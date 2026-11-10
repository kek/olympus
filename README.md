# Olympus

An Elixir/OTP orchestration kernel where rivalry changes resource allocation.
Fate is autonomous: there is no human approval, override, force-merge, test-edit,
or favor-edit operation.

**Status:** JSON-artifact tournaments and isolated coding contests for small CLI
programs. Coding mode returns an independently tested patch and evidence; it never
merges or deploys. General-purpose repository agents and in-process unit-test
frameworks are not supported yet.

## Run

Requires Elixir 1.18+ and OTP 27+ (uses OTP's native JSON implementation).
No Hex dependencies, credentials, or network access are needed for the demo.

```sh
mix test
mix run examples/contest.exs
```

The demo persists to `var/demo.journal`. Running it again replays the settled
episode instead of spending its budget twice. Set `OLYMPUS_JOURNAL` to another
path to create a separate realm.

## Coding contest

Requires **a local Linux container engine, Python 3.10+, Git and Jujutsu**, in
addition to Elixir/OTP. Supported engines are Podman on Linux and Docker Desktop
(with Linux containers) on macOS. No runtime image is pulled automatically:

```sh
podman pull docker.io/library/python:3.12-alpine
mix run examples/coding_contest.exs
```

With Docker Desktop instead:

```sh
docker pull docker.io/library/python:3.12-alpine
OLYMPUS_CONTAINER_ENGINE=docker mix run examples/coding_contest.exs
```

This offline example creates a tiny throwaway repository under `var/coding-source`.
Athena and Ares propose replacements for `main.py`; independent containers run
the fixed sum-of-integers cases. Fate reruns the winner in fresh containers.
Outputs:

- `var/winner/patch.diff` — unified patch against the sealed base revision.
- `var/winner/evidence.json` — measured cases, hashes and container image ID.
- `var/coding.journal` — durable settlement, baseline and acceptance snapshots.

To use actual Pi models instead of the offline contenders, install the Pi
dependencies below, set `OLYMPUS_PI_PROVIDER` and `OLYMPUS_PI_MODEL`, and run the
same example with a **new journal path**:

```sh
OLYMPUS_JOURNAL=var/pi-coding.journal mix run examples/coding_contest.exs
```

This makes provider calls. Reusing a settled journal/task ID replays its result.

For your own task, configure a realm with `coding:`:

```elixir
coding: [
  engine: "podman",             # or "docker" for Docker Desktop
  repository: "/absolute/path/to/repository",
  revision: "immutable-commit-or-jj-revision",
  source_files: ["src/main.py"], # optional exact exported files; otherwise all tracked files
  editable: ["src/main.py"],    # exact paths, no globs
  fixtures: "/private/path/to/cases.json",
  image: "docker.io/library/python:3.12-alpine",
  command: ["python3", "-I", "-B", "/candidate/src/main.py"],
  case_timeout_ms: 3_000,
  max_attempts: 1               # sealed limit, 1–3; use 2 or 3 to enable repair
]
```

The fixture format is a JSON array:

```json
[
  {"stdin": "1 2\\n", "stdout": "3\\n", "exit_code": 0},
  {"stdin": "-3 1 8\\n", "stdout": "6\\n", "exit_code": 0}
]
```

Configure acceptance before submission. The profile is sealed into each task:
resolved commit, source bytes/modes, image ID/platform, test corpus, command,
environment, limits and evaluator implementation hash. Fixtures never enter the
candidate container or model prompt. Keep them outside exported source paths.

In coding mode, proposals contain only
`{"files":{"editable/path":"complete replacement text"}}`.
Olympus applies those bytes itself to separate private workspaces. Models do not
receive shell/edit tools, container sockets, credentials or acceptance files.
Submitted evaluation claims are rejected. Missing or failed acceptance always
blocks harmony, even if the prayer's ordinary checks would pass.

Use checks over `["evaluation", "passed"]` and, optionally, minimize
`["evaluation", "patch_bytes"]`. See the runnable example for a complete prayer.
Only successful CLI exits (`exit_code: 0`) and exact UTF-8 stdout matching are
supported. This does **not** safely run pytest/ExUnit/npm-test assertions inside
the candidate's process: hostile candidate code could fake those results.

Bounds: up to 64 source files / 256 KiB, 16 editable paths / 32 KiB replacement
text, 8 cases, 8 KiB input or expected output per case, 8 KiB combined observed
stdout/stderr, 100–10,000 ms per case. Containers use no network, read-only
root/source, unprivileged UID, no capabilities, no new privileges, one CPU,
256 MiB memory, 64 PIDs, and a 16 MiB temporary filesystem. New files are mode
0644; existing Git executable bits are preserved. Binary files, symlinks,
submodules, LFS pointers, deletions and mode-only edits are unsupported.

The journal archives acceptance cases and source; keep it private. Replays use
recorded decisions without rerunning code. A restart cuts unfinished epochs,
reaps realm-labeled orphan containers and removes stale workspaces. Podman uses
engine-level expiry. Docker creates the container first and arms a separate host
watchdog against its immutable ID before starting candidate code; that watchdog
survives controller death. Container confinement assumes a trusted engine/image/
kernel; it is not a VM security boundary. Arbitrary remote engines and
host-repository edits are unsupported.

### Bounded repair

Set `coding: [max_attempts: 3, ...]` to allow up to three sequential proposals
per contender per tournament round. The default is one attempt. To see a
deterministic offline fail → repair → pass:

```sh
OLYMPUS_MAX_ATTEMPTS=3 OLYMPUS_OUTPUT_DIR=var/repair-winner OLYMPUS_JOURNAL=var/repair-demo.journal mix run examples/coding_contest.exs
```

Prefix with `OLYMPUS_CONTAINER_ENGINE=docker` on Docker Desktop. The offline
fixture deliberately submits a bad first candidate; actual Pi models are not
forced to fail. The same attempt option works with the Pi provider variables.

Each contender's original proposal allowance is split into fixed positive
completion slices. They sum to that allowance; unused slices are not reassigned
or refunded. Calls and evaluations share the original absolute contest deadline.
The first passing candidate stops the sequence. Model errors, malformed edits,
evaluator errors and invalid/broken oaths terminate it without automatic retries.
Only independently measured candidate or contract failures permit repair.

A repair request contains the current candidate files, outstanding oaths and a
limited feedback object: aggregate pass counts and fixed failure categories.
It omits test inputs, expected/observed output, stderr, output hashes, case
indexes and numeric exit codes. Coding reviews get a similarly restricted
evaluation view. Full evidence remains in trusted journal/state, not model
context. Pass counts still form an adaptive oracle; this is bounded disclosure,
not a guarantee of test secrecy across unlimited tasks.

Models return only the paths to change at that step. Valid edits accumulate;
each evaluation reconstructs a fresh workspace from the original sealed baseline.
Committed oaths persist between attempts and rounds. A later malformed response
cannot erase a prior commitment or turn a failed candidate into a winner.

Inspect `result.rounds |> hd() |> Map.get(:candidates)`: each candidate has an
`attempts` audit with indexes, completion slices, statuses, measured artifacts
and validated oaths. Trusted progress snapshots preserve completed attempts and oaths through an
ordinary worker timeout, marking any in-flight attempt interrupted. Audit is
durable with the terminal settlement. An authority crash still cuts the pending thread; in-memory attempt details may be lost and
the reservation is conservatively spent. Individual attempts are not fsynced.

Coding admission includes audit space:
`rounds × contenders × max_bytes × (max_attempts + 1) <= 1 MiB`.
Use a new task ID or journal when changing the policy; settled tasks are replayed,
not retroactively rerun. The final winner still undergoes a fresh independent
evaluation. No merge or deployment is added.

`OLYMPUS_OUTPUT_DIR` changes the example's export directory (default
`var/winner`), so demonstrations need not replace a previous winner export.

