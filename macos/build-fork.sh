#!/bin/bash
# Explicit fork build: never writes the installed official executable.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-${TMPDIR:-/tmp}/sumidoku-fork-target}
export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-4}
npm --prefix "$ROOT/webui" run check
npm --prefix "$ROOT/webui" run build
cargo build --manifest-path "$ROOT/Cargo.toml" --release -p sumidoku-server
mkdir -p "$ROOT/dist/fork"
cp "$CARGO_TARGET_DIR/release/sumidoku-server" "$ROOT/dist/fork/sumidoku-server"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import hashlib,json,subprocess,sys
root=Path(sys.argv[1]); binary=root/'dist/fork/sumidoku-server'
files=subprocess.check_output(['git','ls-files','-z','--cached','--others','--exclude-standard'],cwd=root).split(b'\0')
digest=hashlib.sha256()
for raw in sorted(set(files)):
    if not raw: continue
    path=root/raw.decode()
    if path.is_file(): digest.update(raw+b'\0'+path.read_bytes())
info={'variant':'fork','featureSet':'source-integrations-v1','upstreamVersion':'1.23.3',
      'databaseSchemaVersion':max(int(p.name.split('_')[0]) for p in (root/'crates/server/migrations').glob('*.sql')),
      'sourceRevision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
      'sourceTreeSha256':digest.hexdigest(),'sha256':hashlib.sha256(binary.read_bytes()).hexdigest()}
(root/'dist/fork/server-build.json').write_text(json.dumps(info,indent=2)+'\n')
PY
APP_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/sumidoku-fork-app.XXXXXX")
export SUMIDOKU_APP_OUTPUT="$APP_STAGE/Sumidoku.app"
SUMIDOKU_SERVER_VARIANT=fork SUMIDOKU_SERVER_BINARY="$ROOT/dist/fork/sumidoku-server" "$ROOT/macos/build-app.sh"
python3 - "$ROOT/dist/fork/native-build.json" "$SUMIDOKU_APP_OUTPUT" <<'PYAPP'
from pathlib import Path
import json,sys
Path(sys.argv[1]).write_text(json.dumps({'appPath':sys.argv[2]},indent=2)+'\n')
PYAPP
echo 'Fork and native client built. Use activate-fork.py for a backup-first local activation.'
