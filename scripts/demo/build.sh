#!/bin/sh
# Builds a demo workspace from made-up text, against the stand-in host, so the app and the
# README's pictures can be shown without a real key, a real model or anyone's real writing.
#
#   scripts/demo/build.sh <workspace dir> <port>
#
# The stand-in host must be running on <port> (scripts/demo/mock_host.py). Keys come from
# environment variables, so nothing is written to the Keychain.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
workspace=$1
port=$2
leviathan="$root/.build/debug/leviathan"

export LEVIATHAN_ROOT="$workspace"
export OPENROUTER_API_KEY=sk-or-v1-demo-0000
export ANTHROPIC_API_KEY=sk-or-v1-demo-0000
mkdir -p "$workspace"
# Runs a step quietly; on failure shows what it said and stops.
quiet() {
    out=$("$@" 2>&1) || { printf '%s\nfailed: %s\n' "$out" "$*" >&2; exit 1; }
}

# Hosts: OpenRouter and Anthropic, both answered by the stand-in, one request at a time so the answers repeat run to run.
quiet "$leviathan" providers add --preset openrouter --base-url "http://127.0.0.1:$port/api/v1" --max-concurrent 1
quiet "$leviathan" providers add --preset anthropic --base-url "http://127.0.0.1:$port/v1" --max-concurrent 1
quiet "$leviathan" providers private openrouter --allow --source https://openrouter.ai/docs/features/provider-routing

# Models, filled from the host's list.
quiet "$leviathan" models add --provider openrouter --from-catalogue qwen/qwen3-32b
quiet "$leviathan" models add --provider openrouter --from-catalogue mistralai/mistral-small-3.2
quiet "$leviathan" models terms qwen/qwen3-32b --training-use permitted --licence Apache-2.0 --source https://huggingface.co/Qwen/Qwen3-32B
quiet "$leviathan" models add --provider anthropic --company anthropic --model claude-fable-5-1 --default-only --max-tokens 2048 \
    --input-price 10 --output-price 50

# A prompt set at the root.
quiet "$leviathan" prompts add --set writing --id harbour --text "Describe a harbour town at dusk in one paragraph."
quiet "$leviathan" prompts add --set writing --id ferry --text "Describe an old ferry crossing in one paragraph."
quiet "$leviathan" harvest --set writing --model qwen/qwen3-32b --samples 2

# A work: the made-up season, its studies, and two models' answers.
quiet "$leviathan" works import --work lamp-keeper --title "The Lamp Keeper" --author "Demo Author" \
    --narrative "$here/Narrative.json" --season "$here/season.json"
for kind in revise recall continue; do quiet "$leviathan" works study --work lamp-keeper --kind $kind; done
for kind in revise recall continue; do quiet "$leviathan" harvest --work lamp-keeper --set $kind --model qwen/qwen3-32b --samples 2; done
quiet "$leviathan" harvest --work lamp-keeper --set revise --model mistralai/mistral-small-3.2 --samples 2
for model in qwen/qwen3-32b mistralai/mistral-small-3.2; do quiet "$leviathan" derive --work lamp-keeper --set revise --model $model; done
quiet "$leviathan" works report --work lamp-keeper
echo "demo workspace at $workspace"