### Coding verification

```sh
OLYMPUS_CONTAINER_TESTS=1 mix test
python3 -B -m unittest discover -s priv/coding -p 'test_*.py'
# Optional: full real-Pi-SDK → local mock provider → container → Fate integration:
OLYMPUS_CONTAINER_TESTS=1 npm test --prefix priv/pi
```

For Docker Desktop, prefix integration commands with `OLYMPUS_CONTAINER_ENGINE=docker`.
The Python suite then also checks expiry of an unattended container.
Plain `mix test` excludes container-dependent tests. The integration suite
requires the image above and verifies containment, spoofing resistance, patch
fidelity, cancellation, winner reruns and recovery. No paid credentials are needed.

## Use

```elixir
{:ok, realm} = Olympus.start_realm(
  journal: "var/olympus.journal",
  adapter: Olympus.Adapters.Demo
)

Olympus.pray(realm, %{
  "id" => "delivery-plan",
  "request" => "Produce the cheapest compatible plan.",
  "checks" => [
    %{"path" => ["compatible"], "op" => "eq", "value" => true}
  ],
  "objective" => %{"path" => ["cost"], "direction" => "min"},
  "rounds" => 3,
  "timeout_ms" => 5_000,
  "tokens" => 2_000,
  "max_bytes" => 65_536
})

Olympus.status(realm)
Olympus.events(realm)
Olympus.epic(realm)
```

