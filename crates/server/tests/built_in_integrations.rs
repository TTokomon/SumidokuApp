mod common;
use common::*;
use axum::{Json, Router, http::{HeaderMap,StatusCode}, response::{IntoResponse,Response}, routing::{get,post}};
use serde_json::{Value,json};
use std::sync::{Arc,atomic::{AtomicUsize,Ordering}};

struct Fixture { base:String, calls:Arc<AtomicUsize>, server:tokio::task::JoinHandle<()> }
impl Drop for Fixture { fn drop(&mut self) { self.server.abort(); } }
async fn fixture() -> Fixture {
	let calls=Arc::new(AtomicUsize::new(0)); let count=calls.clone();
	async fn opds(headers:HeaderMap) -> Response {
		if headers.get("authorization").and_then(|v|v.to_str().ok())!=Some("Basic dXNlcjpwYXNz") { return StatusCode::UNAUTHORIZED.into_response(); }
		([(axum::http::header::CONTENT_TYPE,"application/atom+xml")],"<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Komga fixture</title><entry><id>comic</id><title>Fixture Comic</title><link rel=\"http://vaemendis.net/opds-pse/stream\" href=\"/reader/{pageNumber}\" xmlns:pse=\"http://vaemendis.net/opds-pse/ns\" pse:count=\"1\" type=\"image/png\"/></entry></feed>").into_response()
	}
	let app=Router::new().route("/opds/v2/catalog",get(opds))
		.route("/api/opds/private-fixture-key",get(||async { Json(json!({"metadata":{"title":"Kavita fixture"},"publications":[{"metadata":{"identifier":"private-fixture-key/book","title":"Fixture Comic"},"links":[{"rel":"self","type":"application/webpub+json","href":"/api/opds/private-fixture-key/manifest"}]}],"links":[]})) }))
		.route("/api/opds/private-fixture-key/manifest",get(||async { Json(json!({"readingOrder":[{"href":"/api/opds/private-fixture-key/page.png"}]})) }))
		.route("/api/opds/private-fixture-key/page.png",get(||async { ([("content-type","image/png")],vec![137u8,80,78,71]) }))
		.route("/reader/0",get(||async { ([("content-type","image/png")],vec![137u8,80,78,71]) }))
		.route("/not-opds",get(||async { Json(json!({"unrelated":true})) }))
		.route("/redirect",get(||async { (StatusCode::FOUND,[("location","http://127.0.0.1:1/private")]) }))
		.route("/api/graphql",post(move |headers:HeaderMap,Json(body):Json<Value>| { let calls=count.clone(); async move {
			if headers.get("authorization").and_then(|v|v.to_str().ok())!=Some("Basic dXNlcjpwYXNz") { return StatusCode::UNAUTHORIZED.into_response(); }
			let query=body["query"].as_str().unwrap_or_default();
			let data=if query.contains("SumidokuTest") { json!({"mangas":{"nodes":[{"id":7}]}}) }
			else if query.contains("SumidokuLibrary") { json!({"mangas":{"nodes":[{"id":7,"title":"Live fixture","author":"Author","artist":null,"genre":[],"description":"Metadata only"}],"pageInfo":{"hasNextPage":false}}}) }
			else if query.contains("SumidokuChapters") { json!({"fetchChapters":{"chapters":[{"id":13,"name":"Chapter 1","chapterNumber":1.0,"pageCount":1}]}}) }
			else if query.contains("SumidokuPages") { calls.fetch_add(1,Ordering::SeqCst); json!({"fetchChapterPages":{"pages":["/api/v1/manga/7/chapter/0/page/0"]}}) }
			else { return Json(json!({"errors":[{"message":"unsupported fixture query"}]})).into_response(); };
			Json(json!({"data":data})).into_response()
		} })).route("/api/v1/manga/7/chapter/0/page/0",get(||async { ([("content-type","image/png")],vec![137u8,80,78,71]) }));
	let listener=tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();let base=format!("http://{}",listener.local_addr().unwrap());
	let server=tokio::spawn(async move { axum::serve(listener,app).await.unwrap(); });
	Fixture {base,calls,server}
}

