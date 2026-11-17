# Trusted desktop publication bootstrap

This infrastructure is separate from the desktop product PR and the upstream
server/Docker publisher. It neither merges the product PR nor installs an app.
Signing remains on the release maintainer's Mac using the existing Keychain key.
No private signing credential is needed by this workflow.

## Trust and privilege boundary

`desktop-publish.yml` defaults to `verify_only: true`. Its validation job has
**contents read / actions read**, no signing secrets and no publication environment.
It runs main-owned orchestration from the workflow commit. `policy.json` pins the
reviewed verifier at an immutable commit and lists the SHA-256 of every source
file. Only those files are read as Git blobs; no PR ref, checkout, build script,
package-manager install or product executable is used. The pinned Swift verifier
is compiled with an explicit source list. The qualification, catalog, archive,
app/server identity, signed bundle seal and inventory are authenticated before any
publication plan is produced. Only explicitly reviewed Stable/Beta artifacts in
main's policy are eligible. Updating a tooling or artifact pin requires review.

A separate publication job is reachable only with `verify_only: false`, from
`refs/heads/main`, after validation and protected `desktop-release` approval. That
job has contents write but runs **main-owned code only**. It downloads the immutable
verified artifact from the same workflow run, checks all hashes again and treats
its contents as data. It never compiles or imports PR/product code, runs an app,
extracts its app ZIP, or receives a signing key. Branch runs cannot execute this
job. The draft-creation workflow is also restricted to main.

Both release-asset and Actions ZIP transports are size-bounded and reject unexpected
files, duplicate paths and symlinks. GitHub authentication, transport and rate-limit
errors are not treated as missing releases. Published releases are immutable. The
publisher uploads exactly the verified bytes to a matching draft, checks GitHub's
asset SHA-256 values and rechecks the existing feed before publishing. A concurrent
feed change stops publication. Beta requires the authenticated public Stable feed
and publicly verified previously advertised assets. New catalogs retain prior entries.

## First Stable, then Beta

The first Stable is `1.3.0+community.1` (build 9), not a relabelled Beta. Its audited
Stable interface/design is based on `9fd09f5`; the sealed updater-only overlay is
from `6f92874`. It retains the exact original Stable backend payload, schema 37.
Its signed catalog/app/server hashes and archive bytes are pinned in main's policy.
The untouched original 1.3.0 (6) cannot update itself: a separately approved manual
bootstrap is still necessary. No current installation is replaced by this work.

The prepared `1.3.1-beta.1` (build 10) uses the same verifier and publication boundary.
Its app/backend are an exact-source pair. Its archive may be verified offline before
Stable publication, but online Beta publication validation intentionally refuses an
absent public Stable baseline. Previous native Stable → Beta → Restore Stable,
persistent-cookie, progress/download and backup evidence is reused when those
application inputs have not changed. Publication infrastructure tests are separate.

## Hosting: no DNS or separate service needed

The existing repository's GitHub Releases host the immutable archives. A dedicated
`desktop-updates` release hosts these already configured HTTPS endpoints:

- `https://github.com/TTokomon/SumidokuApp/releases/download/desktop-updates/appcast.xml`
- `https://github.com/TTokomon/SumidokuApp/releases/download/desktop-updates/desktop-releases.json`
- `https://github.com/TTokomon/SumidokuApp/releases/download/desktop-updates/desktop-releases.json.sig`

No Pages deployment, custom domain, DNS change or public backend is required. Those
endpoints do not become available until approved publication. The client verifies
publisher signatures and bounded HTTPS redirects; the server stays localhost-only.
The short catalog/signature replacement interval fails closed. Gatekeeper's per-app
Open Anyway procedure remains necessary for some initial community installations;
Developer ID/notarization is optional, never a community release gate.

## Safe verification and operator sequence

1. Review and land only this focused bootstrap. The product PR remains draft.
2. Test the registered workflow on the focused branch with `verify_only=true` and
   `policy_test=true`. This exercises hashes/compiler/permission guards with a
   read-only token. The publication job must be skipped. No release or draft is
   created by that test. Local validation may additionally consume signed files
   directly through `validate.py --artifacts`; it only reads GitHub for CI/feed state.
3. When draft staging is approved, run the main-owned `desktop-local-draft.yml` for
   the exact Stable version and source. It creates only an unpublished draft.
4. Upload the locally signed nine-file artifact set using the reviewed local staging
   tool. Never export the private key. Run `desktop-publish.yml` with the matching
   version/tag and **verify_only=true** to validate the actual remote draft end to end.
5. Request explicit first-publication approval. Only then run the main workflow with
   **verify_only=false** and approve the protected publication job. Verify the public
   archive, appcast and signed catalog before making Beta eligible.

No publication is implied by a passing test or a signed qualification document.
The bootstrap's local tests and workflow policy test do not claim that unpublished
remote draft retrieval or public feed hosting has already been exercised.
