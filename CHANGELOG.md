# Changelog

All notable changes to libactr are documented here. Phase references point at the
design docs in the project-level `docs/` repository.

## Unreleased — dev infrastructure

Vendored a frozen ACT-R snapshot under `vendor/act-r/` (act-r@`da413e6`,
upstream SVN r3493 / ACT-R 7.31.5, snapshot 2026-09-02, LGPL-2.1 with
`COPYING.LESSER` included). The dev-time dual-track oracle (`libactr/oracle`,
`libactr/dual`) and every `asdf:system-relative-pathname "act-r" ...` test
reference now resolve to this in-repo snapshot, so a fresh clone of libactr
alone runs all ten suites with no sibling `act-r/` checkout. Development
infrastructure only: no code, public-surface, or ASDF system-name changes,
and all suite baselines are identical (381/316/51/407/414/22/24/21/35/128).

## 0.4.0 (2026-09-02) — renamed mtt → libactr

End-to-end rename of the library; behavior is unchanged (all ten suite
baselines identical to 0.3.1). A user-directed exception to the 0.3.0
maintenance-mode public-surface freeze.

- ASDF systems: `mtt` → `libactr` and every `mtt/*` subsystem →
  `libactr/*` (28 systems; e.g. `mtt/server` → `libactr/server`). The
  system definition file is now `libactr.asd`.
- Packages: `:mtt` → `:libactr`, `:mtt/server` → `:libactr/server`, …
  (26 packages). Nicknames `:mtt-server` / `:mtt-cluster` →
  `:libactr-server` / `:libactr-cluster`; descriptive nicknames such as
  `:model-tracing` are unchanged.
- FiveAM suites: `:mtt`, `:mtt/server`, `:mtt/redis-store`,
  `:mtt/fraction-tutor`, `:mtt/past-tense-tutor`, `:mtt/subtraction-tutor`,
  `:mtt/empirical`, `:mtt/cluster` → `:libactr…` prefixes (the concurrent
  and dual baselines run the core suite with their test files joined via
  `in-suite`).
- Renamed symbols: `mtt-chunk` → `libactr-chunk`, `mtt-goal-chunk` →
  `libactr-goal-chunk`, `mtt-retrieval-chunk` → `libactr-retrieval-chunk`,
  `:mtt-match-fail` → `:libactr-match-fail`.
- Redis key prefixes: `mtt:cluster:` / `mtt:cluster:ckpt:` →
  `libactr:cluster:` / `libactr:cluster:ckpt:`.
- Error-message prefixes: `mtt/<domain>-adapter: …` →
  `libactr/<domain>-adapter: …`.
- **Data compatibility (breaking, intentional):** redis data written by
  mtt 0.x is not readable by libactr — key prefixes and `kc_package`
  package names changed. No production data existed; no migration.
- Docs: all historical specs/plans renamed and rewritten in place in the
  project docs repository (git rename tracking kept).

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