Prayer IDs are unique within a realm. Invalid prayers produce no events.
Natural language supplies context, not an evaluation oracle: a request without
explicit supported checks is rejected. The checks define the task, while Fate's
fixed laws govern admission, scoring, spending, deadlines and settlement.
Nobody approves or edits a sealed thread.

### Real model adapter

`Olympus.Adapters.OpenAI` supports an OpenAI-compatible chat-completions endpoint:

```elixir
{:ok, realm} = Olympus.start_realm(
  journal: "var/models.journal",
  adapter: Olympus.Adapters.OpenAI,
  adapter_opts: [
    endpoint: "https://api.openai.com/v1/chat/completions",
    model: System.fetch_env!("OLYMPUS_MODEL"),
    api_key_env: "OPENAI_API_KEY"
  ]
)
```

Choose a model supporting `max_tokens` and JSON-object responses. No model is
selected silently, no request is retried, TLS is verified, redirects are disabled,
and credentials are never journaled. This adapter has not been tested against a
live provider. It buffers HTTP response bodies before checking their size; use a
trusted endpoint with upstream body limits. A cancelled local request cannot
guarantee cancellation of provider-side generation or billing.

### Pi adapter

`Olympus.Adapters.Pi` uses the **Pi SDK 1.5.1** in a disposable Node subprocess.
It reuses Pi's model catalog, `models.json`, API-key environment variables and
`auth.json` (including OAuth), without requiring a Pi CLI executable.

Install its locked dependencies with **Node 22.19+**:

```sh
npm ci --prefix priv/pi --ignore-scripts
npm test --prefix priv/pi
```

The SDK tests use a loopback mock provider; no credentials or paid calls are
needed. Mix must also be available for the cross-language integration test.
The ordinary `mix test` suite does not require the SDK installation or Node.

```elixir
{:ok, realm} = Olympus.start_realm(
  journal: "var/pi.journal",
  adapter: Olympus.Adapters.Pi,
  adapter_opts: [
    provider: System.fetch_env!("OLYMPUS_PI_PROVIDER"),
    model: System.fetch_env!("OLYMPUS_PI_MODEL")
    # agent_dir: "/path/to/.pi/agent",  # optional credential/model config directory
    # node: "/path/to/node"            # optional Node executable
  ]
)
```

To reuse Pi’s Codex login on a host with Docker Desktop:

```sh
OLYMPUS_CONTAINER_ENGINE=docker \
OLYMPUS_PI_PROVIDER=openai-codex OLYMPUS_PI_MODEL=gpt-6.1-sol \
OLYMPUS_JOURNAL=var/codex-coding.journal mix run examples/coding_contest.exs
```

By default the adapter uses `PI_CODING_AGENT_DIR`, then `~/.pi/agent`.
Authentication must be available **where Olympus runs**; a sandbox does not
automatically have access to the host's Pi credentials. No credentials are copied
by this adapter. Pi may refresh OAuth credentials in the selected directory.

Every invocation gets a fresh in-memory session and explicitly selected physical
model, with no tools, extensions, MCP, skills, prompt templates, context files,
automatic retries, compaction, or cache warming. This is an artifact proposal and
review adapter, not permission for Pi to edit the repository. Fate alone decides
acceptance. Pi model/auth configuration is trusted configuration and may include
credential commands or custom endpoints.

