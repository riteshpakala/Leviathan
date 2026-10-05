# Property catalogue

What Leviathan's measurements show about how models answer, and what each property suggests as a layer or change in RaoLM.

Leviathan sees behaviour only: response text across temperatures and, where the host returns them, token log-probabilities. Nothing here claims to recover a model's weights or internals. An entry describes a regularity in what models write and argues for a design choice in RaoLM. RaoLM is at `/Users/ritesh/Documents/rao/repositories/RaoLM`; file references below are to that repository as of commit `37d9380`.

Rules for this file:

- An entry is **observed** only when an evidence file under `catalogue/evidence/` backs it. Until then it is a **candidate** and names the measurement that would confirm or refute it.
- Evidence from a model whose terms are not `permitted` may be catalogued. Its outputs still never enter a Thread.
- A property that has been made into a RaoLM change is **adopted**, with the commit. One refuted by evidence is **rejected**, and stays here with the evidence.

## Reading the evidence

`leviathan measure --set S --model C/M` writes `catalogue/evidence/<thread-slug>/<date>.json`. Samples are compared with the prompt's baseline, which is sample 0 at the lowest temperature. The fields:

| Field | Meaning |
| --- | --- |
| `byTemperature[].formKept`, `contentKept` | Mean share of the baseline's form words (function words) and content words a sample kept, per temperature |
| `byTemperature[].meanOverlap` | Mean share of tokens kept, over the longer of the two texts |
| `byTemperature[].divergent` | Samples sharing under half their tokens with the baseline: whole-response alternates |
| `byTemperature[].bitsPerFormWord`, `bitsPerContentWord` | Mean −log₂ p per word, from the host's log-probabilities; empty when the host returned none |
| `cutWords[]` | Expectations grouped by the function word that ends their stem, with mean confidence |
| `onsets[]` | How many areas, and how many broken expectations, first appear at each temperature |
| `areas` | Area counts: insertions, ones holding content, ones holding only form; mean variants and entropy |
| `passages[].lockedShare` | Share of a passage's words that every aligned sample kept |

