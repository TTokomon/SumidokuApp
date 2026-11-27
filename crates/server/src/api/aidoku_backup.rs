//! Aidoku .aib import: a binary-plist-encoded Codable Backup (Aidoku/Aidoku Core/Backup/Models);
//! the additive merge semantics differ from BackupDoc restore's upsert — see import_merge for the merge primitives

use crate::error::{ApiError, ApiResult};
use crate::model::unix_now;
use crate::state::AppState;
use crate::tracker::core::TrackMode;
use crate::tracker::{Provider, dao};
use axum::Extension;
use axum::extract::{Query, State};
use axum::response::Json;
use base64::Engine as _;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use serde_json::{Value, json};
use sqlx::{Sqlite, Transaction};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use super::import_merge::{
	ChapterMeta, ImportCounts, MangaMeta, ensure_category, ensure_chapter_row, ensure_manga_row,
	mark_in_library, merge_chapter_progress,
};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AidokuImportQuery {
	#[serde(default)]
	pub dry_run: bool,
	/// Older clients retain skip semantics unless they explicitly opt into offline preservation.
	#[serde(default)]
	pub preserve_missing_sources: bool,
	pub preview_fingerprint: Option<String>,
}

// The structs below declare only the consumed fields, unknown fields tolerated; field names follow Aidoku's Codable keys
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AibBackup {
	#[serde(default)]
	library: Vec<AibLibraryManga>,
	#[serde(default)]
	history: Vec<AibHistory>,
	#[serde(default)]
	manga: Vec<AibManga>,
	#[serde(default)]
	chapters: Vec<AibChapter>,
	// Aidoku writes either a bare string or a {title,sort,group,data} object, so take the title from a Value by hand
	#[serde(default)]
	categories: Vec<plist::Value>,
	#[serde(default)]
	track_items: Vec<AibTrackItem>,
	// Aidoku exports its whole UserDefaults dump here; only the per-manga chapter display mode is read (it is also the
	// tracking mode), everything else is left alone rather than imported
	#[serde(default)]
	settings: HashMap<String, plist::Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AibTrackItem {
	// Aidoku's track id on the tracker's side; the binding's remote entry id
	id: String,
	tracker_id: String,
	manga_id: String,
	source_id: String,
	#[serde(default)]
	title: Option<String>,
	#[serde(default)]
	chapter_offset: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AibLibraryManga {
	manga_id: String,
	source_id: String,
	#[serde(default)]
	date_added: Option<plist::Date>,
	#[serde(default)]
	categories: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AibHistory {
	source_id: String,
	manga_id: String,
	chapter_id: String,
	#[serde(default)]
	progress: Option<i64>,
	#[serde(default)]
	total: Option<i64>,
	#[serde(default)]
	completed: bool,
	#[serde(default)]
	date_read: Option<plist::Date>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AibManga {
	id: String,
	source_id: String,
	#[serde(default)]
	title: String,
	#[serde(default)]
	author: Option<String>,
	#[serde(default)]
	artist: Option<String>,
	#[serde(default)]
	desc: Option<String>,
	#[serde(default)]
	tags: Vec<String>,
	#[serde(default)]
	cover: Option<String>,
	#[serde(default)]
	url: Option<String>,
	#[serde(default)]
	status: i64,
	#[serde(default)]
	nsfw: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AibChapter {
	#[serde(default)]
	thumbnail: Option<String>,
	#[serde(default)]
	locked: Option<bool>,
	id: String,
	source_id: String,
	manga_id: String,
	#[serde(default)]
	title: Option<String>,
	#[serde(default)]
	scanlator: Option<String>,
	#[serde(default)]
	url: Option<String>,
	#[serde(default)]
	lang: Option<String>,
	#[serde(default)]
	chapter: Option<f64>,
	#[serde(default)]
	volume: Option<f64>,
	#[serde(default)]
	date_uploaded: Option<plist::Date>,
	#[serde(default)]
	source_order: i64,
}

struct ReportEntry<'a> {
	section: &'static str,
	source_key: &'a str,
	manga_key: &'a str,
	chapter_key: Option<&'a str>,
	tracker_id: Option<&'a str>,
	reason: Option<&'static str>,
}

impl ReportEntry<'_> {
	fn to_json(
		&self,
		manga: &HashMap<(&str, &str), &AibManga>,
		chapters: &HashMap<(&str, &str, &str), &AibChapter>,
	) -> Value {
		let mut value = json!({
			"section": self.section,
			"sourceKey": self.source_key,
			"mangaKey": self.manga_key,
		});
		if let Some(title) = manga
			.get(&(self.source_key, self.manga_key))
			.map(|m| m.title.as_str())
			.filter(|title| !title.trim().is_empty())
		{
			value["mangaTitle"] = json!(title);
		}
		if let Some(key) = self.chapter_key {
			value["chapterKey"] = json!(key);
			if let Some(title) = chapters
				.get(&(self.source_key, self.manga_key, key))
				.and_then(|chapter| chapter.title.as_deref())
				.filter(|title| !title.trim().is_empty())
			{
				value["chapterTitle"] = json!(title);
			}
		}
		if let Some(tracker_id) = self.tracker_id {
			value["trackerId"] = json!(tracker_id);
		}
		if let Some(reason) = self.reason {
			value["reason"] = json!(reason);
		}
		value
	}
}

#[derive(serde::Serialize)]
struct SourceIdentity {
	id: i64,
	kind: String,
	version: i64,
	enabled: bool,
	updated_at: i64,
	has_package: bool,
}

#[derive(Default)]
struct ImportReport<'a> {
	imported: ImportCounts,
	entries: Vec<ReportEntry<'a>>,
	categories: HashSet<String>,
	preserve_missing_sources: bool,
	missing_sources: HashSet<String>,
	archived_trackers: Vec<crate::settings::ArchivedAidokuTracker>,
	archived_count: usize,
	source_identities: BTreeMap<String, Option<SourceIdentity>>,
	resolved_sources: HashMap<String, Option<i64>>,
}

/// A Swift Date in a plist is CFAbsoluteTime; the plist crate has already normalized it to SystemTime
fn date_to_unix(date: plist::Date) -> i64 {
	let time: std::time::SystemTime = date.into();
	time.duration_since(std::time::UNIX_EPOCH)
		.map(|d| d.as_secs() as i64)
		.unwrap_or(0)
}

/// Match exact source identities. Reuse the disabled, package-less source representation
/// used by data-preserving uninstall. The installer reuses its row ID.
pub(crate) fn retainable_aidoku_key(key: &str) -> bool {
	crate::source::valid_source_key(key)
		&& !["local.", "opds.", "komga.", "kavita.", "suwayomi."].iter().any(|prefix| key.starts_with(prefix))
}

async fn source_id_by_key(
	tx: &mut Transaction<'_, Sqlite>,
	key: &str,
	report: &mut ImportReport<'_>,
) -> ApiResult<Option<i64>> {
	if let Some(id) = report.resolved_sources.get(key) {
		return Ok(*id);
	}
	let existing: Option<(i64, String, String, i64, bool, i64)> = sqlx::query_as(
		"SELECT id, kind, wasm_path, version, enabled, updated_at FROM source WHERE key = ?",
	).bind(key).fetch_optional(&mut **tx).await?;
	let identity = existing.map(|(id, kind, path, version, enabled, updated_at)| SourceIdentity {
		id, kind, version, enabled, updated_at, has_package: !path.is_empty(),
	});
	let resolved = match &identity {
		Some(source) if source.kind != "aidoku" || source.has_package => Some(source.id),
		Some(source) if report.preserve_missing_sources => {
			report.missing_sources.insert(key.to_string());
			Some(source.id)
		}
		None if report.preserve_missing_sources && retainable_aidoku_key(key) => {
			let id = sqlx::query_scalar(
				"INSERT INTO source (key, name, kind, wasm_path, enabled) VALUES (?, ?, 'aidoku', '', 0) RETURNING id",
			).bind(key).bind(key).fetch_one(&mut **tx).await?;
			report.missing_sources.insert(key.to_string());
			Some(id)
		}
		_ => None,
	};
	report.source_identities.insert(key.to_string(), identity);
	report.resolved_sources.insert(key.to_string(), resolved);
	Ok(resolved)
}

/// Aidoku stores contentRating.rawValue - 1 (when >0); 0 conflates unknown/safe, treated as unknown
fn content_rating_from_aib(nsfw: i64) -> i64 {
	match nsfw {
		1 => 2,
		2 => 3,
		_ => 0,
	}
}

fn category_title(value: &plist::Value) -> Option<String> {
	match value {
		plist::Value::String(title) => Some(title.clone()),
		plist::Value::Dictionary(dict) => dict
			.get("title")
			.and_then(plist::Value::as_string)
			.map(str::to_string),
		_ => None,
	}
}

fn aib_manga_meta(m: &AibManga) -> ApiResult<MangaMeta<'_>> {
	Ok(MangaMeta {
		title: m.title.as_str(),
		authors: serde_json::to_string(m.author.as_slice())?,
		artists: serde_json::to_string(m.artist.as_slice())?,
		description: m.desc.as_deref(),
		tags: serde_json::to_string(&m.tags)?,
		status: m.status,
		content_rating: content_rating_from_aib(m.nsfw),
		cover_url: m.cover.as_deref(),
		url: m.url.as_deref(),
	})
}

fn aib_chapter_meta(c: &AibChapter) -> ApiResult<ChapterMeta<'_>> {
	Ok(ChapterMeta {
		thumbnail: c.thumbnail.as_deref(),
		page_count: 0,
		locked: c.locked.unwrap_or(false),
		title: c.title.as_deref(),
		number: c.chapter,
		volume: c.volume,
		scanlators: serde_json::to_string(c.scanlator.as_slice())?,
		language: c.lang.as_deref(),
		url: c.url.as_deref(),
		date_uploaded: c.date_uploaded.map(date_to_unix),
		source_order: c.source_order,
	})
}

