//! Live Suwayomi GraphQL adapter, reusing the OPDS persistence/reader pipeline.
//! Only the remote library is browsed. No extension install or download mutation is sent.
use super::{integration::{self, Connection}, opds_source::{EntryLink, Feed, FeedEntry}};
use crate::error::{ApiError, ApiResult};
use serde_json::{Value, json};

const MANGAS: &str = "query SumidokuLibrary($offset:Int!,$filter:MangaFilterInput){mangas(condition:{inLibrary:true},first:100,offset:$offset,filter:$filter){nodes{id title description author artist genre thumbnailUrl} pageInfo{hasNextPage}}}";
const CHAPTERS: &str = "mutation SumidokuChapters($id:Int!){fetchChapters(input:{mangaId:$id}){chapters{id name chapterNumber pageCount}}}";
const PAGES: &str = "mutation SumidokuPages($id:Int!){fetchChapterPages(input:{chapterId:$id}){pages}}";

pub async fn query(connection: &Connection, query: &str, variables: Value) -> ApiResult<Value> {
	let mut base = integration::url(&connection.url)?;
	if !base.path().ends_with('/') { base.set_path(&format!("{}/", base.path())); }
	let endpoint = base.join("api/graphql").map_err(|_| ApiError::bad_request("invalid Suwayomi base URL"))?;
	let (bytes, _) = integration::request(connection, &endpoint, Some(json!({"query":query,"variables":variables})), 4*1024*1024).await?;
	let response: Value = serde_json::from_slice(&bytes).map_err(|_| ApiError::bad_gateway("Suwayomi returned invalid JSON"))?;
	if response.get("errors").and_then(Value::as_array).is_some_and(|v| !v.is_empty()) || !response["data"].is_object() {
		return Err(ApiError::bad_gateway("Suwayomi GraphQL rejected the request; check API version and access permissions"));
	}
	Ok(response["data"].clone())
}

pub async fn test(connection: &Connection) -> ApiResult<()> {
	let value = query(connection, "query SumidokuTest{mangas(condition:{inLibrary:true},first:1){nodes{id}}}", json!({})).await?;
	if !value["mangas"]["nodes"].is_array() { return Err(ApiError::bad_gateway("incompatible Suwayomi GraphQL schema")); }
	Ok(())
}

fn link(rel: &str, kind: &str, href: String) -> EntryLink { EntryLink { rel:rel.into(), type_:kind.into(), href, pse_count:None } }
fn virtual_url(connection: &Connection, field: &str, value: &str) -> String {
	let mut url = reqwest::Url::parse(&connection.url).expect("validated connection");
	url.query_pairs_mut().append_pair(field, value); url.to_string()
}
fn text(row: &Value, key: &str) -> String { row[key].as_str().unwrap_or_default().to_string() }
fn entry(row: &Value) -> FeedEntry {
	FeedEntry { id:row["id"].to_string(), title:text(row,"title"), content:text(row,"description"), updated:None,
		authors:row["author"].as_str().map(|v| vec![v.to_string()]).unwrap_or_default(),
		artists:row["artist"].as_str().map(|v| vec![v.to_string()]).unwrap_or_default(),
		tags:row["genre"].as_array().map(|v| v.iter().filter_map(Value::as_str).map(str::to_string).collect()).unwrap_or_default(), links:vec![] }
}

