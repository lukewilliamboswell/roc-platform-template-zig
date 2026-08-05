#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root_dir"

bundle_arg="${1:-}"
work_dir=".bundle-url-test"
server_pid=""

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

rm -rf "$work_dir"
mkdir -p "$work_dir/examples"

if [ -z "$bundle_arg" ]; then
  bundle_output=$(./bundle.sh 2>&1)
  echo "$bundle_output"

  bundle_arg=$(printf '%s\n' "$bundle_output" | awk '/^Created:/ { print $2; exit }')
  if [ -z "$bundle_arg" ]; then
    echo "Error: could not find bundle path in bundle.sh output" >&2
    exit 1
  fi
fi

if [[ "$bundle_arg" == http://* || "$bundle_arg" == https://* ]]; then
  bundle_url="$bundle_arg"
else
  if [ ! -f "$bundle_arg" ]; then
    echo "Error: bundle file not found: $bundle_arg" >&2
    exit 1
  fi

  bundle_abs=$(python3 - "$bundle_arg" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve())
PY
)
  serve_dir="$(dirname "$bundle_abs")"
  bundle_name="$(basename "$bundle_abs")"
  port_file="$work_dir/http-port"

  python3 - "$serve_dir" "$port_file" <<'PY' &
import functools
import http.server
import socketserver
import sys

serve_dir, port_file = sys.argv[1], sys.argv[2]

class Server(socketserver.TCPServer):
    allow_reuse_address = True

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=serve_dir)

with Server(("127.0.0.1", 0), handler) as httpd:
    port = httpd.server_address[1]
    with open(port_file, "w", encoding="utf-8") as f:
        f.write(str(port))
    httpd.serve_forever()
PY
  server_pid=$!

  for _ in {1..100}; do
    if [ -s "$port_file" ]; then
      break
    fi
    sleep 0.1
  done

  if [ ! -s "$port_file" ]; then
    echo "Error: HTTP server did not start" >&2
    exit 1
  fi

  port="$(cat "$port_file")"
  bundle_url="http://127.0.0.1:${port}/${bundle_name}"

  python3 - "$bundle_url" <<'PY'
import sys
import urllib.request

url = sys.argv[1]
request = urllib.request.Request(url, method="HEAD")
with urllib.request.urlopen(request, timeout=10) as response:
    if response.status >= 400:
        raise SystemExit(f"bundle URL returned HTTP {response.status}: {url}")
PY
fi

echo "Testing examples against bundled platform: $bundle_url"

python3 - "$bundle_url" "$work_dir/examples" <<'PY'
from pathlib import Path
import sys

bundle_url, out_dir = sys.argv[1], Path(sys.argv[2])
source_dir = Path("examples")
replacement = f'platform "{bundle_url}"'
needles = [
    'platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/1.0.0/AnZoxzoGPtSGQ15EQh6pBeeaHJ7aizP9MQhK81dES3Uq.tar.zst"',
    'platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/0.9/8GdFEvQYS3TeAZxKvTzCLVdQiomweGtXcdZkXNDEeABq.tar.zst"',
    'platform "../platform/main.roc"',
]

rewritten = 0
for source in sorted(source_dir.glob("*.roc")):
    text = source.read_text(encoding="utf-8")
    for needle in needles:
        if needle in text:
            (out_dir / source.name).write_text(text.replace(needle, replacement), encoding="utf-8")
            break
    else:
        raise SystemExit(f"example does not use a recognized platform URL: {source}")
    rewritten += 1

if rewritten == 0:
    raise SystemExit("no examples found to test")
PY

python3 scripts/test.py --verbose --examples-dir "$work_dir/examples"