/// Aidoku's tracker ids (`AniListTracker.id` and friends) mapped onto this server's providers; a tracker without a
/// provider here (Shikimori, Komga, Kavita, Suwayomi) is reported as skipped instead of being guessed at
fn aidoku_tracker_provider(tracker_id: &str) -> Option<Provider> {
	match tracker_id {
		"anilist" => Some(Provider::Anilist),
		"myanimelist" => Some(Provider::Mal),
		"bangumi" => Some(Provider::Bangumi),
		"mangabaka" => Some(Provider::Mangabaka),
		_ => None,
	}
}

/// Aidoku's per-manga chapter display mode is also its tracking mode (ChapterTitleDisplayMode: 0 default, 1 chapter,
/// 2 volume, stored under `Manga.chapterDisplayMode.<sourceKey>.<mangaKey>`): the volume mode pushed only the volume,
/// which is exactly TrackMode::Volume. Absent or unknown maps to auto, which decides chapter-first.
fn track_mode_from_settings(settings: &HashMap<String, plist::Value>, source_key: &str, manga_key: &str) -> TrackMode {
	let key = format!("Manga.chapterDisplayMode.{source_key}.{manga_key}");
	match settings.get(&key).and_then(plist::Value::as_signed_integer) {
		Some(1) => TrackMode::Chapter,
		Some(2) => TrackMode::Volume,
		_ => TrackMode::Auto,
	}
}