The stream wrapper sets `maxTokens` to the smaller of the allowance and model
limit; a second model request in the same invocation is forbidden. Repair uses
separate invocations with disjoint slices of the original proposal allowance.
APIs that support output limits
receive that cap. **Pi's native Codex endpoint does not forward a server-side
output cap**: Codex completion allowance is checked after generation, while local
deadlines and output-byte limits still apply. Provider-side generation or usage
may exceed that allowance. Truncated, failed, oversized or non-object JSON output
is rejected. Input tokens and provider-side billing remain outside the allowance.

SDK startup counts against Fate's deadline and can take several seconds **per
invocation**. Use a larger `timeout_ms` (e.g. `120_000`) and adequate completion
offerings for model-backed tournaments. Output bytes and elapsed time are bounded;
task death or expiry closes subprocess input, causing the bridge to exit.
Provider work may still outlive local cancellation.

To integrate another provider, implement `Olympus.Adapter.respond/2`.
Proposal response: `%{"artifact" => json_value, "oaths" => [optional_checks]}`.
Review response: `%{"objections" => [sealed_check_indexes]}`.
Adapters receive their god's identity, durable memory, domain, opponents, sealed
contract, completion-token allowance and remaining time.

## Mechanical mythology

| Myth | Implemented mechanism |
|---|---|
| Clotho | Closed contract compiler; canonical versioned SHA-256 seal |
| Lachesis | Typed predicates, numeric objective, final independent validation |
| Atropos | Whole-contest monotonic deadline; task cancellation; no late harmony |
| Eris | Parallel competing proposals, odd best-of-n majority tournament |
| Zeus | Settlement through Fate; no discretionary bypass |
| Enemy review | Weighted enmity routing; independently verified check-index challenges |
| Allied sponsor | Deterministic eligible ally of the reviewer's identity; not a subjective vote |
| Worship | Conserved 1,200 favor units; favor-weighted completion allowances |
| Styx | Persistent supplemental checks; breach excludes artifact and causes two-epoch coma |
| Nemesis | Fixed artifact, response, contract and aggregate evidence size limits |
| Ambrosia | Last 16 episode summaries, favor, relationships, oaths and generation |
| Lethe | Pathological enmity is reduced at a fixed threshold |
| Titanomachy | After three cut epochs, fresh-context challenger proposals; office inherited only after a Fate-approved majority win |
| Hermes | OTP process messaging and provider boundary |
| Homer | Deterministic epic rendered from the authoritative event journal |

The catalog includes Zeus, Athena, Ares, Hephaestus, Aphrodite, Hera, Apollo,
Hermes, Hades, Dionysus, Nemesis and Eris. Three compete by default; the rest can
review or sponsor. Domains enter model context; not every god has a bespoke
workflow. Mythic imagery is not evidence that rivalry outperforms cooperation.

## Contract vocabulary

Paths are arrays of string map keys or nonnegative array indexes; `[]` selects
the whole artifact. Missing paths fail every check, including `neq`.

- `exists`, `unique`: `path` and `op` only.
- `eq`, `neq`: strict JSON-value equality/inequality.
- `lte`, `gte`: numeric value and numeric bound.
- `length_lte`, `length_gte`: list length or Unicode string length.
- `contains`: list membership.

All other operations and unexpected fields are rejected. Objectives are numeric
paths with direction `min` or `max`; without one, candidates tie at zero and god
names break ties lexicographically.

Bounds: 128 checks, 32 path components, 64 JSON nesting levels, 128 KiB prayer
term, odd rounds 1–9, deadline 1–120,000 ms, completion allowance 1–100,000,
response/artifact limit 1–1,048,576 bytes. Realm admission additionally requires
`rounds × contenders × max_bytes <= 1 MiB`; coding mode additionally multiplies
by `max_attempts + 1` to account for attempt audit and final evidence. Oaths are capped at 16 checks and 8 KiB per god.

## Trust boundary and limitations

“No human say over Fate” is a workflow property: no human votes, approval gates
or override endpoints. Operators with host/code/storage access can still alter
the running system. BEAM processes and hash chains are not a security boundary
against the host, malicious adapter code, or hostile processes in the same VM.
Model output is untrusted data; adapter implementations are trusted code.

Plain artifact mode still does not verify self-reported costs or benchmarks.
Coding mode independently measures sealed CLI acceptance cases and patch bytes;
passing a finite case corpus does not prove general correctness. See
[the architecture](docs/ARCHITECTURE.md) for recovery semantics and remaining work.
