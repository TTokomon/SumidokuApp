# Reviewed artifact qualification

The protected publication workflow requires `desktop-vVERSION.json` and its
`.json.sig` signed with the pinned publisher key. Missing or mismatched evidence
blocks publication. Community qualification uses the publisher key and can run
without an Apple certificate.

The exact-byte signed document must contain format `1`, status `passed`, the
reviewed `sourceRevision`, exact `version` and numeric `build`, `archiveSha256`,
`inventorySha256` for SHA256SUMS, and SHA-256 of the final `desktop-releases.json` and
`appcast.xml` as `catalogSha256` / `appcastSha256`, and successful `checks` for:
`native-community-roundtrip`, `package-security`, `update-policy`, `packaging`,
`frontend`, `required-ci`.

Record links to the actual reviewed test receipts and artifact inventory. Never
convert a failed/unrun test into `passed` to enable publication. Commit only the
public proof and signature; no private signing key, disposable account, session,
server configuration or database. Qualification is for exact immutable artifacts,
not a version label or checkbox. The workflow verifies the signed catalog and
archive and refuses test-scope, development or disabled-coordination apps.