#[tokio::test]
async fn local_test_save_and_edit_never_needs_a_repository() {
	let t=test_app().await; let root=t.tmp.path().join("Manga folders");std::fs::create_dir(&root).unwrap();
	let before=request(&t.app,"GET","/api/v1/sources",None).await.1;
	let body=json!({"provider":"local","name":"Local Files fixture","paths":[root]});
	assert_eq!(request(&t.app,"POST","/api/v1/integrations/test",Some(body.clone())).await.0,StatusCode::OK);
	assert_eq!(request(&t.app,"GET","/api/v1/sources",None).await.1,before,"testing must not register a source");
	let (status,source)=request(&t.app,"POST","/api/v1/integrations",Some(body.clone())).await;assert_eq!(status,StatusCode::OK,"{source}");
	let id=source["id"].as_i64().unwrap();
	let saved=request(&t.app,"GET",&format!("/api/v1/integrations/{id}"),None).await.1;
	assert_eq!(saved["paths"],json!([root]));
	let (status,_)=request(&t.app,"PUT",&format!("/api/v1/integrations/{id}"),Some(body)).await;assert_eq!(status,StatusCode::OK);
	assert_eq!(request(&t.app,"GET",&format!("/api/v1/integrations/{id}"),None).await.1["paths"],json!([root]));
	assert_eq!(request(&t.app,"GET","/api/v1/source-repos",None).await.1,json!([]));
}

#[tokio::test]
async fn komga_and_kavita_test_save_credentials_and_failures() {
	let t=test_app().await;let f=fixture().await;
	for (provider,path) in [("komga","/opds/v2/catalog"),("kavita","/api/opds/private-fixture-key")] {
		let body=json!({"provider":provider,"name":provider,"url":format!("{}{path}",f.base),"username":"user","password":"pass"});
		let (status,value)=request(&t.app,"POST","/api/v1/integrations/test",Some(body.clone())).await;assert_eq!(status,StatusCode::OK,"{value}");
		let (status,source)=request(&t.app,"POST","/api/v1/integrations",Some(body.clone())).await;assert_eq!(status,StatusCode::OK,"{source}");
		assert!(!source.to_string().contains("private-fixture-key"));assert!(!source.to_string().contains("pass"));
		let id=source["id"].as_i64().unwrap();
		let saved=request(&t.app,"GET",&format!("/api/v1/integrations/{id}"),None).await.1;
		assert_eq!(saved["hasCredentials"],true);assert!(!saved.to_string().contains("private-fixture-key"));
		let settings=request(&t.app,"GET",&format!("/api/v1/sources/{id}/settings"),None).await.1;
		assert!(!settings.to_string().contains("private-fixture-key"));assert!(!settings.to_string().contains("\"pass\""));
		let (status,value)=request(&t.app,"POST",&format!("/api/v1/sources/{id}/search"),Some(json!({"query":""}))).await;assert_eq!(status,StatusCode::OK,"{value}");
		assert_eq!(value["entries"][0]["title"],"Fixture Comic");
		assert!(!value.to_string().contains("private-fixture-key"),"private URLs must not reach source search metadata");
		let (status,manga)=request(&t.app,"POST","/api/v1/manga",Some(json!({"sourceId":id,"manga":value["entries"][0]}))).await;assert_eq!(status,StatusCode::OK,"{manga}");
		let mid=manga["id"].as_i64().unwrap();let chapters=request(&t.app,"GET",&format!("/api/v1/manga/{mid}/chapters"),None).await.1;
		let cid=chapters[0]["id"].as_i64().unwrap();let (status,pages)=request(&t.app,"GET",&format!("/api/v1/chapter/{cid}/pages"),None).await;
		assert_eq!(status,StatusCode::OK,"{pages}");assert!(!pages.to_string().contains("private-fixture-key"));
		let (page_status,_,page_bytes)=request_full(&t.app,"GET",&format!("/api/v1/chapter/{cid}/page/0"),None).await;
		assert_eq!(page_status,StatusCode::OK); assert_eq!(page_bytes.as_ref(),[137u8,80,78,71]);
		let repeated=request(&t.app,"POST",&format!("/api/v1/sources/{id}/search"),Some(json!({"query":""}))).await.1;
		for field in ["key","url","chapters"] {
			assert_eq!(value["entries"][0][field],repeated["entries"][0][field],"protected {field} must remain stable across refreshes");
		}
		let (_,_,export)=request_full(&t.app,"GET","/api/v1/backups/document",None).await;
		assert!(!String::from_utf8_lossy(&export).contains("private-fixture-key"));

		let update=json!({"provider":provider,"name":"Edited name","sourceId":id,"keepCredentials":true});
		assert_eq!(request(&t.app,"PUT",&format!("/api/v1/integrations/{id}"),Some(update)).await.0,StatusCode::OK);
	}
	for url in [format!("{}/redirect",f.base),format!("{}/not-opds",f.base),"file:///etc/passwd".into()] {
		let (status,_)=request(&t.app,"POST","/api/v1/integrations/test",Some(json!({"provider":"komga","name":"Bad","url":url}))).await;assert_ne!(status,StatusCode::OK);
	}
	assert_eq!(request(&t.app,"POST","/api/v1/integrations/test",Some(json!({"provider":"komga","name":"Bad password","url":format!("{}/opds/v2/catalog",f.base),"username":"user","password":"wrong"}))).await.0,StatusCode::BAD_GATEWAY);
}

