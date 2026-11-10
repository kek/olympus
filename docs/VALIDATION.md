# Live validation

## 2026-11-10: native Codex coding and bounded repair

These are two small functional experiments, not a comparison against cooperative
or single-agent orchestration. Both used Pi SDK 1.5.1, native
`openai-codex/gpt-6.1-sol`, existing Pi OAuth, and Docker Desktop Linux containers.
No credentials were copied into the project.

The task was a restricted JSON canonicalizer: recursive UTF-16 code-unit key
ordering, exact integer preservation, explicitly specified float notation,
Unicode and JSON string escaping. It was not advertised as full RFC 8785.
Eight acceptance cases were sealed before either experiment and never sent to
models. Both experiments used the identical evaluator profile and corpus.

### Unseeded model proposals

| Candidate | Attempt | Accepted cases | Patch bytes |
|---|---:|---:|---:|
| Athena | 1 | 8/8 | 1,238 |
| Ares | 1 | 8/8 | 1,438 |

Athena won on independently measured patch size. Neither candidate needed repair.
Neither review produced a verified objection. Whole-contest elapsed time was
31.326 seconds, including proposal generation, evaluation, reviews and the fresh
winner rerun.

Contract seal:
`8db5501d2aacd4ce697223874fafb7f64b904e0090aba26a8a5f05b1061ef34d`

Local evidence directory: `var/live-codex-repair-1/`.

### Explicit fault injection followed by live Codex repair

The first candidate was a deterministic fixture, **not a Codex response**. We
changed the successful program's UTF-16 key ordering to Unicode code-point
ordering. The profile, task and acceptance cases remained unchanged. Only later
repair proposals and reviews used live Codex.

| Candidate | Seeded attempt | Codex repair attempt | Final patch bytes |
|---|---:|---:|---:|
| Athena | 7/8 | 8/8 | 1,238 |
| Ares | 7/8 | 8/8 | 1,238 |

Both repaired the bug on attempt two. Ares won the documented lexicographic
identity tie-break; this does not show superior code quality. Codex received the
current candidate plus aggregate counts and a static failure category, not case
inputs, expected output, raw program output or case indexes.

Each proposal sequence had at most three attempts with completion allowances
1,389 / 1,389 / 1,389 under the original reservation and a 120-second contest
deadline. Native Codex does not enforce that allowance server-side; the SDK
checks reported completion usage after generation. Reserved allowances are not
measurements of actual token consumption or billing.

Elapsed time was 29.222 seconds. It is not comparable to the first experiment as
a cost/speed result: the seeded first attempts did not call a model.

Contract seal:
`355d7bccf8e4294692f8d93cc3a3b7b01c9276be560919768c74f9f7abcfff5f`

Local evidence directory: `var/live-codex-repair-seeded-1/`.

### Independent verification

For both winners we:

1. Reconstructed the sealed baseline, including file modes.
2. Applied the exported unified patch in a separate temporary directory.
3. Checked the resulting bytes and modes against the evaluated candidate.
4. Recreated the identical evaluator profile from archived cases and source.
5. Ran all eight cases again in fresh containers and matched candidate/patch hashes.

Both passed 8/8. Fate's own final rerun also used distinct container execution
IDs from the successful proposal. No evaluator containers remained after cleanup.

Base revision: `45a028a183645a820e738f1f3ff368d0484d8a08`.
Image ID: `sha256:99019a77a48761e19493d1e77dc7891b9e390f783ac9ea5798264372a688185f`.

The local directories retain journals, `summary.json`, `winner.diff`,
`evidence.json` and `verification.json`. They remain under ignored `var/` because
journals contain private acceptance data. This report intentionally excludes the
case corpus, raw logs, credentials and authentication files.

### Conclusions and next measurement

The native Codex path, independent evaluation, bounded feedback-driven repair,
patch fidelity, winner revalidation and cleanup worked in these examples. A
seeded-fault repair validates the mechanism; it is not evidence of spontaneous
recovery from a model's own mistake or an advantage from rivalry.

Before comparing orchestration strategies, record provider-reported usage and
per-call elapsed time, distinguishing unavailable/interrupted usage from zero.
Then run multiple tasks and repetitions against an explicit baseline with matched
resource limits. These experiments alone support no claim about defect rates,
relative cost, latency improvements or downstream usefulness.

## Follow-up: metered native Codex smoke run

A fresh sum-of-integers contest used the same native Codex provider/model and
Docker confinement, with the new separate usage channel. Both proposals and both
reviews returned SDK usage: four recorded adapter invocations, complete recorded
coverage, no adapter errors and no reported output overruns. Ares won; its patch
passed the sealed cases and independent Fate rerun.

The SDK-reported subtotal was:
- `input`: 4,993
- `output`: 80
- `cacheRead`: 0
- `cacheWrite`: 0
- `totalTokens`: 5,073

Summed adapter elapsed time was 11,727 ms, including subprocess startup and
authentication. This is not whole-contest latency: concurrent invocation times
overlap. These are SDK reports, not independently measured tokens or a billing
amount. No monetary cost was inferred.

Local artifacts: `var/live-codex-metered-1/` (journal, usage summary, winning patch
and evaluator evidence). The original experiments' actual usage cannot be
retrofitted from their reserved allowances.

This smoke test validates the accounting path. It is still not a matched-budget
comparison, and establishes no quality or efficiency advantage from rivalry.
