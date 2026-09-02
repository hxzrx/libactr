# libactr — Model-Tracing Tutor Engine

An independent, multi-user-safe model-tracing production engine in Common
Lisp. Cognitive models are authored in the ACT-R syntax and validated against
a vendored frozen ACT-R snapshot (`vendor/act-r/`, system name `act-r`) at
development time (dual-track oracle); at runtime libactr is
dependency-free and holds zero global mutable state. This is the
"model in ACT-R, ship a dedicated runtime" path proven by Carnegie
Learning / MATHia and CTAT: ACT-R's global singleton meta-process does not
multi-user, so libactr compiles ACT-R-subset models into pure data and traces
student steps against them at service throughput.

## Status

0.4.x — maintenance mode (defect fixes only, public surface frozen — see
[CHANGELOG](CHANGELOG.md); user-directed exceptions are recorded there).
Four domains shipped (addition, fraction, past-tense, subtraction), each
as a tutor + adapter pair with a declarative bug library. The dev-time
oracle ships vendored (`vendor/act-r/`), so the repository is
self-contained: a fresh clone runs all ten test suites standalone.

## Requirements

- SBCL (developed and tested on 2.6.7; baselines re-verified on 2.6.8); any
  ANSI CL with ASDF 3.3+ should work.
- [Quicklisp](https://www.quicklisp.org/) for the service-layer deps:
  hunchentoot, bordeaux-threads, yason (server); cl-redis (redis-store);
  dexador (cluster); fiveam (tests).
- `redis-server` — only for `libactr/redis-store`, `libactr/cluster`, and their tests
  (suites self-start one and skip when absent).
- No external `act-r/` checkout needed: the dev-time dual-track oracle
  (`libactr/oracle`, `libactr/dual`) runs against the vendored frozen ACT-R
  snapshot under `vendor/act-r/` (LGPL-2.1). Runtime never loads it.

## Quickstart (core)

```lisp
(ql:quickload :libactr)

(let* ((model (libactr:compile-model
               (libactr:read-model-file
                (asdf:system-relative-pathname "libactr" "models/fraction-add.lisp"))))
       (session (libactr:start-session model "student-1" "1/2+1/3"))
       (step (lambda (assignments fact)
               ;; The fraction productions read the retrieval buffer: install
               ;; the fact, then trace the student's goal-slot assignment.
               ;; (Under libactr/server the adapter supplies these primes via the
               ;; step-intent's :prime slot and they are installed for you.)
               (libactr:set-buffer-chunk (libactr:session-state session) 'retrieval fact)
               (libactr:step-session
                session (libactr:make-step-intent :assignments assignments))))
       (r1 (funcall step '((goal cdenom 6))                ; "the common denominator is 6"
                    (libactr:make-chunk :isa 'lcm-fact
                                        :slots '((d1 . 2) (d2 . 3) (lcm . 6)))))
       (r2 (funcall step '((goal snum 5) (goal sdenom 6))  ; "1/2 + 1/3 = 5/6"
                    (libactr:make-chunk :isa 'sum-fact
                                        :slots '((cdenom . 6) (snum . 5) (sdenom . 6))))))
  (list (libactr:trace-result-status r1)                              ; :ON-PATH
        (libactr:production-name (libactr:trace-result-production r1)) ; FIND-COMMON-DENOMINATOR
        (libactr:trace-result-status r2)                              ; :ON-PATH
        ;; Bayesian per-KC mastery, replayed from the session's event log
        (libactr:compute-mastery (libactr:log-all-events (libactr:session-log session)))))
```

Result (SBCL 2.6.7 / 2.6.8 — identical):

```lisp
(:ON-PATH FIND-COMMON-DENOMINATOR :ON-PATH
 ((:KC ADD-FRACTIONS :CORRECT 1 :TOTAL 1 :ACCURACY 1.0d0 :P-L 0.4d0)
  (:KC FIND-COMMON-DENOMINATOR :CORRECT 1 :TOTAL 1 :ACCURACY 1.0d0 :P-L 0.4d0)))
```

Notes:

- `models/` holds four working models (`fraction-add`, `past-tense`,
  `subtraction`, plus the act-r tutorial `addition` referenced by the addition
  tutor). Model symbols are interned in `*PACKAGE*` at read time, so read and
  trace from the same package (any package — the snippets above assume the
  REPL's).
- Chunk slots are dotted `(slot . value)` pairs.
- A step is judged `:on-path` (production covered the student's intent),
  `:off-path-buggy` (a declared misconception production covers it — feedback
  + buggy KC), or `:off-path` (unclassified). Only on-path steps advance
  state; every step appends to the event log.
- One-call alternative with KC attribution and the buggy library attached:
  `libactr/fraction-tutor:load-fraction-model` (see `examples/fraction-tutor.lisp`).

## Serve it (libactr/server)

```lisp
(ql:quickload :libactr/addition-adapter)

(let ((server (libactr/server:start-tutor-server :port 5000)))
  (libactr/server:register-model server "add"
                                 (libactr/addition-adapter:build-addition-model)
                                 (libactr/addition-adapter:make-addition-adapter))
  ;; background acceptor is up; run some requests, then:
  ;; (libactr/server:stop-tutor-server server)
  server)
```

From the shell:

```bash
curl -s localhost:5000/session/start \
     -d '{"student_id":"lea","problem_id":"5+2","model_id":"add"}'
# => {"session_id":"sess-s897","student_id":"lea"}

curl -s localhost:5000/session/step \
     -d '{"session_id":"sess-s897","action":{"type":"start"}}'
# => {"status":"on-path","production":"initialize-addition","mastery":[...],...}

curl -s localhost:5000/session/step \
     -d '{"session_id":"sess-s897","action":{"type":"next-total","value":"six"}}'
# => {"status":"on-path","production":"increment-sum",...}

curl -s 'localhost:5000/student/mastery?student_id=lea'
# => {"student_id":"lea","kc":[{"kc":"INCREMENT-COUNT","correct":1,"total":1,
#     "accuracy":1.0,"p_l":0.4},{"kc":"INCREMENT-SUM",...},{"kc":"INITIALIZE-ADDITION",...}]}

curl -s localhost:5000/session/end -d '{"session_id":"sess-s897"}'
curl -s localhost:5000/health
# => {"status":"ok","active_sessions":0,"students":1}
```

Endpoints:

| Method + path | Body / query | Returns |
|---|---|---|
| `POST /session/start` | `{"student_id","problem_id","model_id"}` | `session_id` |
| `POST /session/step` | `{"session_id","action"}` | `status` (`on-path`/`off-path-buggy`/`off-path`), `production`, `feedback`, inline per-KC `mastery` |
| `POST /session/end` | `{"session_id"}` | end summary (`ok`) |
| `GET /student/mastery` | `?student_id=` | per-KC `kc`,`correct`,`total`,`accuracy`,`p_l` |
| `GET /health` | — | `status`,`active_sessions`,`students` |

The domain adapter is the single engine/domain seam: it parses the action,
computes the correct answer, detects declared bugs, and returns the
step-intent(s) to trace. `start-tutor-server` also accepts `:redis-config
(:host ... :port ...)` (durable per-student event logs via `libactr/redis-store`)
and `:kt-params` (per-KC Bayesian overrides reaching both mastery call
sites). Per-student starts are idempotent per server: while a student has an
active session, repeat starts return its id.

## Scale it (libactr/cluster)

One worker process per OS process (a stock `tutor-server` plus a
`cluster-manager`; workers are cluster-unaware beyond the manager), one Redis,
and one ingress:

```bash
# from the repo root, with redis-server running on 6379.
# ALL workers of a cluster register the SAME model table (see guide below):
sbcl --non-interactive \
  --eval '(ql:quickload :libactr/cluster)' \
  --eval '(ql:quickload :libactr/subtraction-adapter)' \
  --load examples/cluster-worker.lisp \
  --eval '(libactr/cluster-worker:main :port 8801 :redis-port 6379 :worker-id "w1")'
```

The ingress proxy (alternative: any external load balancer — see guide):

```lisp
(ql:quickload :libactr/cluster)
(libactr/cluster:make-tutor-proxy :port 6000 :redis-port 6379)
;; clients talk ONLY to the proxy; :port 0 = OS-assigned, read it back with
;; libactr/cluster:proxy-port; tear down with libactr/cluster:stop-tutor-proxy
```

### Cluster deployment guide

**What the manager does.** Each worker's `cluster-manager` runs three tick
threads over Redis (prefix `libactr:cluster:`, configurable): a heartbeat that
renews a TTL presence lease; a checkpoint scanner that snapshots every local
session (under its lock) to `ckpt:<sid>` every `scan-interval` seconds — the
step hot path never touches Redis; and a takeover scan that adopts sessions of
workers whose lease expired: atomic `SET NX EX` claim (exactly one taker),
rebuild via `restore-from-checkpoint`, route flip to the new worker.

**Ingress, two forms.** Either the built-in `tutor-proxy` — round-robin worker
choice at `/session/start`, sticky routing by `session_id`/`student_id`
afterwards, one re-resolve+retry on transport failure (takeover-transparent
continuation), and `/student/mastery` served straight from Redis
(location-free, no worker involved) — or an external load balancer. With an
external LB the Redis routing table (`sess:<sid>`, `student:<id>`, written at
start and flipped by takeover) remains the source of truth for where each
session lives; the LB must respect it or confine itself to start-time worker
selection. Sessions without a checkpoint (the started-then-died window) are
not taken over: the proxy returns a clear 503 and the client restarts the
session — the event log is unharmed.

**Operational duties.**

- *Workers must be homogeneous.* Every worker registers the same model table
  (same model-ids mapping to the same model + adapter). Takeover rebuilds a
  session by `model-id` on another worker; a missing local registration
  errors. `examples/cluster-worker.lisp` is the reference: identical
  `register-model` calls per worker, only `:worker-id`/`:port` differ.
- *Isolate a worker after declaring it dead.* Lease expiry + takeover is how
  death is detected; once a worker is declared dead, remove it from the health
  check / kill the process. **Fencing (phase 14 A1)**: a worker whose lease
  lapsed (GC pause, heartbeat jitter) and whose sessions were adopted away
  drops those stale local handles at its next heartbeat (zombie self-check) —
  it can no longer step them or clobber the new owner's checkpoints. Residual
  contract: steps in flight at the takeover instant may interleave in the
  shared log (atomic `RPUSH`, contiguous seqs, replay-safe), and the window
  between takeover and the zombie's next heartbeat is bounded by the heartbeat
  interval. Per-request epoch fencing remains out of scope (hot-path cost);
  the `epoch` route field stays reserved for it.
- *Repeat starts are sticky.* At `/session/start` the proxy first consults
  the student's existing route: when that worker is still live, the request
  is forwarded to it and the worker's own same-student idempotency returns
  the active session (same session_id) — clients may retry start freely.
  Only when the routed worker is dead does the proxy fall back to
  round-robin, which can open a new session on another worker.

**Tuning.** `make-cluster-manager`: `heartbeat-ttl` (15s),
`heartbeat-interval` (5s), `scan-interval` (2s — also the takeover loss
window a restored student must re-solve), `takeover-interval` (5s),
`claim-ttl` (30s), `advertise-host`, Redis host/port/prefix. `make-tutor-proxy`:
`:port`, `:forward-timeout` (5s), `:kt-params`, prefix. The ticks are
single-steppable (`cluster-heartbeat-tick` etc.) for deterministic tests.

## Versioning

Feature-complete since `0.3.0`; the library is in maintenance mode:
defects are fixed, the public surface does not move (user-directed
exceptions are recorded in the CHANGELOG). `1.0.0` will be cut once a
real consumer project has validated libactr as a dependency in
production shape.

## System matrix

| System | What | Dependencies |
|---|---|---|
| `libactr` | Core engine: reader → compiler → matcher → tracer, sessions, event log, checkpoints, BKT knowledge tracing, authoring/bug-DSL — pure, zero globals, `:depends-on ()` | — |
| `libactr/server` | HTTP service layer: `tutor-server`, model registry, per-session locks, adapter protocol + reusable base, JSON wire format | `libactr`, hunchentoot, bordeaux-threads, yason |
| `libactr/redis-store` | Durable Redis (AOF) event-log backend, specializes the event-log protocol seam | `libactr`, cl-redis, yason |
| `libactr/cluster` | Multi-worker orchestration: manager (lease/checkpoint/takeover), checkpoint stores, front proxy | `libactr/server`, `libactr/redis-store`, dexador, yason |
| `libactr/oracle` | Dev-time dual-track oracle (runs models under the vendored ACT-R snapshot and compares) | `libactr`, `act-r` |
| `libactr/addition-tutor` | Reference example tutor (act-r tutorial addition model + buggy library + KC map) | `libactr` |
| `libactr/fraction-tutor`, `libactr/past-tense-tutor`, `libactr/subtraction-tutor` | Domain tutors: model load + buggy library + declarative KC attribution | `libactr` |
| `libactr/addition-adapter`, `libactr/fraction-adapter`, `libactr/past-tense-adapter`, `libactr/subtraction-adapter` | Domain adapters — the domain brain on the `standard-domain-adapter` base | `libactr/server` + the matching tutor |
| `libactr/test`, `libactr/redis-store-test`, `libactr/empirical-test`, `libactr/cluster-test` | FiveAM suites (suite name = system name minus `-test`) | fiveam (+ cl-redis where the layer needs it) |
| `libactr/server-test`, `libactr/*-adapter-test`, `libactr/*-tutor-test` | FiveAM suites joining `:libactr/server` — NOTE: the full server count requires loading the FOUR `*-adapter-test` systems first (fraction, addition, past-tense, subtraction — they share the suite) | fiveam, dexador |
| `libactr/dual` | Dual-track regression (joins the `:libactr` suite with the oracle loaded) | `libactr/test`, `libactr/oracle` |
| `libactr/concurrent` | Concurrent-isolation proof (joins the `:libactr` suite with bordeaux loaded) | `libactr/test`, bordeaux-threads |
| `libactr/image` | Portable image-dump smoke | `libactr` |

## Domains shipped

Each domain = a model + a tutor (`examples/`, model load + buggy library + KC
map) + an adapter (`src/`, the domain brain: action parsing, arithmetic, bug
detection, retrieval priming). The model lives in `models/<domain>.lisp` for
fraction / past-tense / subtraction; addition reuses the act-r tutorial
model (loaded via `libactr/addition-tutor`'s `examples/addition-tutor.lisp`).

- **addition** — counting-on strategy (act-r tutorial model); a `next-total`
  action drives a visible `increment-sum` + hidden `increment-count` pair.
- **fraction** — unlike-denominator addition; three KCs
  (`:common-denominator`, `:add-fractions`, `:simplify`) and four declared
  bugs (add-across, keep-left-denominator, no-convert, use-product).
- **past-tense** — English regular/irregular past tense; symbol slot values;
  KC routed by a problem variable (verb class → `:irregular-retrieval` vs
  `:regular-inflection`); three bugs (over-regularize, no-ed, vowel-analogy).
- **subtraction** — 2-digit column subtraction with borrowing; two KCs
  (`:column-subtract`, `:borrow`); borrow columns are conditional 2-intent
  steps (visible `subtract-ones-borrow` + hidden `propagate-borrow`); three
  bugs (borrow-ignore, always-borrow, off-by-one).

**Bug-DSL.** One `libactr:make-bug-spec` declaration generates the three
artifacts a tutor needs: the buggy production (appended by the tutor loader),
the detection predicate (`:when`, a restricted arithmetic S-expression over
goal/answer values with caller-supplied named predicates), and the
retrieval-prime/hidden-intent pair (`libactr:bug-intent`). `libactr:validate-bug-spec`
checks a spec (cross-references, arity, environment names) and the tutor
loaders fail loudly on errors. Ten bugs across three domains are declared
this way; see `examples/fraction-tutor.lisp` for the reference usage and
`src/authoring.lisp` for the evaluator's exact built-in set.

## API overview

Mirrors the tiered export surface of `src/package.lisp` (frozen symbol set;
tiers state audience and stability) plus the `:libactr/cluster` package.

### Tier 1 — core engine (stable contract)

| Symbol | Short description |
|---|---|
| `make-chunk`, `chunk-p`, `chunk-isa`, `chunk-slots` | chunk constructor/predicate/readers; slots are dotted `(slot . value)` pairs |
| `make-chunk-type-def`, `chunk-type-def-p`, `-name`, `-slots`, `-parent` | chunk-type definition (own + inherited slots, parent for ISA subtyping) |
| `make-model-definition`, `model-definition-p`, `-chunk-types`, `-chunks`, `-productions`, `-initial-goal`, `-params` | the read-only compile product all tracing shares |
| `production-p`, `make-production`, `production-name`, `-lhs`, `-rhs`, `-kind`, `-kc` | production accessors (`kind` is `:correct`/`:buggy`; `kc` the knowledge-component tag) |
| `read-model-file` | parse an ACT-R-subset model file; interns symbols in `*PACKAGE*` |
| `compile-model` | type-check chunks/productions, resolve slot tests, validate the initial goal |
| `matching-productions`, `match-production`, `model-matching-productions` | LHS matching with cross-buffer unification and ISA-subtype walks |
| `make-buffer-state`, `buffer-chunk`, `set-buffer-chunk` | buffer-state (eq hash buffer-name → chunk-or-nil) |
| `production-feedback` | a production's tutoring feedback string |
| `step-intent`, `make-step-intent`, `step-intent-p`, `-assignments`, `-action-type`, `-prime` | one student step: proposed `(buffer slot value)` deltas + optional pre-step buffer primes |
| `kc-event`, `make-kc-event`, `kc-event-p`, `-kc`, `-correct-p`, `-production`, `-kind` | one knowledge-component observation (the KT input) |
| `trace-result`, `make-trace-result`, `trace-result-p`, `-status`, `-production`, `-bindings`, `-feedback`, `-events`, `-next-state`, `-next-path`, `-alternatives` | the step diagnosis, carrying the advanced state/path when on-path |
| `chunk-slot` | read one slot of a chunk (nil if absent) |
| `make-buffer-pattern`, `-buffer`, `-modifier`, `-type-name`, `-slot-tests` | programmatic LHS construction |
| `make-slot-test`, `-slot`, `-kind`, `-operand` | programmatic slot test (`:literal`/`:variable`/`:negation`) |
| `make-action`, `-modifier`, `-buffer`, `-spec` | programmatic RHS action (`:=`/`:+`/`:-`/`:!`) |
| `apply-rhs` | apply a production's RHS to a copied buffer-state (pure) |
| `covers-p` | subset-consistent coverage: does the intent fall within an effect state |
| `path-continuity-strategy` | default disambiguation among multiple covering productions (definition order) |
| `trace-step` | pure single-step diagnosis: on-path advance, off-path-buggy, off-path |

### Tier 2 — session & persistence (stable contract)

| Symbol | Short description |
|---|---|
| `log-event`, `make-log-event`, `log-event-p`, `copy-log-event`, `-seq`, `-timestamp`, `-student-id`, `-session-id`, `-problem-id`, `-kc-event`, `-intent-summary`, `-result-summary` | the authoritative event record (mastery's single source of truth) |
| `make-event-log`, `event-log-p`, `log-append`, `log-all-events`, `log-events-since`, `log-last-seq`, `disconnect-log` | event-log protocol (in-memory backend; `disconnect-log` is the backend-teardown seam) |
| `serialize-event-log`, `deserialize-event-log` | pure log (de)serialization |
| `cognitive-session`, `cognitive-session-p`, `session-model`, `-state`, `-path`, `-log`, `-student-id`, `-problem-id`, `-model-id`, `-id`, `-step-count`, `-status` | one student × one problem traced session (all mutable state on the instance) |
| `start-session`, `step-session`, `end-session` | session lifecycle; `step-session` appends an event every step |
| `session-last-checkpoint` | most recent checkpoint plist (diagnostic channel for `:checkpoint-every`) |
| `checkpoint-session`, `restore-from-checkpoint` | snapshot solving state to pure data / rebuild a session from it |
| `student-session`, `student-session-p`, `student-session-student-id`, `-log`, `-sessions`, `-status` | cross-problem student entity: one shared event log per student |
| `start-student-session`, `end-student-session`, `register-cognitive-session` | student-session lifecycle |
| `compute-mastery` | fold events into per-KC `(:kc :correct :total :accuracy :p-l)`; P(L) is Corbett & Anderson BKT |
| `kt-params`, `kt-params-p`, `make-kt-params`, `-l0`, `-transit`, `-guess`, `-slip`, `-overrides` | BKT four parameters + per-KC override table |
| `kt-update`, `kt-posterior`, `kt-params-for` | BKT primitives (single-observation update, final posterior, per-KC parameter lookup) |

### Tier 3 — authoring (stable contract)

| Symbol | Short description |
|---|---|
| `apply-kc-map` | declarative production → KC attribution (alist, symbol-name matched) |
| `tag-symbols`, `untag-symbols` | symbol-tagging codec: intent/result summaries and cluster checkpoints round-trip symbols exactly |
| `bug-spec`, `make-bug-spec`, `bug-spec-p`, `-name`, `-kind`, `-kc`, `-feedback`, `-goal-type`, `-goal-guard`, `-answers`, `-fact-slots`, `-when` | one bug declaration → three generated artifacts |
| `bug-answer-env` | assemble the evaluation environment (goal slots + answers) for `:when` |
| `eval-bug-form` | restricted arithmetic S-expr evaluator (comparison/boolean/arithmetic builtins + caller-supplied named predicates) |
| `bug-production` | generate the buggy production from a spec |
| `detect-bug` | first-hit detection driver; spec list order is the detection order |
| `validate-bug-spec` | pure validator returning `(values errors warnings)` — cross-refs, arity, environment names |

### Tier 4 — service layer (`libactr/server` + `libactr/redis-store` systems; symbols in `:libactr`)

| Symbol | Short description |
|---|---|
| `domain-adapter`, `prepare-session`, `adapt-action`, `step-done?` | the three-generic engine/domain seam |
| `standard-domain-adapter` | reusable adapter base: model-package/terminal-production slots, plumbing helpers, default `step-done?` |
| `adapter-model-package`, `adapter-terminal-production` | base-class configuration readers |
| `adapter-intern`, `adapter-goal-slot`, `adapter-fact`, `adapter-set-goal`, `adapter-prime-pair`, `adapter-primed-intent` | adapter plumbing helpers (interning, goal reads/writes, fact chunks, primed intents) |
| `bug-goal-env`, `bug-intent` | bug-DSL runtime half: the goal environment and the prime + hidden intent pair derived from one spec |
| `bad-tutor-request`, `bad-tutor-request-message`, `signal-bad-request` | unified malformed-input condition (adapters signal; HTTP maps to 400) |
| `redis-event-log`, `redis-event-log-p`, `make-redis-event-log`, `-connection`, `-key`, `-host`, `-port` | durable Redis event-log backend |

### `:libactr/cluster` package (`libactr/cluster` system)

| Symbol | Short description |
|---|---|
| `cluster-manager`, `cluster-manager-p`, `make-cluster-manager`, `start-cluster-manager`, `stop-cluster-manager` | per-worker orchestration instance and lifecycle |
| `cluster-server`, `cluster-worker-id`, `cluster-threads` | manager readers (the wrapped tutor-server, id, tick threads) |
| `cluster-heartbeat-tick`, `cluster-scan-tick`, `cluster-takeover-tick` | single-steppable ticks (lease renewal, checkpoint scan, takeover) |
| `cluster-live-workers`, `cluster-adopt-session`, `cluster-join`, `cluster-leave` | registry views and session adoption |
| `cluster-route-get`, `cluster-route-set` | routing-table access — `(values worker-id epoch)` |
| `checkpoint-store`, `save-checkpoint`, `load-checkpoint` | checkpoint persistence protocol |
| `memory-checkpoint-store`, `make-memory-checkpoint-store` | in-memory store (tests / single process) |
| `redis-checkpoint-store`, `make-redis-checkpoint-store` | Redis store (takeover's source) |
| `tutor-proxy`, `tutor-proxy-p`, `make-tutor-proxy`, `stop-tutor-proxy`, `proxy-port`, `with-proxy-redis` | the front ingress: create/start, stop, bound port, redis access macro |

## Tests

A fresh clone of this repository alone runs all ten suites — the dual-track
oracle ships inside as `vendor/act-r/` (no sibling `act-r/` checkout, no
source-registry entry beyond this repo).

```bash
# core (also the entry point for the concurrent and dual legs, which load
# extra systems and add checks to the same :libactr suite):
sbcl --non-interactive --eval '(ql:quickload :libactr/test)' --eval '(5am:run! :libactr)'

# service layer (must load server-test AND all four adapter tests for the
# full count):
sbcl --non-interactive \
  --eval '(ql:quickload :libactr/server-test)' \
  --eval '(ql:quickload :libactr/addition-adapter-test)' \
  --eval '(ql:quickload :libactr/fraction-adapter-test)' \
  --eval '(ql:quickload :libactr/past-tense-adapter-test)' \
  --eval '(ql:quickload :libactr/subtraction-adapter-test)' \
  --eval '(5am:run! :libactr/server)'

# cluster (self-starts redis-server; skips when absent):
sbcl --non-interactive --eval '(ql:quickload :libactr/cluster-test)' --eval '(5am:run! :libactr/cluster)'

# remaining suites: :libactr/redis-store, :libactr/fraction-tutor,
# :libactr/past-tense-tutor, :libactr/subtraction-tutor, :libactr/empirical
```

Green baseline at 0.4.0, re-verified 2026-09-02 against the vendored
oracle (SBCL 2.6.8, assertion-level FiveAM counts, 0
failures / 0 skips): `:libactr` 381, `:libactr/server` 316, `:libactr/cluster` 128,
`:libactr/redis-store` 51, `:libactr/empirical` 35, `:libactr/fraction-tutor` 22,
`:libactr/past-tense-tutor` 24, `:libactr/subtraction-tutor` 21; the concurrent and
dual legs rerun the `:libactr` suite with bordeaux/act-r loaded (407 / 414 as
run). The cluster e2e spawns real SBCL worker subprocesses and kills one
mid-problem.

## Dual-track validation

The vendored ACT-R snapshot (`vendor/act-r/`, frozen at act-r@`da413e6`,
upstream SVN r3493) is a development-time oracle only. `libactr/oracle` runs
the same models under that ACT-R interpreter and `libactr/dual` cross-checks
matcher agreement on the tutorial corpus and all four domain models; runtime
deployments never load act-r. The shared model files (`models/*.lisp`) are
written in the common subset both engines accept.

### Upgrading the vendored oracle

Current sync point: upstream ACT-R SVN **r3493** (ACT-R 7.31.5,
`svn://act-r.psy.cmu.edu/actr7.x`), vendored from act-r@`da413e6`
(2026-09-02). When `actr7.x/` is updated upstream, the snapshot follows in
two hops:

1. **actr7.x → act-r port** — `svn update actr7.x`, note the new revision,
   then follow `docs/upstream-sync.md` in the [act-r source
   repo](https://gitee.com/hxz/act-r): `svn diff -r 3493:HEAD` against the
   recorded revision, copy changed files, update the asd, update its sync
   table, commit and push.
2. **act-r → this vendor tree** — re-vendor and re-verify:

   ```bash
   rm -rf vendor/act-r/src vendor/act-r/tutorial vendor/act-r/act-r.asd
   git -C <act-r-checkout> archive <new-sha> -- src tutorial act-r.asd \
     | tar -x -C vendor/act-r
   ```

   Update the provenance block in `vendor/act-r/README.md` and the CHANGELOG,
   then re-run the full ten-suite baseline before committing. The oracle is
   the reference the dual suite certifies against, so an upstream engine
   change can legitimately shift dual-track expectations — the baseline gate
   is where that surfaces, and any count change must be explained, not just
   accepted.

## License

MIT — see [LICENSE](LICENSE). Exception: the vendored snapshot under
`vendor/act-r/` is LGPL-2.1 (see [vendor/act-r/COPYING.LESSER](vendor/act-r/COPYING.LESSER));
everything else in this repository is MIT.
