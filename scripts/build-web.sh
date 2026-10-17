#!/bin/zsh
# Build the shipped browser client, without starting a development server.
set -euo pipefail
root="${0:A:h:h}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v node >/dev/null || ! command -v npm >/dev/null; then
  print -u2 'Node.js and npm are required to build the web workspace.'
  exit 1
fi
if [[ ! -d "$root/web/node_modules" ]]; then
  print -u2 "Install pinned build dependencies first: npm --prefix '$root/web' ci"
  exit 1
fi
npm --prefix "$root/web" run build
python3 - "$root/web/dist" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
assert (root / 'index.html').is_file(), 'Web build has no entry point'
assert (root / 'THIRD_PARTY_NOTICES.txt').is_file(), 'Web dependency notices are missing'
files = sorted(p for p in root.rglob('*') if p.is_file() and p.name != 'integrity.json')
assert all(not p.is_symlink() for p in files), 'Web assets must be regular files'
record = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(root / 'integrity.json').write_text(json.dumps(record, indent=2) + '\n')
print(f'Web assets: {len(record)} files verified and recorded')
PY
