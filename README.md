# Olympus

An Elixir/OTP orchestration kernel where rivalry changes resource allocation.
Fate is autonomous: there is no human approval, override, force-merge, test-edit,
or favor-edit operation.

**Status:** runnable first vertical slice: bounded JSON-artifact tournaments.
This is not yet a general-purpose coding agent, repository merger, or deployment
system. The architecture deliberately separates those future effects from judgment.

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

The provider receives `maxTokens` capped to the god's allowance and the model's
limit; a second model request is forbidden. Truncated, failed, oversized or
non-object JSON output is rejected. Input tokens and provider-side billing remain
outside the completion allowance, as with the HTTPS adapter.

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
`rounds × contenders × max_bytes <= 1 MiB`, so accepted evidence fits journal
frames. Oaths are capped at 16 checks and 8 KiB per god.

## Trust boundary and limitations

“No human say over Fate” is a workflow property: no human votes, approval gates
or override endpoints. Operators with host/code/storage access can still alter
the running system. BEAM processes and hash chains are not a security boundary
against the host, malicious adapter code, or hostile processes in the same VM.
Model output is untrusted data; adapter implementations are trusted code.

This release verifies JSON data, not the truth of self-reported benchmarks.
A cost field is an objective value, not an independently measured runtime.
Production code execution requires an isolated evaluator and externally measured
evidence. See [the architecture](docs/ARCHITECTURE.md) for the design, recovery
semantics and remaining work.