pub async fn import_aidoku_backup(
	State(state): State<Arc<AppState>>,
	Extension(user): Extension<crate::auth::AuthUser>,
	Query(query): Query<AidokuImportQuery>,
	body: axum::body::Bytes,
) -> ApiResult<Json<Value>> {
	static ACTIVE_IMPORTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);
	let permit = ACTIVE_IMPORTS.try_acquire()
		.map_err(|_| ApiError::too_many_requests("another Aidoku backup is in progress; try again shortly"))?;
	static NEXT_REQUEST: AtomicU64 = AtomicU64::new(1);
	let request_id = NEXT_REQUEST.fetch_add(1, Ordering::Relaxed);
	let started = std::time::Instant::now();
	let result = tokio::task::spawn_blocking(move || {
		let doc = plist::from_bytes::<AibBackup>(&body)
			.map_err(|_| ApiError::bad_request("invalid Aidoku backup plist"))?;
		let digest = Sha256::digest(&body);
		// Keep the concurrency permit until parsing ends even if the client disconnects.
		Ok::<_, ApiError>((doc, digest, permit))
	}).await.map_err(|_| ApiError::internal("Aidoku backup parsing failed"))?;
	let (doc, digest, _permit) = result?;
	let parsed = started.elapsed();
	let result = import_aidoku_doc(&state, user.id, &doc, &digest, &query, request_id).await;
	tracing::info!(%request_id, dry_run = query.dry_run, parsed_ms = parsed.as_millis(),
		elapsed_ms = started.elapsed().as_millis(), success = result.is_ok(), "Aidoku backup request completed");
	Ok(Json(result?))
}

