# Olympus architecture and design

## Decision: Fate has no voters

Humans submit bounded problems and offerings. They do not approve specifications,
choose winners, adjudicate appeals, alter active tests or waive deadlines. Gods
also have no such powers. Clotho is a deterministic compiler, not an LLM asking a
human to ratify its interpretation.

A prayer must already express machine-verifiable acceptance conditions. Free
text without those conditions fails closed. This intentionally limits the first
release instead of claiming that arbitrary natural-language intent can be
converted into deterministic truth.

Contract laws are compiled into the application and versioned in the seal.
Changing the program is a change to the trusted computing base, not a supported
orchestration operation. A law migration must not reinterpret past rulings.

## Topology

```
Olympus.Supervisor (rest_for_one)
├── Registry                    identity routing
├── Task.Supervisor             disposable adapter executions
├── Pantheon DynamicSupervisor
│   └── God GenServers          domain + disposable context
└── Realms DynamicSupervisor
    └── Fate GenServers         serialized authority, clock, journal, durable memory
```

Fate is outside the god supervision subtree. A god cannot negotiate a test or
obtain authority by crashing. Registry failure restarts dependent infrastructure;
a Fate restart replays its journal and cuts any interrupted thread.

The current deployment is one BEAM node, one writer per journal. A global
registration fences duplicate writers to the same expanded path in that node.
Symlink aliases, unrelated nodes and multiple OS processes are not supported as
concurrent writers. Each deployment must exclusively own its journal directory.

## Lifecycle

1. **Compile:** validate a closed string-keyed JSON schema, reject unknown fields,
   apply fixed limits, include law version and compute a canonical digest.
2. **Admit:** require a fresh episode ID and a bounded aggregate evidence size.
   Increment epoch and allocate favor-weighted completion reservations.
3. **Seal:** append and fsync `thread_spun`, including contract and reservations,
   before invoking any adapter.
4. **Compete:** launch contenders concurrently. Atropos supplies one deadline for
   the entire episode, not a fresh timeout per call or round.
5. **Measure:** validate response structure in the disposable task; independently
   evaluate artifacts and outstanding oaths in Fate.
6. **Challenge:** route each artifact to the strongest eligible enemy. The enemy
   names failed sealed-check indexes. Lachesis verifies every allegation. False
   allegations cannot veto a valid artifact; silence cannot block settlement.
7. **Score:** among eligible candidates, highest objective score wins the round.
   Identity provides a stable tie break. A strict majority of the configured
   best-of-n is required; no plurality winner is promoted.
8. **Sponsor:** require an eligible ally of the final reviewer's identity.
   Sponsorship is a fixed graph eligibility gate in this release, not another
   model's discretionary approval.
9. **Revalidate:** check the selected artifact against the sealed contract and all
   commitments accumulated during the episode. Check time again after evaluation.
10. **Settle:** update conserved favor, memory, oaths, sanctions and champion, then
    append and fsync `harmony` or `thread_cut`. Only then reply to the caller.

A cut changes no champion and awards no favor. Budget already reserved for an
invocation is not refunded on invalid output, crashes or timeout.

## Favor and offerings

Every identity starts with 100 favor, giving a fixed total of 1,200. An accepted
winner receives one unit from each other identity with more than one unit. A
one-unit floor avoids permanent monopoly. The transfer is atomic in the terminal
event and conserves the total.

Completion reservations are integer proportional shares of the prayer's token
offering. Rounding remainders go to sorted identities. Comatose gods receive no
reservation and cannot review or sponsor. An invocation consumes at most its
identity's remaining reservation, with nominal per-call allowance equal to
`reservation / (rounds × 2)`. Unused reservations expire at epoch end.

These are completion-token allowances, not an exact compute, currency or input
context budget. Provider enforcement of `max_tokens` is trusted. The runtime
cannot infer actual token usage from arbitrary adapters. Fixed prompt and memory
bounds limit context growth but do not implement model-specific input accounting.

The first implementation rewards independently accepted winners. It records
verified review findings and adjusts enmity, but does not yet transfer favor for
reviews or measure downstream adoption. Those require an explicit scoring law.

## Oaths, memory and succession

An adapter may declare additional closed predicates over its own artifacts.
They cannot replace sealed checks. Accepted oath declarations carry forward
between rounds and across epochs. Breaking one disqualifies the god for that
episode and excludes it from allocations, reviews and sponsorship for the next
two epochs. Invalid oath declarations cannot evict existing commitments.

Durable ambrosia stores 16 episode summaries plus oaths, favor and generation.
Enmity changes on verified faults; at weight -20, Lethe reduces it to -10 at
settlement. This bounds pathological relationship reinforcement.

Three consecutive cut epochs trigger fresh-context challenger proposals:
memory is empty and generation is incremented for the trial. Oaths remain
binding. The incumbent's durable generation changes only if that identity wins
Fate's unchanged majority trial. This is a minimal succession mechanism, not
simultaneous incumbent/challenger rewrite branches or an entire subtree coup.

## Journal and recovery

Each event is a length-prefixed, versioned ETF frame with sequence number and
SHA-256 chain digest. Writes are synced before acknowledgment. Safe ETF decoding
uses the preloaded fixed application atom vocabulary; external model data remains
JSON with string keys. Journals are local trusted state, not uploaded interchange
files.

