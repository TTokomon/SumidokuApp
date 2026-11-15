//! Private connection storage and bounded, non-redirecting integration requests.
use crate::{error::{ApiError, ApiResult}, state::AppState};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use rand_core::RngCore as _;
use ring::aead::{Aad, LessSafeKey, Nonce, UnboundKey, CHACHA20_POLY1305};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::Write;

pub const SETTINGS_KEY: &str = "integration.credentials";
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Connection {
	pub url: String,
	pub username: String,
	pub password: String,
}

pub fn url(raw: &str) -> ApiResult<reqwest::Url> {
	let url = reqwest::Url::parse(raw.trim()).map_err(|_| ApiError::bad_request("invalid connection URL"))?;
	if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() || !url.username().is_empty() || url.password().is_some() || url.fragment().is_some() {
		return Err(ApiError::bad_request("use an HTTP(S) URL without embedded credentials or a fragment"));
	}
	Ok(url)
}

fn key(state: &AppState, create: bool) -> ApiResult<LessSafeKey> {
	let path = state.config.config_dir.join("integration-secrets.key");
	if create && !path.exists() {
		let mut bytes = [0; 32]; rand_core::OsRng.fill_bytes(&mut bytes);
		let mut options = std::fs::OpenOptions::new(); options.write(true).create_new(true);
		#[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
		match options.open(&path) {
			Ok(mut file) => { file.write_all(&bytes).map_err(|_| ApiError::internal("cannot save integration key"))?; file.sync_all().map_err(|_| ApiError::internal("cannot sync integration key"))?; }
			Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
			Err(_) => return Err(ApiError::internal("cannot create private integration key")),
		}
	}
	let bytes = std::fs::read(path).map_err(|_| ApiError::internal("integration key missing; reconnect this source"))?;
	let key = UnboundKey::new(&CHACHA20_POLY1305, &bytes).map_err(|_| ApiError::internal("invalid integration key"))?;
	Ok(LessSafeKey::new(key))
}

pub fn seal(state: &AppState, connection: &Connection) -> ApiResult<String> {
	let mut nonce = [0; 12]; rand_core::OsRng.fill_bytes(&mut nonce);
	let mut bytes = serde_json::to_vec(connection)?;
	key(state,true)?.seal_in_place_append_tag(Nonce::assume_unique_for_key(nonce), Aad::from(SETTINGS_KEY), &mut bytes)
		.map_err(|_| ApiError::internal("cannot protect integration credentials"))?;
	Ok(STANDARD.encode([nonce.as_slice(), &bytes].concat()))
}

pub async fn load(state: &AppState, id: i64) -> ApiResult<Option<Connection>> {
	let stored: Option<String> = sqlx::query_scalar("SELECT value FROM source_setting WHERE source_id = ? AND key = ?")
		.bind(id).bind(SETTINGS_KEY).fetch_optional(&state.pool).await?;
	let Some(stored) = stored else { return Ok(None) };
	let encoded = match serde_json::from_str::<aidoku_wasm::DefaultValue>(&stored) {
		Ok(aidoku_wasm::DefaultValue::String(value))=>value,
		_=>return Err(ApiError::internal("invalid protected connection")),
	};
	open(state,&encoded).map(Some)
}

pub fn open(state:&AppState,encoded:&str) -> ApiResult<Connection> {
	let mut bytes = STANDARD.decode(encoded).map_err(|_| ApiError::internal("invalid protected connection"))?;
	if bytes.len() < 28 { return Err(ApiError::internal("invalid protected connection")); }
	let nonce: [u8; 12] = bytes[..12].try_into().map_err(|_| ApiError::internal("invalid protected connection"))?;
	let plain = key(state,false)?.open_in_place(Nonce::assume_unique_for_key(nonce), Aad::from(SETTINGS_KEY), &mut bytes[12..])
		.map_err(|_| ApiError::bad_request("connection credentials cannot be opened; reconnect this source"))?;
	serde_json::from_slice(plain).map_err(|_| ApiError::internal("invalid protected connection"))
}

pub async fn save(state: &AppState, id: i64, connection: &Connection) -> ApiResult<()> {
	let protected = serde_json::to_string(&aidoku_wasm::DefaultValue::String(seal(state, connection)?))?;
	sqlx::query("INSERT INTO source_setting (source_id,key,value) VALUES (?,?,?) ON CONFLICT(source_id,key) DO UPDATE SET value=excluded.value")
		.bind(id).bind(SETTINGS_KEY).bind(protected).execute(&state.pool).await?;
	Ok(())
}

