use super::repo;
use crate::{model::SourceRow, state::AppState};
use image::{ImageFormat, ImageReader, Limits};
use sha2::{Digest, Sha256};
use std::io::Cursor;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub(crate) const MAX_ICON_BYTES: u64 = 256 * 1024;
const CACHE_KEY_BYTES: usize = 32;
const FRESH_ICON: Duration = Duration::from_secs(24 * 60 * 60);
const RETRY_AFTER: Duration = Duration::from_secs(3 * 60);
static ACTIVE_ICONS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(4);
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

pub(crate) type Icon = (Vec<u8>, &'static str);

fn icon_mime(bytes: &[u8]) -> Option<&'static str> {
	match image::guess_format(bytes).ok()? {
		ImageFormat::Png => Some("image/png"),
		ImageFormat::Jpeg => Some("image/jpeg"),
		ImageFormat::WebP => Some("image/webp"),
		ImageFormat::Gif => Some("image/gif"),
		_ => None,
	}
}

async fn validate(bytes: Vec<u8>) -> Option<Icon> {
	tokio::task::spawn_blocking(move || {
		let mime = icon_mime(&bytes)?;
		let mut reader = ImageReader::new(Cursor::new(&bytes)).with_guessed_format().ok()?;
		let mut limits = Limits::default();
		limits.max_image_width = Some(1024);
		limits.max_image_height = Some(1024);
		limits.max_alloc = Some(16 * 1024 * 1024);
		reader.limits(limits);
		reader.decode().ok()?;
		Some((bytes, mime))
	}).await.ok().flatten()
}

async fn read_bounded(path: &Path, max: u64) -> Option<Vec<u8>> {
	let file = tokio::fs::File::open(path).await.ok()?;
	let metadata = file.metadata().await.ok()?;
	if !metadata.is_file() || metadata.len() > max {
		return None;
	}
	let mut bytes = Vec::with_capacity(metadata.len() as usize);
	file.take(max + 1).read_to_end(&mut bytes).await.ok()?;
	(bytes.len() as u64 <= max).then_some(bytes)
}

async fn local_icon(state: &AppState, source: &SourceRow) -> Option<Icon> {
	let path = tokio::fs::canonicalize(source.icon_path.as_deref()?).await.ok()?;
	let root = tokio::fs::canonicalize(state.config.sources_dir()).await.ok()?;
	if !path.starts_with(root) {
		return None;
	}
	validate(read_bounded(&path, MAX_ICON_BYTES).await?).await
}

async fn cache_icon(path: &Path, key: &[u8], bytes: &[u8]) -> std::io::Result<()> {
	if let Some(parent) = path.parent() {
		tokio::fs::create_dir_all(parent).await?;
	}
	let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
	let temporary = path.with_extension(format!("{}.{}.tmp", std::process::id(), sequence));
	let mut file = tokio::fs::OpenOptions::new().write(true).create_new(true).open(&temporary).await?;
	let result = async {
		file.write_all(key).await?;
		file.write_all(bytes).await?;
		file.flush().await?;
		drop(file);
		tokio::fs::rename(&temporary, path).await
	}.await;
	if result.is_err() {
		let _ = tokio::fs::remove_file(temporary).await;
	}
	result
}

pub(crate) async fn resolve(state: &AppState, source: &SourceRow) -> Option<Icon> {
	if let Some(icon) = local_icon(state, source).await {
		return Some(icon);
	}
	// Package provenance disambiguates repositories offering the same source key.
	let list = repo::repo_row(&state.pool, source.repo_id?).await.ok()?;
	let entry = repo::cached_entries(&list).into_iter()
		.find(|entry| entry.key == source.key && entry.version == source.version)?;
	let url = entry.icon_url?;
	let mut hash = Sha256::new();
	hash.update(source.version.to_be_bytes());
	hash.update(list.id.to_be_bytes());
	hash.update(list.fetched_at.unwrap_or_default().to_be_bytes());
	hash.update(url.as_bytes());
	let key = hash.finalize();
	let path = state.config.config_dir.join("source-icons").join(format!("{}.icon", source.id));
	let mut stale = None;
	if let Some(cached) = read_bounded(&path, MAX_ICON_BYTES + CACHE_KEY_BYTES as u64).await
		.filter(|bytes| bytes.starts_with(&key)) {
		let bytes = &cached[CACHE_KEY_BYTES..];
		let age = tokio::fs::metadata(&path).await.ok().and_then(|meta| meta.modified().ok())
			.and_then(|modified| modified.elapsed().ok());
		if bytes.is_empty() && age.is_some_and(|age| age < RETRY_AFTER) {
			return None;
		}
		if let Some(mime) = icon_mime(bytes) {
			let icon = (bytes.to_vec(), mime);
			if age.is_some_and(|age| age < FRESH_ICON) {
				return Some(icon);
			}
			stale = Some(icon);
		}
	}
	let Ok(_permit) = ACTIVE_ICONS.try_acquire() else { return stale };
	let icon = match repo::fetch_source_icon(&list.url, &url).await {
		Some(bytes) => validate(bytes).await,
		None => None,
	};
	if let Some((bytes, _)) = &icon {
		let _ = cache_icon(&path, &key, bytes).await;
	} else if stale.is_none() {
		let _ = cache_icon(&path, &key, &[]).await;
	}
	icon.or(stale)
}
