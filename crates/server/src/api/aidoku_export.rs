//! Reverse Aidoku transfer for progress and its restore dependencies only.
use super::backup::{BackupProgress, read_backup_progress};
use crate::error::{ApiError, ApiResult};
use crate::state::AppState;
use axum::Extension;
use axum::body::Bytes;
use axum::extract::{Query, State};
use axum::http::header;
use axum::response::{IntoResponse, Json, Response};
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub(super) const BODY_MAX: usize = 32 * 1024 * 1024;
const MAX_ROWS: usize = 100_000;
const MAX_AGE: Duration = Duration::from_secs(24 * 60 * 60);
const INCLUDED: [&str; 4] = ["chapters", "history", "readingSessions", "updates"];
const OMITTED: [&str; 8] = [
	"manga",
	"library",
	"categories",
	"trackItems",
	"vocabulary",
	"sources",
	"sourceLists",
	"settings",
];

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportQuery {
	#[serde(default)]
	complete_backup: bool,
	preview_fingerprint: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TargetBackup {
	date: plist::Date,
	manga: Vec<MangaIdentity>,
	chapters: Vec<Chapter>,
	history: Vec<History>,
	reading_sessions: Vec<ReadingSession>,
	updates: Vec<Update>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MangaIdentity {
	source_id: String,
	id: String,
}

type Identity<'a> = (&'a str, &'a str, &'a str);

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Chapter {
	source_id: String,
	manga_id: String,
	id: String,
	lang: String,
	title: Option<String>,
	scanlator: Option<String>,
	url: Option<String>,
	chapter: Option<f32>,
	volume: Option<f32>,
	date_uploaded: Option<plist::Date>,
	thumbnail: Option<String>,
	locked: Option<bool>,
	source_order: i16,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct History {
	source_id: String,
	manga_id: String,
	chapter_id: String,
	date_read: plist::Date,
	progress: Option<i16>,
	total: Option<i16>,
	completed: bool,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReadingSession {
	source_id: String,
	manga_id: String,
	chapter_id: String,
	start_date: plist::Date,
	end_date: plist::Date,
	pages_read: i16,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Update {
	source_id: String,
	manga_id: String,
	chapter_id: String,
	date: plist::Date,
	viewed: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ExportBackup<'a> {
	date: plist::Date,
	name: &'static str,
	chapters: &'a [Chapter],
	history: Vec<History>,
	reading_sessions: &'a [ReadingSession],
	updates: &'a [Update],
}

fn validate_target(target: &TargetBackup, now: SystemTime) -> ApiResult<()> {
	if !now.duration_since(target.date.into()).is_ok_and(|age| age <= MAX_AGE) {
		return Err(ApiError::bad_request(
			"Choose an Aidoku backup made in the last 24 hours.",
		));
	}
	if [
		target.manga.len(),
		target.chapters.len(),
		target.history.len(),
		target.reading_sessions.len(),
		target.updates.len(),
	]
	.into_iter()
	.any(|count| count > MAX_ROWS)
	{
		return Err(ApiError::payload_too_large(
			"The Aidoku backup contains too many records.",
		));
	}
	let manga: HashSet<_> = target
		.manga
		.iter()
		.map(|m| (m.source_id.as_str(), m.id.as_str()))
		.collect();
	if manga.is_empty()
		|| manga.len() != target.manga.len()
		|| manga
			.iter()
			.any(|(source, manga)| !valid_key(source) || !valid_key(manga))
	{
		return Err(ApiError::bad_request(
			"The Aidoku backup must contain unique manga identities.",
		));
	}
	let mut chapters = HashSet::new();
	for row in &target.chapters {
		if !manga.contains(&(row.source_id.as_str(), row.manga_id.as_str()))
			|| !valid_key(&row.id)
			|| !chapters.insert((row.source_id.as_str(), row.manga_id.as_str(), row.id.as_str()))
			|| row.lang.trim().is_empty()
			|| [row.chapter, row.volume].into_iter().flatten().any(|n| !n.is_finite())
			|| [row.url.as_deref(), row.thumbnail.as_deref()]
				.into_iter()
				.flatten()
				.any(|url| !safe_metadata_url(url))
		{
			return Err(ApiError::bad_request(
				"A chapter has invalid metadata, a duplicate identity or no parent manga.",
			));
		}
	}
	if chapters.is_empty() {
		return Err(ApiError::bad_request(
			"Include the full Aidoku chapter catalog in the backup.",
		));
	}
	let mut history = HashSet::new();
	for row in &target.history {
		let key = history_key(row);
		if !chapters.contains(&key) || !history.insert(key) {
			return Err(ApiError::bad_request(
				"An Aidoku history entry has a duplicate identity or no chapter.",
			));
		}
	}
	for row in &target.reading_sessions {
		let key = (row.source_id.as_str(), row.manga_id.as_str(), row.chapter_id.as_str());
		if !history.contains(&key)
			|| row.pages_read <= 0
			|| SystemTime::from(row.end_date) <= SystemTime::from(row.start_date)
		{
			return Err(ApiError::bad_request(
				"An Aidoku reading session has invalid values or no matching history.",
			));
		}
	}
	if target
		.updates
		.iter()
		.any(|row| !chapters.contains(&(row.source_id.as_str(), row.manga_id.as_str(), row.chapter_id.as_str())))
	{
		return Err(ApiError::bad_request("An Aidoku update has no matching chapter."));
	}
	Ok(())
}

fn valid_key(key: &str) -> bool {
	!key.trim().is_empty() && key.len() <= 1024 && !key.contains(char::is_control)
}

fn safe_metadata_url(url: &str) -> bool {
	if url.is_empty() {
		return true;
	}
	url::Url::parse(url).is_ok_and(|url| {
		matches!(url.scheme(), "https" | "http")
			&& url.host_str().is_some()
			&& url.username().is_empty()
			&& url.password().is_none()
			&& url.query().is_none()
			&& url.fragment().is_none()
	})
}

fn history_key(row: &History) -> Identity<'_> {
	(&row.source_id, &row.manga_id, &row.chapter_id)
}

fn reading_progress(row: &BackupProgress) -> bool {
	row.last_page_read != 0 || row.is_read || row.last_read_at.is_some()
}

fn build_history(
	target: &TargetBackup,
	progress: &[BackupProgress],
	verified: &HashSet<Identity<'_>>,
	corrections: &HashSet<Identity<'_>>,
) -> ApiResult<(Vec<History>, usize)> {
	let chapters: HashSet<Identity<'_>> = target
		.chapters
		.iter()
		.map(|p| (p.source_id.as_str(), p.manga_id.as_str(), p.id.as_str()))
		.collect();
	let original: HashMap<Identity<'_>, _> = target.history.iter().map(|row| (history_key(row), row)).collect();
	let session_keys: HashSet<Identity<'_>> = target
		.reading_sessions
		.iter()
		.map(|s| (s.source_id.as_str(), s.manga_id.as_str(), s.chapter_id.as_str()))
		.collect();
	let mut output = Vec::new();
	let mut included = HashSet::new();
	for row in progress.iter().filter(|row| reading_progress(row)) {
		let key = (
			row.source_key.as_str(),
			row.manga_key.as_str(),
			row.chapter.key.as_str(),
		);
		if !verified.contains(&key) || !chapters.contains(&key) {
			return Err(ApiError::bad_request(
				"Some Sumidoku progress has no exact, supported chapter in the Aidoku backup. Export is blocked.",
			));
		}
		let date = row
			.last_read_at
			.and_then(|secs| u64::try_from(secs).ok())
			.and_then(|secs| UNIX_EPOCH.checked_add(Duration::from_secs(secs)))
			.map(plist::Date::from)
			.or_else(|| original.get(&key).map(|history| history.date_read))
			.ok_or_else(|| ApiError::bad_request("A reading record has no reliable date for an Aidoku restore."))?;
		let page = i16::try_from(row.last_page_read)
			.ok()
			.filter(|page| *page >= 0)
			.ok_or_else(|| ApiError::bad_request("A saved page position is outside Aidoku's supported range."))?;
		if let Some(old) = original.get(&key)
			&& !corrections.contains(&key)
			&& SystemTime::from(old.date_read)
				.duration_since(date.into())
				.is_ok_and(|age| age >= Duration::from_secs(1))
		{
			return Err(ApiError::bad_request(
				"Aidoku has newer reading history. Import and review the fresh backup before exporting.",
			));
		}
		let total = i16::try_from(row.chapter.page_count)
			.ok()
			.filter(|total| *total > 0)
			.or_else(|| original.get(&key).and_then(|history| history.total));
		if total.is_some_and(|total| total > 0 && page >= total) {
			return Err(ApiError::bad_request(
				"A saved page position exceeds the known chapter layout.",
			));
		}
		output.push(History {
			source_id: row.source_key.clone(),
			manga_id: row.manga_key.clone(),
			chapter_id: row.chapter.key.clone(),
			date_read: date,
			progress: Some(page),
			total,
			completed: row.is_read,
		});
		included.insert(key);
	}
	let mut removed_count = 0;
	for key in original.keys().filter(|key| !included.contains(*key)) {
		if !corrections.contains(key) || session_keys.contains(key) {
			return Err(ApiError::bad_request(
				"Export would lose Aidoku history or a reading session. Import the latest backup or keep history unchanged.",
			));
		}
		removed_count += 1;
	}
	Ok((output, removed_count))
}

pub async fn export_aidoku(
	State(state): State<Arc<AppState>>,
	Extension(user): Extension<crate::auth::AuthUser>,
	Query(query): Query<ExportQuery>,
	body: Bytes,
) -> ApiResult<Response> {
	let loopback = state
		.config
		.addr
		.parse::<SocketAddr>()
		.is_ok_and(|addr| addr.ip().is_loopback());
	if !loopback {
		return Err(ApiError::unsupported_501(
			"Aidoku export requires a localhost-only Sumidoku instance.",
		));
	}
	let fixture_enabled =
		cfg!(debug_assertions) && std::env::var("SUMIDOKU_AIDOKU_EXPORT_FIXTURE").as_deref() == Ok("1");
	if query.preview_fingerprint.is_some() && !fixture_enabled {
		return Err(ApiError::unsupported_501(
			"Aidoku export download is gated until official restore testing passes.",
		));
	}
	if !query.complete_backup {
		return Err(ApiError::bad_request(
			"Confirm the backup includes manga, chapters, history, reading sessions and updates.",
		));
	}
	static ACTIVE_EXPORTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);
	let permit = ACTIVE_EXPORTS
		.try_acquire()
		.map_err(|_| ApiError::too_many_requests("another Aidoku export is in progress"))?;
	let (target, input_hash, _permit) = tokio::task::spawn_blocking(move || {
		let target: TargetBackup = plist::from_bytes(&body).map_err(|_| {
			ApiError::bad_request(
				"Choose a complete Aidoku backup with manga, chapters, history, reading sessions and updates.",
			)
		})?;
		validate_target(&target, SystemTime::now())?;
		Ok::<_, ApiError>((target, Sha256::digest(&body), permit))
	})
	.await
	.map_err(|_| ApiError::internal("Aidoku export validation failed"))??;

	let mut tx = state.pool.begin().await?;
	let progress = read_backup_progress(&mut *tx, user.id).await?;
	let eligible: Vec<(String, String, String)> = sqlx::query_as(
		"SELECT s.key, m.key, c.key FROM chapter c JOIN manga m ON m.id = c.manga_id JOIN source s ON s.id = m.source_id
		 WHERE s.kind = 'aidoku' AND c.trashed_at IS NULL",
	).fetch_all(&mut *tx).await?;
	let verified: HashSet<_> = eligible
		.iter()
		.map(|(s, m, c)| (s.as_str(), m.as_str(), c.as_str()))
		.collect();
	let mut corrections = HashSet::new();
	for key @ (source, manga, chapter) in target.history.iter().map(history_key) {
		let marker = crate::server_state::aidoku_progress_key(user.id, source, manga, chapter);
		if verified.contains(&key) && crate::server_state::get(&mut *tx, &marker).await?.is_some() {
			corrections.insert(key);
		}
	}
	tx.rollback().await?;

	let (history, removed_count) = build_history(&target, &progress, &verified, &corrections)?;
	let counts = (
		target.chapters.len(),
		history.len(),
		target.reading_sessions.len(),
		target.updates.len(),
	);
	let previous: HashMap<_, _> = target.history.iter().map(|row| (history_key(row), row)).collect();
	let added_count = history
		.iter()
		.filter(|row| !previous.contains_key(&history_key(row)))
		.count();
	let changed_count = history
		.iter()
		.filter(|row| {
			previous.get(&history_key(row)).is_some_and(|old| {
				row.completed != old.completed
					|| row.progress != old.progress
					|| row.total != old.total
					|| row.date_read != old.date_read
			})
		})
		.count();
	let output = ExportBackup {
		date: target.date,
		name: "Sumidoku reading progress",
		chapters: &target.chapters,
		history,
		reading_sessions: &target.reading_sessions,
		updates: &target.updates,
	};
	let mut binary = Vec::new();
	plist::to_writer_binary(&mut binary, &output).map_err(|_| ApiError::internal("Aidoku export encoding failed"))?;
	if binary.len() > BODY_MAX {
		return Err(ApiError::payload_too_large("Aidoku export exceeded its size limit."));
	}
	let digest = Sha256::new().chain_update(input_hash).chain_update(&binary).finalize();
	let fingerprint = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest);
	if let Some(expected) = query.preview_fingerprint {
		if expected != fingerprint {
			return Err(ApiError::conflict(
				"aidoku_preview_changed",
				"The Aidoku backup or Sumidoku progress changed. Review the export again.",
			));
		}
		return Ok((
			[
				(header::CONTENT_TYPE, "application/octet-stream"),
				(
					header::CONTENT_DISPOSITION,
					"attachment; filename=\"sumidoku-aidoku-progress.aib\"",
				),
				(header::CACHE_CONTROL, "no-store"),
			],
			binary,
		)
			.into_response());
	}
	Ok(([(header::CACHE_CONTROL, "no-store")], Json(serde_json::json!({
		"previewFingerprint": fingerprint, "included": INCLUDED, "omitted": OMITTED, "fixtureDownloadEnabled": fixture_enabled,
		"chapters": counts.0, "history": counts.1, "readingSessions": counts.2, "updates": counts.3,
		"removedHistory": removed_count, "addedHistory": added_count, "changedHistory": changed_count,
	}))).into_response())
}
