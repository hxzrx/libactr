# Changelog

All notable changes to libactr are documented here. Phase references point at the
design docs in the project-level `docs/` repository.

## Unreleased — test infrastructure (post-0.4.1)

The redis-dependent suites can now run against an EXTERNAL disposable redis:
setting `LIBACTR_TEST_REDIS_HOST`/`LIBACTR_TEST_REDIS_PORT` makes the
redis-store and cluster fixtures connect there directly (FLUSHDB on entry —
never point it at real data) instead of self-starting a local redis-server,
which lets hosts without a redis-server binary run the full baselines
(verified against a scratch instance on a VM: `:libactr/redis-store` 51 pass
+ 1 designed skip, `:libactr/cluster` 128/128 including the kill-worker e2e).
Host threading fixes along the way:

- The ~50 hardcoded loopback hosts in the redis tests are unified behind a
  `%test-redis-host` helper (external host when set, else 127.0.0.1); the e2e
  worker subprocesses and in-process servers thread the external host too.
- fiveam has no `:skipped-if` option — it was silently ignored, so the
  AOF-restart test ran unconditionally and failed on hosts without a usable
  local redis-server fixture (mistakenly believed skipped since it was
  written). It now uses the `5am:skip` check idiom and skips under
  external-redis mode as well (the external instance must not be killed).
- e2e worker kill: `uiop:terminate-process` degrades to `taskkill /pid <n>`
  WITHOUT `/F` on Windows and hung the whole image in
  SB-WIN32::WIN32-PROCESS-WAIT (run-evidenced via a thread-backtrace
  watchdog), wedging every prior run at the kill step and cascading into the
  host's virtual-network stack. `%terminate-worker` now force-kills via
  `taskkill /F` on Windows and keeps terminate-process elsewhere.

## 0.4.1 (2026-10-07) — concurrency, robustness, and scalability review fixes

Maintenance-mode defect fixes from a purpose-based review (libactr as a
multi-user-safe, high-performance, thread-safe tutoring dependency). The new
exports are user-directed exceptions to the public-surface freeze; tier
semantics are unchanged.

- **F1 registry concurrency (thread safety).** Every read AND write of the
  tutor-server registries (students/sessions/models) now goes under the
  registry lock — including the step/mastery/health lookups and the
  end-session remhash, which previously took no lock at all (plain CL hash
  tables are unsafe under concurrent reader+writer access).
  server-start-session was restructured into three phases (registry resolve →
  unlocked build+prepare → registry register) so adapter code no longer
  serializes unrelated students' starts. The cluster scan/takeover ticks
  iterate a registry snapshot instead of a live maphash. New exports:
  `server-sessions-snapshot`, `server-register-handle`,
  `server-find-session-handle`, `server-model-entry`.
- **F2 redis connection serialization (thread safety).** redis-event-log's
  single cl-redis connection is guarded by a per-instance bordeaux lock (the
  same ruling the cluster manager and proxy already followed): a step's RPUSH
  and a concurrent mastery LRANGE for the same student used to interleave RESP
  frames on one socket. `libactr/redis-store` now depends on bordeaux-threads.
- **F3 shared event-log locking (thread safety).** A per-student lock
  (`server-log-lock`, exported) serializes every access to a student's shared
  event log — step-path appends, end/checkpoint `log-last-seq` reads, mastery
  reads — on both the in-memory and redis backends (the session lock cannot
  cover the log: it outlives any one session).
- **F4 incremental mastery (performance).** The inline `:mastery` in step
  responses and GET /student/mastery previously folded the student's ENTIRE
  history on every call (on the redis backend a full `LRANGE 0 -1` plus one
  JSON parse per event per step — cost grew without bound with the student's
  cross-problem history). A per-student BKT cache now folds only events
  appended since the last call; results are identical to compute-mastery by
  construction (first call / kt-params change / shrunken log fall back to a
  full replay).
- **F5 unified action-field parsing (robustness).** Shared
  `adapter-action-string` / `adapter-action-integer` helpers (exported from
  :libactr) make every malformed student action a 400 bad-tutor-request:
  fraction's missing-value hole (the one domain the phase-14 B1 sweep missed)
  and — across all four adapters — unquoted JSON numbers, which used to reach
  `parse-integer`/`string-upcase` as integers and TYPE-ERROR into HTTP 500s.
- **F6 ACT-R value equality (fidelity).** Slot comparisons now mirror official
  ACT-R's chunk-slot-equal (eq / case-insensitive string / equalp) instead of
  plain `equal` — mixed-type numbers and case-differing strings no longer
  diverge from the dual-track oracle.
- **F7 out-of-subset diagnostics (usability).** compile-model rejects LHS
  `+buf>`/`-buf>`/`!action!` patterns with a diagnostic naming the production
  (was: an opaque struct TYPE-ERROR, or a silent drop); read-model-file accepts
  legal name-only add-dm declarations (`(shark)`) as empty chunks and rejects
  genuinely malformed entries (was: a silent skip that quietly dropped facts);
  multiple SGP forms accumulate instead of last-wins.