pub async fn feed(connection: &Connection, target: &str) -> ApiResult<Feed> {
	let target = integration::url(target)?;
	if target.origin() != integration::url(&connection.url)?.origin() { return Err(ApiError::bad_request("Suwayomi locator has a different origin")); }
	let params: std::collections::HashMap<_,_> = target.query_pairs().into_owned().collect();
	if let Some(id) = params.get("sumidoku-manga") {
		let id: i32 = id.parse().map_err(|_| ApiError::bad_request("invalid Suwayomi manga ID"))?;
		let data = query(connection, CHAPTERS, json!({"id":id})).await?;
		let rows = data["fetchChapters"]["chapters"].as_array().ok_or_else(|| ApiError::bad_gateway("Suwayomi chapter response missing nodes"))?;
		if rows.len() > 10000 { return Err(ApiError::bad_gateway("Suwayomi chapter list is too large")); }
		let mut feed = Feed::default();
		for row in rows {
			let mut entry = entry(row); entry.title=text(row,"name");
			entry.links.push(link("self", "application/webpub+json", virtual_url(connection,"sumidoku-chapter",&row["id"].to_string())));
			feed.entries.push(entry.clone()); feed.publications.push(entry);
		}
		return Ok(feed);
	}
	let offset: u32 = params.get("sumidoku-offset").map(|v| v.parse()).transpose().map_err(|_| ApiError::bad_request("invalid Suwayomi page"))?.unwrap_or(0);
	if offset > 100000 { return Err(ApiError::bad_request("Suwayomi page limit exceeded")); }
	let data = query(connection, MANGAS, json!({"offset":offset,"filter":params.get("sumidoku-query").map(|q|json!({"title":{"includesInsensitive":q}}))})).await?;
	let rows = data["mangas"]["nodes"].as_array().ok_or_else(|| ApiError::bad_gateway("Suwayomi library response missing nodes"))?;
	let mut feed = Feed { title:"Suwayomi library".into(), ..Feed::default() };
	for row in rows {
		let mut entry = entry(row);
		entry.links.push(link("self","application/opds+json",virtual_url(connection,"sumidoku-manga",&row["id"].to_string())));
		if let Some(thumbnail) = row["thumbnailUrl"].as_str() {
			let base = integration::url(&connection.url)?;
			let url = base.join(thumbnail).map_err(|_| ApiError::bad_gateway("invalid Suwayomi thumbnail URL"))?;
			if url.origin() == base.origin() { entry.links.push(link("http://opds-spec.org/image/thumbnail","image/jpeg",url.to_string())); }
		}
		feed.entries.push(entry.clone()); feed.publications.push(entry);
	}
	if data["mangas"]["pageInfo"]["hasNextPage"] == true {
		let mut next=integration::url(&virtual_url(connection,"sumidoku-offset",&(offset+100).to_string()))?;
		if let Some(query)=params.get("sumidoku-query") { next.query_pairs_mut().append_pair("sumidoku-query",query); }
		feed.links.push(link("next","application/opds+json",next.to_string()));
	}
	Ok(feed)
}

pub async fn manifest(connection: &Connection, target: &str) -> ApiResult<Option<Vec<u8>>> {
	let target = integration::url(target)?;
	if target.origin() != integration::url(&connection.url)?.origin() { return Err(ApiError::bad_request("Suwayomi locator has a different origin")); }
	let Some(id) = target.query_pairs().find_map(|(k,v)| (k=="sumidoku-chapter").then(||v.into_owned())) else { return Ok(None) };
	let id: i32=id.parse().map_err(|_|ApiError::bad_request("invalid Suwayomi chapter ID"))?;
	let data=query(connection,PAGES,json!({"id":id})).await?;
	let pages=data["fetchChapterPages"]["pages"].as_array().ok_or_else(||ApiError::bad_gateway("Suwayomi returned no page URLs"))?;
	if pages.len()>10000 { return Err(ApiError::bad_gateway("Suwayomi page count exceeded")); }
	let base=integration::url(&connection.url)?;
	let mut order=vec![];
	for page in pages {
		let page=page.as_str().ok_or_else(||ApiError::bad_gateway("invalid Suwayomi page URL"))?;
		let page=base.join(page).map_err(|_|ApiError::bad_gateway("invalid Suwayomi page URL"))?;
		if page.origin()!=base.origin() { return Err(ApiError::bad_gateway("Suwayomi page URL must use the configured server origin")); }
		order.push(json!({"href":page.as_str()}));
	}
	Ok(Some(serde_json::to_vec(&json!({"readingOrder":order}))?))
}