pub async fn request(connection: &Connection, target: &reqwest::Url, body: Option<Value>, cap: u64) -> ApiResult<(Vec<u8>, Option<String>)> {
	let origin = url(&connection.url)?;
	let validated = url(target.as_str())?;
	if origin.scheme()=="https" && validated.scheme()!="https" { return Err(ApiError::bad_gateway("integration links cannot downgrade HTTPS")); }
	let client = reqwest::Client::builder().no_proxy().redirect(reqwest::redirect::Policy::none())
		.timeout(std::time::Duration::from_secs(20)).build().map_err(|_| ApiError::internal("cannot create integration client"))?;
	let mut request = if let Some(body) = body { client.post(target.clone()).json(&body) } else { client.get(target.clone()) };
	if origin.origin() == target.origin() && !connection.username.is_empty() { request = request.basic_auth(&connection.username, Some(&connection.password)); }
	let response = request.send().await.map_err(|_| ApiError::bad_gateway("connection unavailable or TLS verification failed"))?;
	if !response.status().is_success() { return Err(ApiError::bad_gateway(format!("connection returned HTTP {}; check endpoint and credentials (redirects are not followed)", response.status().as_u16()))); }
	crate::source::read_body(response, cap).await
}

/// Opaque fetch locators keep API-key URLs out of library metadata and logs.
/// A PSE page placeholder remains outside the encrypted payload.
pub async fn protect_url(state:&AppState,raw:&str) -> ApiResult<String> {
	let template=raw.contains("{pageNumber}");
	let search=raw.contains("SUMIDOKU_SEARCH_TOKEN");
	let raw=raw.replace("{pageNumber}","SUMIDOKU_PAGE_TOKEN");
	let parsed=url(&raw)?;
	use sha2::{Digest as _,Sha256};
	let key_bytes=std::fs::read(state.config.config_dir.join("integration-secrets.key")).map_err(|_|ApiError::internal("integration key missing"))?;
	let cache_key=format!("integration.url.{}",STANDARD.encode(Sha256::digest([key_bytes.as_slice(),raw.as_bytes()].concat())));
	let cached:Option<String>=crate::server_state::get(&state.pool,&cache_key).await?;
	let sealed=if let Some(value)=cached { value } else {
		let value=seal(state,&Connection {url:raw, ..Connection::default()})?;
		crate::server_state::integration_locator(&state.pool,&cache_key,&value).await?
	};
	let blob=sealed.replace('+',"-").replace('/',"_").trim_end_matches('=').to_string();
	Ok(format!("{}/.sumidoku-private/{blob}{}",parsed.origin().ascii_serialization(),if template {"?page={pageNumber}"} else if search {"?search={searchTerms}"} else {""}))
}

pub fn reveal_url(state:&AppState,raw:&str) -> ApiResult<reqwest::Url> {
	let parsed=url(raw)?;
	let Some(blob)=parsed.path().strip_prefix("/.sumidoku-private/") else { return Ok(parsed) };
	let mut blob=blob.replace('-',"+").replace('_',"/");
	while blob.len()%4!=0 { blob.push('='); }
	let mut target=open(state,&blob)?.url;
	if target.contains("SUMIDOKU_PAGE_TOKEN") {
		let page=parsed.query_pairs().find_map(|(k,v)|(k=="page").then(||v.into_owned())).ok_or_else(||ApiError::bad_request("missing page number"))?;
		let page:u32=page.parse().map_err(|_|ApiError::bad_request("invalid page number"))?;
		if page>10000 { return Err(ApiError::bad_request("page limit exceeded")); }
		target=target.replace("SUMIDOKU_PAGE_TOKEN",&page.to_string());
	}
	if target.contains("SUMIDOKU_SEARCH_TOKEN") {
		let search=parsed.query_pairs().find_map(|(k,v)|(k=="search").then(||v.into_owned())).ok_or_else(||ApiError::bad_request("missing search term"))?;
		let encoded:String=url::form_urlencoded::byte_serialize(search.as_bytes()).collect();
		target=target.replace("SUMIDOKU_SEARCH_TOKEN",&encoded);
	}
	url(&target)
}
