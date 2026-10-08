# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

libactr is a **model-tracing tutor engine** (the Carnegie Learning / MATHia lineage): models are authored in an ACT-R-subset production language and each student step is traced against them (on-path / off-path-buggy / off-path), folding into Bayesian (Corbett & Anderson BKT) per-skill mastery, served over HTTP and cluster-scalable.

It is **not ACT-R and never loads ACT-R at runtime**. The vendored frozen snapshot under `vendor/act-r/` (LGPL, system name `act-r`) is a development-time **dual-track oracle** only (`libactr/oracle`, `libactr/dual`): it runs the same models under the real ACT-R interpreter and cross-checks matcher agreement. Any core matcher/compiler semantic change must keep the dual suite green (or explain why the oracle expectation legitimately moved).

The library is in **0.4.x maintenance mode: defect fixes only, public surface frozen**. New exports or signature changes are user-directed exceptions that must be recorded in CHANGELOG.md.

## Commands

```bash
# core suite (also the base for the concurrent/dual legs)
sbcl --non-interactive --eval '(ql:quickload :libactr/test)' --eval '(5am:run! :libactr)'

# server suite — MUST load server-test AND all four adapter tests first (they join one suite)
sbcl --non-interactive \
  --eval '(ql:quickload :libactr/server-test)' \
  --eval '(ql:quickload :libactr/addition-adapter-test)' \
  --eval '(ql:quickload :libactr/fraction-adapter-test)' \
  --eval '(ql:quickload :libactr/past-tense-adapter-test)' \
  --eval '(ql:quickload :libactr/subtraction-adapter-test)' \
  --eval '(5am:run! :libactr/server)'

# single test (note the PACKAGE qualification — test symbols live in per-file test packages)
sbcl --non-interactive --eval '(ql:quickload :libactr/test)' \
  --eval "(5am:run! 'libactr/test::reader.multiple-sgp-forms-accumulate)"

# redis-dependent suites: either a local redis-server binary, or an external DISPOSABLE instance:
LIBACTR_TEST_REDIS_HOST=192.168.182.133 LIBACTR_TEST_REDIS_PORT=6390 \
  sbcl --non-interactive --eval '(ql:quickload :libactr/cluster-test)' --eval '(5am:run! :libactr/cluster)'
```

- Suite name = system name minus `-test`. Current baselines (assertion counts, 0 failures; SBCL 2.6.9 Linux, 2026-10-08): `:libactr` 409, `:libactr/concurrent` 435 (reruns `:libactr` with bordeaux loaded), `:libactr/dual` 442 standalone (468 when the concurrent and dual legs share one process), `:libactr/server` 366, `:libactr/redis-store` 51 + 1 designed skip (external-redis mode) or 54 self-started (this box has `/usr/sbin/redis-server`, Redis 8.10.1 — `which` misleads, the fixture probes absolute paths), `:libactr/cluster` 128, `:libactr/empirical` 35, tutors 22/24/21. **Identical on CCL 1.13 (Linux)** — all ten suites in both redis modes, including the dual oracle and the CCL-worker e2e.
- The external-redis fixture **FLUSHDBs on entry** — never point it at real data.
- The cluster e2e spawns real worker subprocesses **in the same implementation as the test image** (follow-the-parent; sbcl `--eval` chain, ccl generated `--load` bootstrap — see `%worker-command`) and kills one mid-problem (~4 min runtime).
- CCL portability check: `ccl --batch --load <script>` (Linux; Windows-era: `D:/Dev/ccl/wx86cl64.exe`) — use a script FILE; `--eval` strings containing package-prefixed symbols (e.g. `5am:...`) fail at read time because the packages don't exist yet. Related, run-evidenced: `uiop:argv0` returns NIL under CCL; an SBCL `--eval` string must hold EXACTLY one complete form (a `#-quicklisp` guard reads as zero forms and kills the process — hence the `(unless (find-package :ql) ...)` idiom in `%worker-command`).
- Threading is bordeaux-threads **APIv2** (`bt2:`) everywhere — the APIv1 package (`bt:`/`bordeaux-threads:`) must not creep back: mixing them fails as TYPE-ERROR (v1 `with-lock-held` wants a native SB-THREAD:MUTEX, not a BT2:LOCK wrapper), and v2 `make-lock` takes `:name` by keyword.