#[tokio::test]
async fn suwayomi_live_library_chapters_and_pages_are_not_backup_import_or_download_jobs() {
	let t=test_app().await;let f=fixture().await;
	let body=json!({"provider":"suwayomi","name":"Live Suwayomi","url":f.base,"username":"user","password":"pass"});
	assert_eq!(request(&t.app,"POST","/api/v1/integrations/test",Some(body.clone())).await.0,StatusCode::OK);
	let (status,source)=request(&t.app,"POST","/api/v1/integrations",Some(body)).await;assert_eq!(status,StatusCode::OK,"{source}");
	let id=source["id"].as_i64().unwrap();
	let (status,results)=request(&t.app,"POST",&format!("/api/v1/sources/{id}/search"),Some(json!({"query":"Live"}))).await;assert_eq!(status,StatusCode::OK,"{results}");
	assert_eq!(results["entries"][0]["title"],"Live fixture");assert_eq!(f.calls.load(Ordering::SeqCst),0);
	let (status,manga)=request(&t.app,"POST","/api/v1/manga",Some(json!({"sourceId":id,"manga":results["entries"][0]}))).await;assert_eq!(status,StatusCode::OK,"{manga}");
	let manga=manga["id"].as_i64().unwrap();
	let (status,chapters)=request(&t.app,"GET",&format!("/api/v1/manga/{manga}/chapters"),None).await;assert_eq!(status,StatusCode::OK,"{chapters}");
	assert_eq!(f.calls.load(Ordering::SeqCst),0,"metadata fetch must not request pages");
	let chapter=chapters[0]["id"].as_i64().unwrap();
	let (status,pages)=request(&t.app,"GET",&format!("/api/v1/chapter/{chapter}/pages"),None).await;assert_eq!(status,StatusCode::OK,"{pages}");
	assert_eq!(pages[0]["content"]["Url"][0],format!("{}/api/v1/manga/7/chapter/0/page/0",f.base));
	assert_eq!(f.calls.load(Ordering::SeqCst),1);
	let (status,_,bytes)=request_full(&t.app,"GET",&format!("/api/v1/chapter/{chapter}/page/0"),None).await;
	assert_eq!(status,StatusCode::OK); assert_eq!(bytes.as_ref(),[137u8,80,78,71]);
	assert_eq!(request(&t.app,"GET","/api/v1/downloads",None).await.1,json!([]));
}
