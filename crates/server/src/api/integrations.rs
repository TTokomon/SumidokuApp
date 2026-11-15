//! Built-in setup/test/update surface. Testing never registers a source or fetches chapters.
use crate::{error::{ApiError, ApiResult}, internal::{integration::{self, Connection}, opds_source}, state::AppState};
use axum::{Json, extract::{Path, State}};
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;

#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
pub struct Setup {
	pub provider: String,
	pub name: String,
	#[serde(default)] pub url: String,
	#[serde(default)] pub username: String,
	#[serde(default)] pub password: String,
	#[serde(default)] pub paths: Vec<String>,
	#[serde(default)] pub keep_credentials: bool,
	pub source_id: Option<i64>,
}

async fn connection(state: &AppState, body: &Setup) -> ApiResult<Connection> {
	if !["local","komga","kavita","suwayomi"].contains(&body.provider.as_str()) { return Err(ApiError::bad_request("unknown built-in integration")); }
	let old = if let Some(id) = body.source_id {
		let source = super::source_row(state,id).await?;
		if source.kind != "opds" { return Err(ApiError::bad_request("not a remote built-in connection")); }
		if body.keep_credentials || body.url.trim().is_empty() { integration::load(state,id).await? } else { None }
	} else { None };
	let endpoint = if body.url.trim().is_empty() { old.as_ref().map(|v|v.url.clone()).unwrap_or_default() } else { body.url.trim().to_string() };
	let mut url=integration::url(&endpoint)?;
	if body.provider=="suwayomi" && !url.path().ends_with('/') { url.set_path(&format!("{}/",url.path())); }
	let mut result=Connection { url:url.to_string(), username:body.username.clone(), password:body.password.clone() };
	if body.keep_credentials && let Some(old)=old {
		if integration::url(&old.url)?.origin()!=url.origin() { return Err(ApiError::bad_request("re-enter credentials when changing the server origin")); }
		result.username=old.username; result.password=old.password;
	}
	Ok(result)
}

async fn validate(state: &AppState, body: &Setup) -> ApiResult<Option<Connection>> {
	if body.name.trim().is_empty() || body.name.len()>200 { return Err(ApiError::bad_request("enter a connection name of at most 200 characters")); }
	if body.provider=="local" {
		crate::internal::local::validate_paths(&body.paths).await?;
		return Ok(None);
	}
	let connection=connection(state,body).await?;
	if body.provider=="suwayomi" { crate::internal::suwayomi::test(&connection).await?; }
	else {
		let (bytes,mime)=integration::request(&connection,&integration::url(&connection.url)?,None,4*1024*1024).await?;
		let json_feed = serde_json::from_slice::<Value>(&bytes).ok();
		if let Some(value)=&json_feed {
			if !value["metadata"].is_object() || !["links","navigation","publications","groups"].iter().any(|key|value[*key].is_array()) { return Err(ApiError::bad_gateway("endpoint is not a compatible OPDS catalog")); }
		} else {
			let mut reader=quick_xml::Reader::from_reader(bytes.as_slice());
			loop { match reader.read_event() {
				Ok(quick_xml::events::Event::Start(event)) if event.local_name().as_ref()=="feed" => break,
				Ok(quick_xml::events::Event::Decl(_) | quick_xml::events::Event::Text(_) | quick_xml::events::Event::Comment(_)) => {},
				_ => return Err(ApiError::bad_gateway("endpoint is not a compatible OPDS catalog")),
			} }
		}
		let feed=if mime.as_deref().is_some_and(|v|v.contains("json")) || bytes.first()==Some(&b'{') {
			opds_source::parse_feed_json(&bytes)
		} else { opds_source::parse_feed(&bytes) };
		feed.map_err(|_|ApiError::bad_gateway("endpoint is not a compatible OPDS catalog"))?;
	}
	Ok(Some(connection))
}

pub async fn test(State(state):State<Arc<AppState>>,Json(body):Json<Setup>) -> ApiResult<Json<Value>> {
	validate(&state,&body).await?;
	Ok(Json(json!({"ok":true,"message":"Connection verified. No chapters downloaded."})))
}