- **F8 service hardening.** `start-tutor-server` / `make-tutor-proxy` accept
  `:max-body-size` (default 64 KiB): oversized POST bodies are refused with
  413 before being read; `student_id` is validated at session start
  (non-empty printable string of at most 128 characters — 400 otherwise; it is
  embedded in redis keys and event records).
- **F9 BKT parameter validation.** `check-kt-params` (exported) enforces every
  parameter strictly inside (0,1) and G+S<1 per set including overrides —
  fail-fast at server/proxy construction, backstop in compute-mastery (a
  violating set used to divide by zero mid-fold).

## Unreleased — dev infrastructure

Vendored a frozen ACT-R snapshot under `vendor/act-r/` (act-r@`da413e6`,
upstream SVN r3493 / ACT-R 7.31.5, snapshot 2026-09-02, LGPL-2.1 with
`COPYING.LESSER` included). The dev-time dual-track oracle (`libactr/oracle`,
`libactr/dual`) and every `asdf:system-relative-pathname "act-r" ...` test
reference now resolve to this in-repo snapshot, so a fresh clone of libactr
alone runs all ten suites with no sibling `act-r/` checkout. Development
infrastructure only: no code, public-surface, or ASDF system-name changes,
and all suite baselines are identical (381/316/51/407/414/22/24/21/35/128).

Removed the legacy descriptive package nicknames `:model-tracing` (for
`:libactr`) and `:model-tracing/oracle` (for `:libactr/oracle`) — the last
public traces of the former project identity, a user-directed exception to
the maintenance-mode public-surface freeze. Nothing in this repository or
its tests/examples referenced the nicknames by prefix; all ten suite
baselines are unchanged.

Refreshed the asd `:long-description` to the current state: dropped the
internal project jargon and the stale sibling-`act-r/` reference, and now
describes the shipped surface (kernel, KT, service layer, cluster,
four domain adapters) and the self-contained vendored oracle.

## 0.4.0 (2026-09-02) — project-wide rename; behavior unchanged

The library took its current name and identity across every public
surface: ASDF system names (28 systems, definition file now `libactr.asd`),
package names, FiveAM suite names, exported symbol prefixes, redis key
prefixes, and error-message prefixes. Behavior is unchanged (all ten suite
baselines identical to 0.3.1). A user-directed exception to the 0.3.0
maintenance-mode public-surface freeze.

- **Data compatibility (breaking, intentional):** redis data written by
  earlier 0.x releases is not readable — key prefixes and `kc_package`
  package names changed. No production data existed; no migration.
- Docs: all historical specs/plans renamed and rewritten in place in the
  project docs repository (git rename tracking kept).
- The complete old→new name mapping is recorded in the 0.4.0 commit in git
  history.

## 0.3.1 (2026-09-02) — parked-minors cleanup

Maintenance-mode quality closeout: every minor the phase-14 final review
parked (21 ledger rows) is dispositioned — FIXED 8 / CLOSED 13 /
ALREADY-FIXED 0 (permanent ledger: docs/2026-09-02-libactr-parked-minors-cleanup.md
in the project-level docs repository).

