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
provider stream for the reservation. Native Codex does not send a server-side
output-token limit; its reported completion usage is checked after generation.
For Codex, only local deadline/output bytes are hard-bounded, not remote token
consumption. The same reservation is never reused for another model request. Non-success stop reasons and malformed
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
Coding mode adds source context and asks Pi for exact file replacements rather
than enabling tools. The authority applies those replacements itself; arbitrary
repository-editing agents still do not run inside the authority VM.

## Isolated coding workflow

A realm can hold a prepared coding profile. Preparation resolves a Jujutsu
revision to an immutable Git commit without snapshotting or mutating the user's
worktree. Read-only Git object plumbing exports bounded text files without hooks,
checkout filters, VCS metadata, submodules, symlinks or LFS materialization.
Original regular/executable Git modes are retained. Explicit `source_files` can
reduce the export; all tracked files are the default.

The profile snapshots a closed JSON corpus of stdin / expected stdout / successful
exit cases. Acceptance files are not mounted into candidate containers and are
never included in model context. This is a black-box evaluator, not an in-process
test framework. A test runner importing adversarial code would share its
privileges: code could exit zero, replace assertions or spoof reports. Keeping
the oracle in the host controller avoids that failure.

Law version 3 binds the manifest and bounded-repair policy into the contract seal.
Previously settled law-version-2 coding episodes retain their recorded decisions. The manifest includes
base commit, exported source/mode digest, corpus digest, resolved immutable image
ID and platform, trusted controller hash/version, exact argv, environment, working
directory, editable paths and limits. The sealed event privately archives source,
modes and corpus for reproducibility; the model receives only source and manifest.
Journals therefore contain private acceptance data and must be protected.

Proposals contain only a bounded map of exact path replacements. No paths outside
the allowlist, null deletions, symlinks, permission changes or submitted evaluation
claims are accepted. A trusted Python controller reconstructs each candidate in a
new private directory. It generates a unified patch from those exact bytes,
including empty additions and missing-final-newline markers.

Each case runs in a fresh local Podman or Docker container with an explicitly overridden
entrypoint. The root filesystem and candidate source bind are read-only; the
container gets no host credentials, engine socket, test files or network.
Capabilities are dropped, no-new-privileges is enabled, UID/GID are unprivileged,
and CPU/memory/PID/tmp/output/time limits apply. The controller compares raw stdout
and observed process exit itself. Printing a purported success report or merely
exiting zero cannot substitute for matching every sealed expected output.

Fate admits only independently successful artifacts, regardless of model claims
or the prayer's additional predicates. It reconstructs and reruns the winning
replacement map in fresh containers before final validation and settlement.
Evidence includes per-case execution IDs, bounded output previews/hashes,
termination status, measured duration, tests passed, patch size/hash, proposal and
candidate-tree hashes, base commit, image ID and profile hash. The journal
preserves the winning file map and patch before success is returned. No merge or
source-repository mutation occurs.

Evaluation is performed in monitored helper subprocesses, not in the BEAM VM.
Caller death closes the helper's input; an external cancellation monitor cleans
up the attached CLI, container and temporary workspace. Podman containers also have
engine-enforced lifetimes. Docker containers are created without executing code;
an independent host watchdog is armed against the immutable container ID before
attach/start. The candidate cannot kill this host process. It expires the
container even if the controller is abruptly killed. A realm owner label derived from its journal path
scopes startup cleanup: after a restart, that realm's orphan containers and
workspace root are reaped before more work can run. Interrupted tasks remain cut,
not retried. Kernel/engine crashes can still require operator storage recovery.

The local Linux Podman engine or Docker Desktop Linux VM, image, Python controller, VCS object store and
host kernel are trusted. The current environment tests verify read-only source,
hidden fixtures, absent credentials, no outbound network, zero effective
capabilities, no-new-privileges, and cgroup memory/PID limits. Unsupported runtime
configurations must not be assumed equivalent. Rootless execution is recommended
where available; container isolation is not a defense against kernel escapes.

This milestone deliberately supports successful CLI programs over bounded text
source trees. It does not support arbitrary build pipelines, dependency fetching,
binary patches, deletions, mode-only edits, remote engines, property-test oracles,
in-process unit suites, automatic merge, or empirical claims about rivalry's value.

## Bounded repair within a reservation

The sealed profile declares `max_attempts`, an integer from 1 to 3 (default 1).
`Coding.Search` partitions each original proposal reservation into fixed positive
completion allowances, skipping impossible zero-token slots. Their sum equals
the reservation; early success does not redistribute unused capacity. Reviews
keep their existing independent allocations. Native Codex continues to have
post-generation token checks rather than a server-side output cap.

A contender's steps run sequentially inside its existing disposable task, while
contenders remain concurrent. Every invocation receives the remaining time from
one original absolute deadline. Each step creates a fresh Pi session and fresh
evaluation workspaces. Model/evaluator failures and malformed edits terminate;
only a measured candidate/contract failure can advance to another step.