pub async fn create(State(state):State<Arc<AppState>>,Json(body):Json<Setup>) -> ApiResult<Json<Value>> {
	if body.source_id.is_some() { return Err(ApiError::bad_request("use the saved connection update action")); }
	let connection=validate(&state,&body).await?;
	// Make the private key/sealed payload before creating a registry row.
	let protected=connection.as_ref().map(|c|integration::seal(&state,c)).transpose()?;
	let row=if body.provider=="local" {
		crate::internal::local::register_instance(&state,&body.name,&body.paths,None,None,None,None,None).await?
	} else {
		let url=integration::url(&connection.as_ref().ok_or_else(||ApiError::internal("missing connection"))?.url)?;
		// Public source metadata never contains a password or an OPDS URL API key.
		opds_source::register_instance(&state,&body.name,&format!("{}/",url.origin().ascii_serialization()),None,None).await?
	};
	let config=json!({"integration":body.provider});
	let mut tx=crate::db::begin_write(&state.pool).await?;
	sqlx::query("UPDATE source SET config=? WHERE id=?").bind(config.to_string()).bind(row.id).execute(&mut *tx).await?;
	if let Some(protected)=protected {
		sqlx::query("INSERT INTO source_setting(source_id,key,value) VALUES (?,?,?)")
			.bind(row.id).bind(integration::SETTINGS_KEY).bind(serde_json::to_string(&aidoku_wasm::DefaultValue::String(protected))?).execute(&mut *tx).await?;
	}
	tx.commit().await?;
	let row=super::source_row(&state,row.id).await?;
	Ok(Json(super::repo::source_json(&row,&Default::default(),&Default::default())))
}

pub async fn get(State(state):State<Arc<AppState>>,Path(id):Path<i64>) -> ApiResult<Json<Value>> {
	let source=super::source_row(&state,id).await?;
	if source.kind=="aidoku" { return Err(ApiError::bad_request("not a built-in connection")); }
	let config=source.config.as_deref().and_then(|v|serde_json::from_str::<Value>(v).ok()).unwrap_or_default();
	let paths=match crate::state::load_defaults(&state.pool,id).await?.remove("paths") { Some(aidoku_wasm::DefaultValue::StringArray(paths))=>Some(paths), _=>None };
	Ok(Json(json!({"id":id,"name":source.name,"provider":config["integration"].as_str().unwrap_or(if source.is_local(){"local"}else{"opds"}),
		"url":source.base_url,"paths":paths,"hasCredentials":sqlx::query_scalar::<_,bool>("SELECT EXISTS(SELECT 1 FROM source_setting WHERE source_id=? AND key=?)").bind(id).bind(integration::SETTINGS_KEY).fetch_one(&state.pool).await?})))
}

pub async fn update(State(state):State<Arc<AppState>>,Path(id):Path<i64>,Json(mut body):Json<Setup>) -> ApiResult<Json<Value>> {
	let row=super::source_row(&state,id).await?;
	if row.kind=="aidoku" || (row.is_local() != (body.provider=="local")) { return Err(ApiError::bad_request("cannot change a connection's source kind")); }
	if let Some(provider)=row.config.as_deref().and_then(|raw|serde_json::from_str::<Value>(raw).ok()).and_then(|doc|doc["integration"].as_str().map(str::to_string))
		&& provider!=body.provider { return Err(ApiError::bad_request("create a separate connection when changing the integration type")); }
	body.source_id=Some(id);
	let connection=validate(&state,&body).await?;
	if let Some(connection)=&connection { integration::save(&state,id,connection).await?; }
	let mut tx=crate::db::begin_write(&state.pool).await?;
	let mut config=row.config.as_deref().and_then(|raw|serde_json::from_str::<Value>(raw).ok()).unwrap_or_else(||json!({}));
	config["integration"]=json!(body.provider);
	let public_url=connection.as_ref().map(|c|integration::url(&c.url).map(|url|format!("{}/",url.origin().ascii_serialization()))).transpose()?;
	sqlx::query("UPDATE source SET name=?,config=?,base_url=COALESCE(?,base_url) WHERE id=?").bind(body.name.trim()).bind(config.to_string()).bind(public_url).bind(id).execute(&mut *tx).await?;
	if body.provider=="local" {
		let dirs=crate::internal::local::validate_paths(&body.paths).await?;
		sqlx::query("INSERT INTO source_setting(source_id,key,value) VALUES (?,'paths',?) ON CONFLICT(source_id,key) DO UPDATE SET value=excluded.value")
			.bind(id).bind(serde_json::to_string(&aidoku_wasm::DefaultValue::StringArray(dirs))?).execute(&mut *tx).await?;
	}
	tx.commit().await?;
	state.evict_source(id).await;
	Ok(Json(json!({"ok":true})))
}