An expectation is a stem cut at a function word (RaoLM's list in `TokenRoles`), followed by the run of content words after it. Its **support** is the aligned samples that kept every word of the stem. Its **confidence** is the share of those that also kept the answer.

## Entry template

```
### P-NNN: <the property, in one sentence>
- Status: candidate | observed | adopted | rejected
- Seen on: <models> × <prompt sets>
- Measurement: <the evidence fields, and the result that would confirm or refute it>
- Evidence: catalogue/evidence/<slug>/<date>.json, …
- Suggests for RaoLM: <the layer: what it takes in, where it sits, which files change>
- Bench: <the RaoLM bench or eval that would show it helps>
```

## What RaoLM cannot take yet

Found in RaoLM's source while building Leviathan. Each gap names the change that would close it. Until one closes, Leviathan writes around it as described.

1. **No document kind for harvested text.** `DocumentKind` in `Sources/RaoLMCore/Corpus/CorpusModels.swift` is a closed enum of synthetic kinds. Leviathan writes `transcript` by default; a prompt set can choose any other existing kind in its `set.json`. *Change:* add a `harvested` case.
2. **No fact kind for measured expectations.** `FactKind` in the same file is closed, and `Fact.negativePrompt` is required. Leviathan writes expectations to `expectations.jsonl` in the `Fact` shape, with an empty negative prompt. It writes them to `facts.jsonl` only when `export --fact-kind K` names a kind. *Change:* add an `expectation` kind. Let `FactEvaluator` (`Sources/RaoLMProvenance/FactEvaluator.swift`) skip the negative-prompt control when the negative prompt is empty.
3. **The loss mask is 0 or 1.** `RaoLoss.makeLossAndGrad` (`Sources/RaoLMTraining/RaoLoss.swift`) already computes `Σ loss·mask / Σ mask`, so a fractional mask works as a per-token weight with no change there. The mask is filled with 1 in `BatchSampler.swift` and `TokenStream.swift`. *Change:* have `TokenizedCorpus` read `weights.jsonl` and give each token the weight of the span holding its last byte. The convention is restated in each export's `thread.json`. The samplers then copy the weights into the mask.
4. **Sampling weight is per corpus only.** `TokenStream.Source.weight` (`Sources/RaoLMTraining/TokenStream.swift`) draws whole corpora by weight. Leviathan writes a weight per document and one per Thread to `thread.json`. *Change:* draw a document's windows in proportion to its weight. The per-Thread weight works today as a `TokenStream` source weight.
5. **Braid datasets need the generator's entity types.** `BraidDataset` and `MockWorld` (`Sources/RaoLMBraid/MockWorld.swift`) expect worlds, entities and crosslinks, so a Leviathan Thread cannot be fed with `raolm braid … --dataset`. Two routes work today:
   - `raolm train --corpus <thread>/snapshot.json` trains one model on the Thread.
   - `raolm corpus ingest <thread>` deposits the Thread into a running Thread node. The export directory is a `CorpusStore` directory.

   *Change:* a dataset source that takes Leviathan Threads as nodes, with crosslinks where two models answered the same prompt.

## Candidate properties

None of these has evidence yet. Each names what would confirm it.

### P-001: Form holds before content as temperature rises

- Status: candidate
- Measurement: at every temperature above 0, `formKept` exceeds `contentKept`. Confirmed if this holds for at least three models on two prompt sets. Refuted if the two track each other within 0.02.
- Suggests for RaoLM: the teacher's own uncertainty would be split the way RaoLM's credit is (`TokenRoles`: form to the commons, content to the Threads). That supports a form weight below 1 in `weights.jsonl`, and setting it from the measured ratio of form to content bits instead of the fixed 0.5. RaoLM's measurement before building found form to be 30–47% of tokens but 15–33% of bits.
- Bench: `bench-umbrella`, trained with fractional form weights against masks of 1. Compare the owner's credit on its facts' answers and the commons' credit on general text.

### P-002: Some function words set firmer expectations than others

- Status: candidate
- Measurement: `cutWords[].meanConfidence` differs by at least 0.15 between the firmest and loosest of the ten most frequent cut words, each with at least 30 supported expectations. The expected pattern: "in" and "of" before names and places are firm; "the" and "and" are loose.
- Suggests for RaoLM: a prior on the gate keyed by the preceding function word. After a firm cut word the braid should trust the Thread holding the fact; after a loose one, lean on the commons. It would sit in the gate update in `Sources/RaoLMProvenance/BraidMixer.swift` and `BraidedGenerator.swift` as a multiplier on the evidence each token contributes.
- Bench: `bench-gate` and `bench-question`, on the share of told answers credited to their source.

### P-003: The temperature at which content first diverges tracks how well the model knows it

- Status: candidate
- Measurement: on hosts that return log-probabilities, content in areas with a low onset carries more bits per word than locked content. Confirmed by a rank correlation of at least 0.3 between an area's `onsetTemperature` and the baseline's bits on its words, across at least 200 areas.
- Suggests for RaoLM: onset as a per-token difficulty signal. Uses include a curriculum that trains on locked content first, and calibrating `TokenTrace` confidence (`Sources/RaoLMCore/Citation/CitationModels.swift`), which the README reports as uncalibrated (calibration error 0.23).
- Bench: `raolm eval` calibration error before and after the confidence is fitted to onset.

### P-004: Whole-answer alternates start abruptly above a model-specific temperature

- Status: candidate
- Measurement: `byTemperature[].divergent` stays at 0 up to some temperature, then exceeds a quarter of the samples within one step of the plan.
- Suggests for RaoLM, in two parts:
  - A harvest rule: cap each model's temperature at the last step with no alternates, so a Thread's measurements are not diluted by a different mode.
  - Where a prompt has several modes, each should be its own document in a Thread rather than one blurred answer. That mirrors how RaoLM's trajectory treats a text that switches documents mid-way (`Sources/RaoLMCore/Braid/Trajectory.swift`).
- Bench: fact exactness of a node trained on mode-split documents against one trained on baselines only.

### P-005: Locked share depends on how open the prompt is

- Status: candidate
- Measurement: `passages[].lockedShare` is above 0.8 for factual prompt sets and below 0.4 for open-ended writing, on the same model.
- Suggests for RaoLM: a per-Thread retrieval weight. RaoLM already sets λ and τ per Thread from how its corpus traces itself (`Sources/RaoLMProvenance/SelfTrajectory.swift`). A Thread made from loosely worded answers should lean less on retrieval of exact wording, so its locked share is a cheap prior for λ before the self-trajectory is measured.
- Bench: `bench-umbrella` with λ from locked share against the self-trajectory's λ.

### P-006: Confident expectations behave like RaoLM's synthetic facts

- Status: candidate
- Measurement: export a Thread with `--fact-kind expectation`, after RaoLM accepts that kind (gap 2). Train a node on it and run `raolm eval`. Confirmed if candidate expectations (confidence ≥ 0.8, support ≥ 3) are answered exactly at least 20 points more often than the remaining expectations.
- Suggests for RaoLM: Leviathan as a source of fact sets drawn from real model text, so RaoLM's evaluation reaches beyond the synthetic Veldmar archive and the braid datasets.
- Bench: `raolm eval` exact answer and citation@1, split by candidate status.

### P-007: Answers that run on into a verb are less stable than names alone

- Status: candidate
- Measurement: among expectations whose answer ends in a word the system's lexical tagger marks as a verb ("Mador Halfell stood"), mean confidence is lower than among those ending in a noun.
- Suggests for RaoLM: stop answers at verbs, so expectations match the noun-phrase shape of RaoLM's facts. The cut stays at RaoLM's function words; only the answer's end changes. Note the cost: a tagger is a model, so the rule would no longer be a fixed list.
- Bench: candidate count and their exact-answer rate (P-006) with and without the verb stop.

## Observations

None yet. The only evidence so far comes from the mock server used to test Leviathan. Its answers were scripted, so it says nothing about a real model.