Valid replacement maps accumulate over the immutable baseline. The model sees
that baseline alongside `repair.current_files`; omitted edited paths retain
their previous values. The trusted evaluator applies the full accumulated map
and enforces limits on the merged tree, not just the latest delta. The first
pass stops the search. Exhaustion preserves the last measured artifact and records
the terminal failure separately. No failed intermediate artifact can win.

Styx is checked on every measured step, using all previously committed oaths,
including those from earlier tournament rounds. Breach or invalid declaration
ends the sequence immediately. Only validated oaths are committed, and earlier
ones survive a later invalid declaration. A trusted terminal marker keeps that
invalid declaration ineligible even if its artifact otherwise passes.
Model-supplied trace/terminal fields are discarded and regenerated by authority.

Repair feedback is an explicit allowlist of aggregate counts and static failure
categories. No raw stdout/stderr, input, expected output, numeric exit status,
case index, execution ID or output hash is exposed. Coding review requests are
sanitized too: passing full evidence to an enemy would allow a candidate that
echoes hidden stdin to exfiltrate it to another model. Oaths contain only prior
model-authored predicates; the journal and full attempt audit never enter agent
memory or prompts. The intentionally limited acceptance oracle still permits
bounded adaptive inference; it is not cryptographic confidentiality.

Candidates retain attempt indexes, fixed allowances, statuses, evaluated
artifacts and validated oaths in their private audit. Admission reserves
`max_attempts + 1` evidence units per candidate/round, including final artifacts.
Trusted progress snapshots are sent to the owning authority before and after
each step. Ordinary task timeouts retain completed evidence and validated oaths,
mark in-flight attempts interrupted, and cannot promote partial success.
Audit is appended atomically with terminal settlement, not on every step. An
authority crash cuts the pending epoch, may lose uncommitted attempt details, and never
retries it or refunds potentially spent reservations. Incremental crash-durable
progress would require a separate nonblocking journal protocol.

The final selected replacement bytes still undergo a completely fresh independent
evaluation before settlement. The repair loop does not merge, deploy, introduce
model-selected tests, or give either gods or humans an override.

## Non-authoritative usage and timing

`Adapter.invoke/3` is the trusted boundary for invocation timing. Legacy
`respond/2` adapters remain compatible. An optional `respond_with_usage/2`
returns metadata as a separate tuple element; the Pi bridge obtains it from the
completed SDK assistant message, outside the model-generated text. The public Pi
`respond/2` API still returns its original two-element success/error tuples.

Only provider/model labels and the five nonnegative, safe-integer Pi SDK token
counters are accepted. Costs, headers, raw errors and arbitrary metadata are
discarded. SDK counters are emitted only when complete and nonzero; initialized
zero-filled usage is conservatively unavailable. Model-authored usage and audit
fields cannot overwrite authority-owned call records.

Coding search checkpoints completed invocation metadata before starting evaluation,
so a later evaluator timeout retains known model consumption. A model call killed
before its reply has unknown usage. Failed JSON or over-allowance completions can
still retain available provider counters. Plain proposals and enemy reviews use
the same boundary; generated artifacts never contain authoritative telemetry.

`Usage.summarize/1` enumerates audited proposal/repair and review slots. It reports
known subtotals and coverage separately. Missing historical records, skipped or
interrupted slots, and provider omissions are not converted to zero. Empty
restart-cut episodes cannot establish zero consumption. The sum of adapter elapsed
times includes startup/authentication and may exceed contest wall time because
contenders run concurrently. It is not model-only latency or evaluator time.

This is additive accounting, excluded from scoring, oath predicates, favor,
reservation allocation and model context. It introduces no billing claims or
remote hard cap for native Codex. A future matched-budget strategy benchmark must
account for incomplete coverage, cached-token semantics, failures and repetitions
rather than compare reserved allowances as if they were measured consumption.

Docker Desktop workspace preparation now removes stale children while preserving
the private owner-root inode. Deleting and immediately recreating that parent can
leave Desktop bind sharing with a stale path, causing an infrastructure failure.
Before reuse, an O_NOFOLLOW directory descriptor verifies ownership, and private
0700 permissions are enforced before traversing stale entries. Foreign-owned or
symlink roots are rejected; evaluation rechecks ownership and mode. No retry or
weaker mount policy is used to hide a mount failure.

## Verification and roadmap

Tests cover contract seals, typed predicates, missing paths, invalid schemas,
independent acceptance, verified vs fabricated review challenges, deterministic
ties, strict majority, conserved favor, tiny budgets, deadlines, adapter crashes,
replay, duplicate IDs, interrupted epochs, writer fencing, corrupt journals,
bounded oath memory, coma, Lethe and generation inheritance.

The offline example exercises the public supervised entry point and cold-VM
journal replay. It demonstrates mechanics, not empirical gains from rivalry.

Next stages, without weakening Fate:

1. **Richer external evaluation:** isolated build stages, trusted out-of-process
   type-check/benchmark/property-test oracles, dependency/image provenance and
   resource accounting beyond the current black-box CLI cases.
2. **Protected merge effects:** idempotent, fenced Zeus executor and immutable
   effect intents. Winning patches and evidence now exist; host repository
   mutation and automatic merging remain unimplemented.
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
