# Leviathon

Leviathon harvests how models answer and turns the answers into Thread corpora that [RaoLM](https://lm.rao.nyc) can train on.

![A passage in the Mac app: twelve samples of one prompt, with locked text plain, form dimmed and the areas where samples diverged tinted. Area 0 is open, showing its two variants and the temperatures that wrote them.](README_Assets/passage.png)

For each prompt it does four things:

1. **Samples** the prompt across a temperature spread, through any OpenAI-compatible `/chat/completions` endpoint: local runtimes, hosted open-weight models, or closed APIs.
2. **Derives a passage.** Text that every sample kept is locked. Each span where samples diverge becomes an area that lists every variant and the temperatures that wrote it.
3. **Measures expectations and weights.** An expectation is a stem cut at one of RaoLM's function words; its confidence is how often the samples kept the content after it. Every token gets a loss weight: form weighs little, firm content 1, volatile content its share of the samples.
4. **Writes a Thread** for each model and prompt set in RaoLM's corpus format, with the weights and expectations beside it. It also writes evidence for the [property catalogue](catalogue/PROPERTIES.md), which records what the measurements suggest for RaoLM's design.

Leviathon sees behaviour, not weights. A model's Thread is exported only once you mark its terms `permitted`; closed APIs start as `prohibited`.

## Build and run

Requires macOS 15 or later and Swift 6.2 or later.

```bash
swift build
swift test
swift run leviathon --help
swift run LeviathonApp          # the Mac app, on the same core
```

## A run, end to end

```bash
leviathon providers add --preset ollama
leviathon models add --provider ollama --company qwen --model qwen2.5:7b
leviathon models terms qwen/qwen2.5-7b --training-use permitted --licence Apache-2.0
leviathon prompts add --set writing --id lighthouse --text "Tell me about the Hollow Lighthouse."
leviathon harvest --set writing --model qwen/qwen2.5-7b --dry-run     # see the request count
leviathon harvest --set writing --model qwen/qwen2.5-7b
leviathon passage --set writing --model qwen/qwen2.5-7b --prompt lighthouse
leviathon edit    --set writing --model qwen/qwen2.5-7b --prompt lighthouse --choose 2=1
leviathon export  --set writing --model qwen/qwen2.5-7b
leviathon measure --set writing --model qwen/qwen2.5-7b
```

`leviathon providers presets` lists the hosts it was written against: their base URLs, key variables, temperature ranges, and what their documentation leaves open.

Every command takes `--json`. Exit codes follow sysexits: 64 usage, 65 malformed file, 66 missing input, 69 host unavailable, 70 internal, 73 cannot write, 75 retries ran out, 77 terms do not permit, 78 configuration. A harvest states its request count before sending anything and refuses a plan larger than `--max-requests` (200 by default).

## The Mac app

`swift run LeviathonApp` opens the same workspace the command uses. The sidebar lists models by company, each with one Thread per prompt set, then the prompt sets and providers.

A Thread's **Harvest** tab states the request count before anything is sent and skips samples already in the transcript.

![The Harvest tab after a run: the plan on the left, twelve completed requests on the right.](README_Assets/harvest.png)

Its **Passages** tab is the view at the top of this page. Orange marks the baseline's wording and blue your choice. Click an area to see its variants, choose one or write your own, and save; the next export uses the edit.

A model's page holds what to request, its sampling limits and its terms. Its Threads are exported only once the terms say `permitted`.

![A model's page for a closed API, with training use set to prohibited.](README_Assets/model.png)

## Layout

```
providers.json                      hosts: base URL, key variable, extra fields (no secrets)
prompts/<set>/<prompt>.md           one prompt per file; _system.md and set.json per set
dataset/<company>/<model>/
  model.json                        what to request, sampling limits, terms
  transcripts.jsonl                 every generation: the system of record
  threads/<set>/
    passages/<prompt>.json          derived: locked text, areas, variants, expectations
    edits.jsonl                     your choices and your own words
    thread/                         the RaoLM corpus: manifest.json, documents/, facts.jsonl,
                                    snapshot.json, expectations.jsonl, weights.jsonl, thread.json
catalogue/
  PROPERTIES.md                     what the measurements suggest for RaoLM
  evidence/<thread>/<date>.json
```

To train RaoLM on a Thread: `raolm train --corpus dataset/<company>/<model>/threads/<set>/thread/snapshot.json`. RaoLM does not yet read the weights or expectations. [PROPERTIES.md](catalogue/PROPERTIES.md#what-raolm-cannot-take-yet) lists what each would need.

## Keys

A provider names the environment variable that holds its key. The app can also save a key to the Keychain, as can `leviathon providers key <id>`, which reads the key from stdin. Keys are never written to disk by Leviathon or printed. A binary rebuilt during development may lose access to a key it saved earlier; the environment variable always works.