Events contain bounded authority snapshots without the accumulated episode map.
Terminal evidence is stored once. Replay rebuilds the episode index and restores
recorded decisions without contacting providers or consulting wall-clock time.
Event sequence validation is linear. The in-memory audit index and journal still
grow with lifetime history; compaction and streaming storage are future work.

Checksums detect corruption and reordering relative to the retained chain.
They do not prevent an operator rewriting the whole chain or removing its suffix.
There is no external immutable checkpoint in this version.

An unfinished sealed epoch is cut on restart and its ID remains consumed. Its
completion reservations are reported as fully spent, conservatively accounting
for requests that may already have reached providers. No automatic retry can
double-spend that episode. Torn frames, corrupt hashes and unknown journal
versions prevent startup. Repair is deliberately not an automatic policy choice.

A process failure before the terminal fsync leaves an interrupted thread.
Failure after fsync but before reply is resolved by querying/replaying the episode,
not rerunning it. This is durable local decision making, not distributed consensus
or exactly-once provider execution. Fsync does not by itself guarantee survival
of every possible directory/filesystem or hardware failure.

## Threat model

LLM output may lie, collude, stall, invent approvals, claim nonexistent checks,
or submit malformed values. None is authoritative. All acceptance checks and
review allegations are independently evaluated. Output validation runs in
deadline-controlled tasks; final bounded verification runs in Fate.

Adapters are trusted executable plugins. BEAM offers fault containment, not
isolation from malicious Elixir code, process introspection or unrestricted
filesystem access. A production deployment must put model-facing workers and
arbitrary code execution outside the authority VM, with capability-scoped IPC.
Operators with root access remain outside the software's enforcement boundary.

The HTTPS adapter verifies certificates, disables redirects, does not retry,
monitors task death to cancel outstanding local HTTP requests, and accepts only
JSON-object responses. It buffers responses before size validation, so an
upstream response-size limit is required. Provider generation/billing may outlive
local cancellation. No live-provider verification has been performed.

## Pi SDK adapter

`Olympus.Adapters.Pi` owns no authority. A monitored port guardian starts the
locked Pi SDK 1.5.1 bridge under Node 22.19+, writes one JSONL request and collects
one bounded JSON reply plus successful exit status. Deadline, oversized output,
failed exit or caller death closes the port. The bridge exits when stdin closes;
it never spawns tools or descendants. Neither prompts nor credentials are passed
in process arguments. Only proposal data returns to Fate.

Each request constructs an in-memory Pi session with an explicit resource loader
that returns no extensions, skills, templates or context files. No built-in,
custom or MCP tools are enabled. Settings disable provider/agent retries,
compaction and cache warming. Physical model selection is explicit; there is no
fallback model or routing trial. The stream wrapper sets `maxTokens`, removes
model sampling overrides that could replace that cap, and rejects any second
provider stream for the reservation. Non-success stop reasons and malformed
JSON fail closed.

Pi's runtime resolves credentials using the selected agent directory and
environment. OAuth refresh may write that directory; it is not mounted or copied
from the host by Olympus. Pi auth/model configuration is trusted and may execute
credential commands. Child environment inheritance includes provider secrets, as
needed for authentication; no secret is included in journaled adapter responses.

The adapter starts a fresh process per invocation, so SDK startup overhead counts
against the whole-contest deadline. No durable Pi sessions are stored; ambrosia
remains Fate-owned. Tests exercise the real SDK through a loopback compatible
provider, including the complete Elixir subprocess path, without live credentials.
This is still not an execution sandbox for repository-editing agents.

## Verification and roadmap

Tests cover contract seals, typed predicates, missing paths, invalid schemas,
independent acceptance, verified vs fabricated review challenges, deterministic
ties, strict majority, conserved favor, tiny budgets, deadlines, adapter crashes,
replay, duplicate IDs, interrupted epochs, writer fencing, corrupt journals,
bounded oath memory, coma, Lethe and generation inheritance.

The offline example exercises the public supervised entry point and cold-VM
journal replay. It demonstrates mechanics, not empirical gains from rivalry.

Next stages, without weakening Fate:

1. **External evaluator:** immutable evaluator images, read-only sealed fixtures,
   isolated workspaces, network policy, measured tests/type checks/benchmarks.
   Workers never write acceptance definitions.
2. **Repository artifacts:** content-addressed patches, base revisions, protected
   merge effect intents and an idempotent, fenced Zeus executor. No host repository
   mutation occurs in the present release.
3. **Full succession trials:** incumbent and fresh-generation workspaces compete
   concurrently under the same evaluator; transfer office only after measured
   improvement.
4. **Measured economics:** provider usage reconciliation, input-token reservations,
   bounded downstream adoption rewards, explicitly priced reviews.
5. **Storage and transport:** streaming HTTP/body limits, event compaction,
   durable capability-scoped message bus, external tamper-evident checkpoints.
6. **Evidence of value:** compare rivalry, cooperative orchestration and a single
   agent under identical tasks and total resource budgets. Publish acceptance
   rate, cost, latency, defect escape rate and evaluation failures.

Persephone's recurring feature flags, dedicated Hades archival jobs, specialized
Apollo profilers, Zeus scope accumulation and adoption-based economics remain
unimplemented. Their names are not substitutes for working mechanisms.