## Windows dev quirks (this repo is developed on Windows)

- `uiop:terminate-process` degrades to `taskkill /pid` **without /F** and hangs forever in `WIN32-PROCESS-WAIT` on console processes spawned with output redirection — kill subprocesses with `taskkill /F /PID <pid>` instead (see `%terminate-worker` in tests/test-cluster-e2e.lisp).
- Never use `~`+newline format-directive continuations in error strings (CRLF makes them illegal directives).
- fiveam has **no `:skipped-if` option** — it is silently ignored. Skipping is a `(5am:skip "reason")` check in the test body.

## Architecture

Layering (each layer only depends on lower ones):

```
core (libactr)            reader → compiler → matcher → tracer, sessions,
  :depends-on ()           event log, checkpoints, BKT, authoring/bug-DSL
  ZERO global mutable      — pure functions, all state on CLOS instances
  state, no locks
        ↓
libactr/server            HTTP service: tutor-server, model registry,
  (hunchentoot, bt, yason) session-handles, adapter protocol, JSON wire
        ↓                        (src/adapter.lisp lives in :libactr but loads with server)
libactr/redis-store       durable event-log backend (specializes the
  (cl-redis, yason, bt)    event-log generic protocol)
        ↓
libactr/cluster           manager (lease/checkpoint/takeover ticks) +
  (dexador)                front proxy; composition only — no lower file modified
```

**Domain adapters are the single engine/domain seam** (`prepare-session` / `adapt-action` / `step-done?` — three generics in src/adapter.lisp). The adapter IS the domain brain: parses the action, computes the correct answer, runs bug detection (`detect-bug` over bug-specs), and returns primed step-intents; the engine stays domain-agnostic. Four shipped domains (addition/fraction/past-tense/subtraction) each = tutor (`examples/`) + adapter (`src/`) + model (`models/` or the act-r tutorial one).

**The event log is the single source of truth**; mastery is a deterministic derivation (folded on demand; the server keeps a per-student incremental BKT cache that is identical to a full replay by construction).

**Symbol-package convention (easy to break, silently):** `read-model-file` interns all model symbols in the caller's `*PACKAGE*`. Tutor loaders bind `*package*` to their package; adapters carry `:model-package` and every symbol interning goes through `adapter-intern`. Buffer-state is an EQ hash — a same-named symbol from the wrong package silently never matches.

**Lock discipline (service layer only)** — acquisition chains only run **SESSION → LOG → REGISTRY** (registry innermost, held for single hash ops; no path acquires them in another order): per-session lock on `session-handle`, per-student `server-log-lock` around shared-event-log access, registry lock (students-lock) around the students/sessions/models tables. Cluster tick threads iterate registry snapshots (`server-sessions-snapshot`), never live maphash. cl-redis connections are single-socket/not thread-safe: every use is under a per-instance lock (`with-redis` in redis-store, manager/store/proxy have their own).

**Cluster manager** state lives in Redis (prefix `libactr:cluster:`): heartbeat TTL lease, checkpoint scan (per session, under session+log locks), takeover via atomic Lua claim + route flip. The three ticks are single-steppable functions (`cluster-heartbeat-tick` etc.) — tests drive them directly for determinism.

## Conventions

- **Comment culture:** deviations from a plan/brief are recorded inline as `[brief defect, run-evidenced: ...]` / `[deviation from brief: ...]` with the evidence that falsified the original. Preserve this style when touching such code.
- BKT parameters must satisfy every-param-in-(0,1) and G+S<1 per set incl. overrides — `check-kt-params` runs fail-fast at server/proxy construction and as a backstop in `compute-mastery`.
- Slot-value comparisons use `slot-value-equal` (eq / case-insensitive string / equalp), mirroring official ACT-R `chunk-slot-equal` — do not regress to plain `equal`.
- The LHS subset is `=buf>` content tests and `?buf>` state queries only; `+buf>`/`-buf>`/`!action!` are RHS-only and rejected by `compile-model` with a diagnostic.
- `add-dm` accepts `(name isa type slot val ...)` and name-only `(name)` entries; anything else is a reader error (fail loudly, no silent skips).
- Malformed student input is ALWAYS `bad-tutor-request` (400), never a leaked TYPE-ERROR (500) — use `adapter-action-string` / `adapter-action-integer`, and guard arithmetic on goal slots (B1-style out-of-order checks).
