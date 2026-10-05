#!/bin/sh
# Redraws the README's pictures into README_Assets/ from a demo workspace of made-up text.
# No window is shown and nothing touches the Keychain or a real host.
#
#   scripts/screenshots.sh [--dark]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
port=${LEVIATHAN_DEMO_PORT:-8777}
workspace=/tmp/leviathan-demo

cd "$root"
swift build --product leviathan > /dev/null
swift build --product LeviathanApp > /dev/null

if curl -s -o /dev/null "http://127.0.0.1:$port/"; then
    echo "port $port is already in use; set LEVIATHAN_DEMO_PORT to another" >&2
    exit 1
fi
python3 scripts/demo/mock_host.py "$port" &
host=$!
trap 'kill $host 2>/dev/null || true; wait $host 2>/dev/null || true; rm -rf "$workspace"' EXIT
# Wait for the stand-in host to answer.
tries=0
until curl -s -o /dev/null "http://127.0.0.1:$port/api/v1/models"; do
    kill -0 $host 2>/dev/null || { echo "the stand-in host stopped" >&2; exit 1; }
    tries=$((tries + 1))
    [ $tries -gt 50 ] && { echo "the stand-in host did not start on port $port" >&2; exit 1; }
    sleep 0.2
done

rm -rf "$workspace"
scripts/demo/build.sh "$workspace" "$port"

export LEVIATHAN_ROOT="$workspace"
export OPENROUTER_API_KEY=sk-or-v1-demo-0000
export ANTHROPIC_API_KEY=sk-or-v1-demo-0000
for screen in connect-host connect-key model-picker my-work revise-passage cost-guard; do
    .build/debug/LeviathanApp --snapshot "$screen" --out "README_Assets/$screen.png" "$@"
    echo "README_Assets/$screen.png"
done