/// Validation and a single write transaction for preview and commit.
async fn import_aidoku_doc(
	state: &AppState, user_id: i64, doc: &AibBackup, digest: &[u8], query: &AidokuImportQuery, request_id: u64,
) -> ApiResult<Value> {
	let AidokuImportQuery { dry_run, preserve_missing_sources, preview_fingerprint } = query;
	let (dry_run, preserve_missing_sources) = (*dry_run, *preserve_missing_sources);
	let manga_meta: HashMap<(&str, &str), &AibManga> = doc
		.manga
		.iter()
		.map(|m| ((m.source_id.as_str(), m.id.as_str()), m))
		.collect();
	let chapter_meta: HashMap<(&str, &str, &str), &AibChapter> = doc
		.chapters
		.iter()
		.map(|c| ((c.source_id.as_str(), c.manga_id.as_str(), c.id.as_str()), c))
		.collect();

	let mut report = ImportReport { preserve_missing_sources, ..Default::default() };
	let fingerprint;
	{
		let wait = std::time::Instant::now();
		let mut tx = crate::db::begin_write(&state.pool).await?;
		tracing::debug!(%request_id, wait_ms = wait.elapsed().as_millis(), "Aidoku backup write transaction acquired");
		import_categories(&mut tx, user_id, doc, &mut report.categories).await?;
		import_library(&mut tx, user_id, doc, &manga_meta, &mut report).await?;
		import_progress(&mut tx, user_id, doc, &manga_meta, &chapter_meta, &mut report).await?;
		import_library_chapters(&mut tx, doc, &manga_meta, &mut report).await?;
		import_trackers(&mut tx, user_id, doc, &manga_meta, &mut report).await?;
		let archived_count = report.archived_trackers.len();
		crate::settings::merge_aidoku_tracker_archive(&mut tx, std::mem::take(&mut report.archived_trackers)).await?;
		// Retain the reported count (including existing matches) for preview/commit parity.
		report.archived_count = archived_count;
		let mut hash = Sha256::new();
		hash.update(b"sumidoku-aidoku-preview-v1");
		hash.update(digest);
		hash.update([u8::from(preserve_missing_sources)]);
		hash.update(serde_json::to_vec(&report.source_identities)?);
		fingerprint = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(hash.finalize());
		if !dry_run && preview_fingerprint.as_ref().is_some_and(|expected| *expected != fingerprint) {
			tx.rollback().await?;
			return Err(ApiError::conflict("aidoku_preview_changed", "The backup or its sources changed. Recheck the backup before importing."));
		}
		if dry_run {
			tx.rollback().await?;
		} else {
			tx.commit().await?;
		}
	}
	let (skipped, included): (Vec<_>, Vec<_>) = report.entries.iter().partition(|entry| entry.reason.is_some());
	let entry_json = |entry: &ReportEntry<'_>| entry.to_json(&manga_meta, &chapter_meta);
	let mut categories: Vec<_> = report.categories.iter().collect();
	categories.sort_unstable();
	let mut missing_sources: Vec<_> = report.missing_sources.iter().collect();
	missing_sources.sort_unstable();
	Ok(json!({
		"dryRun": dry_run,
		"previewFingerprint": fingerprint,
		"imported": {
			"library": report.imported.library,
			"categories": categories.len(),
			"progress": report.imported.progress,
			"trackers": report.imported.trackers,
		},
		"included": included.into_iter().map(entry_json).collect::<Vec<_>>(),
		"categoryNames": categories,
		"missingSources": missing_sources,
		"archivedTrackers": report.archived_count,
		"skipped": skipped.into_iter().map(entry_json).collect::<Vec<_>>(),
	}))
}

/// The top-level categories array creates rows first; categories that appear only as references inside library entries are created lazily in import_library
async fn import_categories(
	tx: &mut Transaction<'_, Sqlite>,
	user_id: i64,
	doc: &AibBackup,
	seen: &mut HashSet<String>,
) -> ApiResult<()> {
	for value in &doc.categories {
		let title = category_title(value)
			.filter(|t| !t.trim().is_empty())
			.ok_or_else(|| ApiError::bad_request("aidoku category must have a non-empty title"))?;
		ensure_category(tx, user_id, title.trim()).await?;
		seen.insert(title.trim().to_string());
	}
	Ok(())
}