- takeover: the no-checkpoint claim drop logs one line (was silent — the
  sibling branches already did); the five-field marker snapshot takes the
  session handle lock (the scan tick's discipline); the zombie sweep logs
  the owner observed at scan time instead of a second HGET.
- `validate-bug-spec`: the fact-slot / goal-guard malformed-entry messages
  name the proper-list requirement (message-only; tests pin prefixes).
- tests: proxy mastery pins the `kc->json` wiring (RED-probed); the
  subtraction out-of-order test drops the pre-falsification "already"
  wording; the sentinel count read ordering is documented; the C1/C2
  fixtures stop their acceptor-less servers.
- Public surface frozen (no new exports, no signature changes;
  `server.lisp` untouched); cluster suite 126 -> 128 (two new assertions).

## 0.3.0 (2026-08-31) — engine residual hardening

All phase-13 final-review residuals closed at library-consumer standard.

- **A1** zombie self-check: a recovered falsely-dead worker drops local
  handles adopted away (new exported `server-drop-session`); in-flight-at-flip
  log interleaving stays a documented bounded contract.
- **A2** `make-session-id` cross-process uniqueness (time + sub-second +
  gensym; fresh images used to collide).
- **A3/A4** atomic claim + atomic route-flip (single Lua EVAL each); the
  stranded-adopt retry closes via a five-field checkpoint marker.
- **A5** sticky proxy start (same student -> same worker/session_id).
- **B1** out-of-order/missing-field actions are 400 (`bad-tutor-request`),
  was 500; **B2** `validate-bug-spec` never signals on dotted entries.
- **C1-C8** tick error visibility, poll-join stop, `student-events-key`
  single source, exported `kc->json`, strict route-epoch parse, tightened
  symbol-tag predicate (+ wire contract), spec-gate sad-path coverage,
  idempotent `start-cluster-manager`.
- Cosmetic: checkpoint codec fidelity (normalization at the consumer),
  retry sentinel test, e2e launch-in-protect, README/alignment polish.
- New exports: `libactr/server:kc->json`, `libactr/server:student-events-key`,
  `libactr/server:server-drop-session`. `make-session-id` output format changed
  (opaque to consumers). server.lisp exception exercised 4x per spec §8.

**Policy**: 0.3.0 is the feature-complete candidate. Maintenance mode from
here (defect fixes only, public surface frozen); 1.0.0 will be released
after the first real consumer validates libactr as a dependency.

## 0.2.0 (2026-08-28)

Engine completion + library-ization. Five workstreams:

- **Cluster orchestration (`libactr/cluster`).** Multi-worker deployment layer on
  Redis: a per-worker `cluster-manager` (heartbeat TTL lease, periodic
  checkpoint scan under each session's lock, atomic-claim takeover that
  rebuilds dead workers' sessions via `restore-from-checkpoint` and flips the
  routing table), memory/Redis checkpoint stores, and a thin front
  `tutor-proxy` (round-robin at session start, sticky `session_id`/`
  `student_id` routing, one re-resolve+retry on transport failure,
  location-free `/student/mastery` computed straight from Redis).
  `examples/cluster-worker.lisp` is the worker bootstrap and the e2e test
  kills a live worker mid-problem, proving transparent continuation.
  Fencing boundary is documented, not hidden: a zombie worker can still append
  to the shared event log (per-request epoch checks rejected as hot-path
  Redis churn); the epoch counter in route values is reserved for a future
  opt-in fence, and the deployment guide's isolate-after-death duty covers
  the residual.
- **`validate-bug-spec` authoring validator.** Pure checker (cross-reference,
  `:when` walk, arity, environment names) returning `(values errors
  warnings)`, wired fail-loud into the fraction/subtraction tutors and the
  past-tense adapter so malformed bug declarations cannot load silently.
- **Symbol-faithful summaries round-trip.** `tag-symbols`/`untag-symbols`
  codec: Redis intent/result summaries and cluster checkpoints now round-trip
  symbol slot values exactly (name AND package), with legacy rows still
  readable.
- **Fraction `simplify` third KC.** A `:simplify` production (reduce-fact
  priming, nil-guard sequencing) plus the adapter's conditional
  `step-done?` — sums are only done when in lowest terms.
- **Library-ization.** This README with runnable quickstarts, MIT LICENSE,
  this CHANGELOG, `libactr.asd` metadata (version 0.2.0 / MIT / author /
  long-description), and a tiered export surface with complete docstrings on
  the public API.

## 0.1.0 (2026-08-08 — 2026-08-27)

Twelve phases, each ending merged and green (see the phase docs for detail):

- **Phase 1 — kernel.** Types, reader, compiler, matcher: ACT-R-subset model
  files compile to pure data; zero global mutable state from day one.
- **Phase 2 — dual-track validation.** `libactr/oracle` runs the same models
  under act-r; the dual suite cross-checks matcher agreement on the tutorial
  corpus. act-r remains a dev-time oracle only.
- **Phase 3 — model-tracing layer.** `step-intent` / `covers-p` /
  `trace-step`: on-path advance, off-path-buggy diagnosis from declared
  misconception libraries, off-path unclassified; feedback + KC events.
- **Phase 4 — session layer.** `cognitive-session` (all mutable state on the
  instance), authoritative event log, checkpoint/restore, and the
  concurrent-isolation proof suite.
- **Phase 5 — service layer.** `libactr/server`: Hunchentoot `tutor-server` with
  5 endpoints, model registry, per-session locks, per-student idempotent
  starts, `student-session` (one shared log per student), and
  `libactr/redis-store` for AOF-durable event logs.
- **Phase 6 — knowledge tracing.** Corbett & Anderson four-parameter BKT:
  `compute-mastery` folds the event log into per-KC accuracy + P(L); multi-step
  primed intents (visible + hidden steps).
- **Phase 7 — fraction domain.** Second domain; established the adapter as
  the domain brain (arithmetic, bug detection, retrieval priming), per-KC KT
  parameter overrides, and the empirical synthetic-student harness.
- **Phase 8 — authoring support.** Declarative `apply-kc-map` KC attribution
  and the reusable `standard-domain-adapter` base (dogfooded by both
  arithmetic adapters).
- **Phase 9 — polish.** Recursive JSON encoding (nested plists as objects,
  not arrays), and per-server `kt-params` threading through to both mastery
  call sites.
- **Phase 10 — past-tense domain.** Third domain; first symbol-slot model;
  KC routed by a problem variable (verb class); terminal-production lists.
- **Phase 11 — subtraction domain.** Fourth domain; mixed integer+symbol
  slots; borrow columns as conditional 2-intent steps; detection-mutex and
  degenerate-case analysis; the bug-DSL evidence that motivated Phase 12.
- **Phase 12 — minimal bug-DSL.** One `make-bug-spec` declaration generates
  the buggy production, detection predicate, and retrieval-prime/hidden
  intent; ten bugs across three domains migrated with bit-identical behavior;
  malformed-input 400 mapping unified.