async fn import_library<'a>(
	tx: &mut Transaction<'_, Sqlite>,
	user_id: i64,
	doc: &'a AibBackup,
	manga_meta: &HashMap<(&str, &str), &AibManga>,
	report: &mut ImportReport<'a>,
) -> ApiResult<()> {
	for entry in &doc.library {
		if entry.source_id.is_empty() || entry.manga_id.is_empty() {
			return Err(ApiError::bad_request(
				"aidoku library entry must have non-empty sourceId and mangaId",
			));
		}
		let row = ReportEntry {
			section: "library",
			source_key: &entry.source_id,
			manga_key: &entry.manga_id,
			chapter_key: None,
			tracker_id: None,
			reason: None,
		};
		let Some(source_id) = source_id_by_key(tx, &entry.source_id, report).await? else {
			report.entries.push(ReportEntry { reason: Some("source not installed"), ..row });
			continue;
		};
		let meta = manga_meta
			.get(&(entry.source_id.as_str(), entry.manga_id.as_str()))
			.map(|m| aib_manga_meta(m))
			.transpose()?;
		let manga_id = ensure_manga_row(tx, source_id, &entry.manga_id, meta.as_ref()).await?;
		let in_library_at = entry.date_added.map(date_to_unix).unwrap_or_else(unix_now);
		mark_in_library(tx, user_id, manga_id, in_library_at).await?;
		for name in &entry.categories {
			let name = name.trim();
			if name.is_empty() {
				report.entries.push(ReportEntry {
					section: "categories",
					reason: Some("category assignment has a blank name"),
					..row
				});
				continue;
			}
			let category_id = ensure_category(tx, user_id, name).await?;
			report.categories.insert(name.to_string());
			crate::store::category::add_manga(tx, category_id, manga_id, user_id).await?;
		}
		report.imported.library += 1;
		report.entries.push(row);
	}
	Ok(())
}

/// History rows take precedence because they may carry a page count. Keep the
/// other chapter metadata for shelved titles as provisional source records.
async fn import_library_chapters(
	tx: &mut Transaction<'_, Sqlite>,
	doc: &AibBackup,
	manga_meta: &HashMap<(&str, &str), &AibManga>,
	report: &mut ImportReport<'_>,
) -> ApiResult<()> {
	let shelved: HashSet<_> = doc.library.iter()
		.map(|entry| (entry.source_id.as_str(), entry.manga_id.as_str())).collect();
	let mut manga_ids = HashMap::new();
	for chapter in &doc.chapters {
		let key = (chapter.source_id.as_str(), chapter.manga_id.as_str());
		if chapter.id.is_empty() || !shelved.contains(&key) {
			continue;
		}
		let manga_id = if let Some(&id) = manga_ids.get(&key) {
			id
		} else {
			let Some(source_id) = source_id_by_key(tx, key.0, report).await? else { continue };
			let meta = manga_meta.get(&key).map(|manga| aib_manga_meta(manga)).transpose()?;
			let id = ensure_manga_row(tx, source_id, key.1, meta.as_ref()).await?;
			manga_ids.insert(key, id);
			id
		};
		let meta = aib_chapter_meta(chapter)?;
		ensure_chapter_row(tx, manga_id, &chapter.id, Some(&meta)).await?;
	}
	Ok(())
}

async fn import_progress<'a>(
	tx: &mut Transaction<'_, Sqlite>,
	user_id: i64,
	doc: &'a AibBackup,
	manga_meta: &HashMap<(&str, &str), &AibManga>,
	chapter_meta: &HashMap<(&str, &str, &str), &AibChapter>,
	report: &mut ImportReport<'a>,
) -> ApiResult<()> {
	for entry in &doc.history {
		if entry.source_id.is_empty() || entry.manga_id.is_empty() || entry.chapter_id.is_empty() {
			return Err(ApiError::bad_request(
				"aidoku history entry must have non-empty sourceId, mangaId and chapterId",
			));
		}
		let row = ReportEntry {
			section: "progress",
			source_key: &entry.source_id,
			manga_key: &entry.manga_id,
			chapter_key: Some(&entry.chapter_id),
			tracker_id: None,
			reason: None,
		};
		let Some(source_id) = source_id_by_key(tx, &entry.source_id, report).await? else {
			report.entries.push(ReportEntry { reason: Some("source not installed"), ..row });
			continue;
		};
		let meta = manga_meta
			.get(&(entry.source_id.as_str(), entry.manga_id.as_str()))
			.map(|m| aib_manga_meta(m))
			.transpose()?;
		let manga_id = ensure_manga_row(tx, source_id, &entry.manga_id, meta.as_ref()).await?;
		let mut meta = chapter_meta
			.get(&(
				entry.source_id.as_str(),
				entry.manga_id.as_str(),
				entry.chapter_id.as_str(),
			))
			.map(|c| aib_chapter_meta(c))
			.transpose()?;
		if let Some(meta) = &mut meta {
			meta.page_count = entry.total.filter(|total| (1..=i16::MAX as i64).contains(total)).unwrap_or(0);
		}
		let chapter_id = ensure_chapter_row(tx, manga_id, &entry.chapter_id, meta.as_ref()).await?;
		// Aidoku also uses -1 for absent progress. Only completed establishes read status.
		let last_page_read = entry.progress.unwrap_or(0).max(0);
		let last_read_at = entry.date_read.map(date_to_unix);
		merge_chapter_progress(tx, user_id, chapter_id, last_page_read, entry.completed, last_read_at).await?;
		report.imported.progress += 1;
		report.entries.push(row);
	}
	Ok(())
}

/// Restores tracker bindings: Aidoku's TrackObject rows carry the tracker's own entry id, so each one becomes a local
/// binding; an existing binding for the same (manga, provider) is kept as is, and unsupported trackers are reported
/// rather than dropped silently. The manga row is created from the backup's metadata when the entry is not in the library.
async fn import_trackers<'a>(
	tx: &mut Transaction<'_, Sqlite>,
	user_id: i64,
	doc: &'a AibBackup,
	manga_meta: &HashMap<(&str, &str), &AibManga>,
	report: &mut ImportReport<'a>,
) -> ApiResult<()> {
	for entry in &doc.track_items {
		if entry.source_id.is_empty() || entry.manga_id.is_empty() || entry.id.is_empty() {
			return Err(ApiError::bad_request(
				"aidoku track entry must have non-empty sourceId, mangaId and id",
			));
		}
		let row = ReportEntry {
			section: "trackers",
			source_key: &entry.source_id,
			manga_key: &entry.manga_id,
			chapter_key: None,
			tracker_id: Some(&entry.tracker_id),
			reason: None,
		};
		let provider = aidoku_tracker_provider(&entry.tracker_id);
		// An unsupported provider is an inactive association, never a live link or
		// a credential. Archive the original identity even when its source is absent.
		if provider.is_none() && report.preserve_missing_sources {
			report.archived_trackers.push(crate::settings::ArchivedAidokuTracker {
				source_key: entry.source_id.clone(),
				manga_key: entry.manga_id.clone(),
				tracker_id: entry.tracker_id.clone(),
				track_id: entry.id.clone(),
				title: entry.title.clone(),
				chapter_offset: entry.chapter_offset,
				track_mode: track_mode_from_settings(&doc.settings, &entry.source_id, &entry.manga_id).as_str().to_string(),
			});
			report.entries.push(ReportEntry { section: "archivedTrackers", ..row });
			continue;
		}
		let Some(source_id) = source_id_by_key(tx, &entry.source_id, report).await? else {
			report.entries.push(ReportEntry { reason: Some("source not installed"), ..row });
			continue;
		};
		let Some(provider) = provider else {
			report.entries.push(ReportEntry { reason: Some("tracker not supported"), ..row });
			continue;
		};
		let meta = manga_meta
			.get(&(entry.source_id.as_str(), entry.manga_id.as_str()))
			.map(|m| aib_manga_meta(m))
			.transpose()?;
		let manga_id = ensure_manga_row(tx, source_id, &entry.manga_id, meta.as_ref()).await?;
		// The binding's offset is added to local chapter numbers before pushing; the API's own bounds apply here too
		let chapter_offset = entry.chapter_offset.unwrap_or(0).clamp(-10_000, 10_000) as i32;
		dao::insert_link_if_absent(
			tx,
			&dao::NewTrackerLink {
				manga_id,
				user_id,
				provider: provider.as_str(),
				track_id: &entry.id,
				title: entry.title.as_deref().map(str::trim).filter(|t| !t.is_empty()),
				track_mode: track_mode_from_settings(&doc.settings, &entry.source_id, &entry.manga_id),
				chapter_offset,
			},
		)
		.await?;
		report.imported.trackers += 1;
		report.entries.push(row);
	}
	Ok(())
}
