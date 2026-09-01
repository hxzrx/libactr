;;;; mtt.asd — Model-Tracing Tutor engine

(asdf:defsystem "mtt"
  :version "0.2.0"
  :description "Independent, multi-user-safe model-tracing production engine"
  :long-description "mtt is the Path-B deliverable of the ACT-R project: an independent, multi-user-safe model-tracing tutor engine for cognitive-tutor deployments, following the Carnegie Learning / MATHia lineage of authoring models in ACT-R and shipping a dedicated runtime. The core holds zero global mutable state — every piece of per-session and per-student state lives on CLOS instances and locks stay in the service layer — so one Lisp image can trace many students concurrently; the core system itself has no dependencies. act-r/ is used strictly as a development-time dual-track oracle (mtt/oracle, mtt/dual); runtime deployments never load it."
  :license "MIT"
  :author "The mtt authors"
  :depends-on ()
  :serial t
  :components ((:file "src/package")
               (:file "src/types")
               (:file "src/reader")
               (:file "src/compiler")
               (:file "src/matcher")
               (:file "src/tracer")
               (:file "src/event-log")
               (:file "src/session")
               (:file "src/checkpoint")
               (:file "src/kt")
               (:file "src/student-session")
               (:file "src/authoring"))
  :in-order-to ((test-op (test-op "mtt/test"))))

;;; act-r/ dual-track oracle — dev-time only, pulls in act-r.
(asdf:defsystem "mtt/oracle"
  :description "act-r/ dual-track oracle adapter (dev-time)"
  :depends-on ("mtt" "act-r")
  :components ((:file "src/oracle")))

;;; Fast unit tests — no act-r dependency.
(asdf:defsystem "mtt/test"
  :depends-on ("mtt" "fiveam")
  :components ((:file "tests/suite")
               (:file "tests/test-types")
               (:file "tests/test-reader")
               (:file "tests/test-compiler")
               (:file "tests/test-matcher")
               (:file "tests/test-tracer")
               (:file "tests/test-event-log")
               (:file "tests/test-session")
               (:file "tests/test-checkpoint")
               (:file "tests/test-kt")
               (:file "tests/test-student-session")
               (:file "tests/test-authoring")))

;;; Dual-track regression — needs act-r via oracle.
(asdf:defsystem "mtt/dual"
  :depends-on ("mtt/test" "mtt/oracle")
  :components ((:file "tests/test-dual-track")
               (:file "tests/test-tracer-dual")))

;;; Fuller example tutor — a consumer of the core, not part of mtt itself.
(asdf:defsystem "mtt/addition-tutor"
  :depends-on ("mtt")
  :components ((:file "examples/addition-tutor")))

;;; Phase 4 concurrent-isolation proof — needs bordeaux-threads (portable APIv2).
(asdf:defsystem "mtt/concurrent"
  :depends-on ("mtt/test" "bordeaux-threads")
  :components ((:file "tests/test-concurrent")))

;;; Phase 4 portable image-dump smoke — de-risks Phase 5 deployment.
(asdf:defsystem "mtt/image"
  :depends-on ("mtt")
  :components ((:file "examples/image-smoke")))

;;; Phase 5 durable event-log backend — cl-redis (AOF). Own suite :mtt/redis-store.
(asdf:defsystem "mtt/redis-store"
  :depends-on ("mtt" "cl-redis" "yason")
  :components ((:file "src/redis-store"))
  :in-order-to ((test-op (test-op "mtt/redis-store-test"))))

(asdf:defsystem "mtt/redis-store-test"
  ;; mtt/past-tense-tutor: Phase 10 symbol specialization test interns
  ;; model-package symbols (:mtt/past-tense-tutor) for summary round-trip —
  ;; light system (depends on mtt only), no server stack pulled in.
  :depends-on ("mtt/redis-store" "mtt/past-tense-tutor" "fiveam")
  :components ((:file "tests/test-redis-store")))

;;; Phase 5 service layer — Hunchentoot + bordeaux-threads (domain-agnostic engine).
;;; adapter.lisp lives in the :mtt package (it is core-adjacent: the three protocol
;;; generics are exported from :mtt). server.lisp defines the :mtt/server package.
;;; http-api.lisp (Task 4) loads AFTER server.lisp because it references
;;; tutor-server accessors and the server-* ops defined there; it provides
;;; install-handlers!, which start-tutor-server (in server.lisp) calls at
;;; runtime. server.lisp carries a (declaim (notinline install-handlers!)) to
;;; silence the undefined-function compile-time warning; yason is pulled in for
;;; JSON encode/decode at the HTTP boundary.
(asdf:defsystem "mtt/server"
  :depends-on ("mtt" "hunchentoot" "bordeaux-threads" "yason")
  :serial t
  :components ((:file "src/adapter")
               (:file "src/server")
               (:file "src/http-api")))

(asdf:defsystem "mtt/server-test"
  ;; dexador: real-HTTP client for Task 6's over-the-wire smoke + concurrency
  ;;   tests. mtt/addition-adapter: provides build-addition-model +
  ;;   make-addition-adapter so the smoke tests exercise the real reference
  ;;   adapter (not just the stub). No cycle: mtt/addition-adapter (library)
  ;;   depends on mtt/server + mtt/addition-tutor only — not on any test system.
  :depends-on ("mtt/server" "mtt/addition-adapter" "fiveam" "dexador")
  :components ((:file "tests/test-server")
               (:file "tests/test-adapter-base")))

;;; Phase 5 Task 5 — reference addition domain adapter (reuses mtt/addition-tutor
;;; model-load + dm priming; implements the 3-method adapter protocol against the
;;; tutor-server). mtt/addition-adapter-test depends on mtt/server-test because
;;; the test file joins the :mtt/server FiveAM suite defined in test-server.lisp.
(asdf:defsystem "mtt/addition-adapter"
  :depends-on ("mtt/server" "mtt/addition-tutor")
  :components ((:file "src/addition-adapter")))

(asdf:defsystem "mtt/addition-adapter-test"
  :depends-on ("mtt/addition-adapter" "mtt/server-test" "fiveam")
  :components ((:file "tests/test-addition-adapter")))

;;; Phase 7 — fraction domain (second adapter). Model file is a data file under
;;; models/ (read by path); the tutor system loads+compiles it and appends the
;;; buggy library.
(asdf:defsystem "mtt/fraction-tutor"
  :depends-on ("mtt")
  :components ((:file "examples/fraction-tutor")))

(asdf:defsystem "mtt/fraction-tutor-test"
  :depends-on ("mtt/fraction-tutor" "fiveam")
  :components ((:file "tests/test-fraction-tutor")))

;;; Phase 7 Task 3 — reference fraction domain adapter (reuses mtt/fraction-tutor
;;; model-load; implements the 3-method adapter protocol against the
;;; tutor-server). The adapter is the domain brain: it computes correct answers,
;;; detects 4 bug patterns, and primes retrieval so the matcher routes
;;; on-path / off-path-buggy / off-path. mtt/fraction-adapter-test depends on
;;; mtt/server-test because the test file joins the :mtt/server FiveAM suite
;;; defined in test-server.lisp.
(asdf:defsystem "mtt/fraction-adapter"
  :depends-on ("mtt/server" "mtt/fraction-tutor")
  :components ((:file "src/fraction-adapter")))

(asdf:defsystem "mtt/fraction-adapter-test"
  :depends-on ("mtt/fraction-adapter" "mtt/server-test" "fiveam")
  :components ((:file "tests/test-fraction-adapter")))

;;; Phase 10 — past-tense domain (third adapter: retrieval-heavy, symbol slot
;;; values, single-step). Model file under models/; tutor system loads+compiles
;;; it and appends the buggy library.
(asdf:defsystem "mtt/past-tense-tutor"
  :depends-on ("mtt")
  :components ((:file "examples/past-tense-tutor")))

(asdf:defsystem "mtt/past-tense-tutor-test"
  ;; phase 14 C7: the sad-path gate test drives the ADAPTER's
  ;; %validate-specs! (the gate lives in make-past-tense-adapter, not the
  ;; tutor loader), so the adapter system must be in the image for the test
  ;; file to even read the symbol.
  :depends-on ("mtt/past-tense-tutor" "mtt/past-tense-adapter" "fiveam")
  :components ((:file "tests/test-past-tense-tutor")))

;;; Phase 10 Task 3 — third domain adapter (past-tense). Reuses
;;; mtt/past-tense-tutor model-load; the adapter is the domain brain (lexicon
;;; lookup, bug detection, retrieval priming). mtt/past-tense-adapter-test
;;; depends on mtt/server-test because the test file joins the :mtt/server
;;; FiveAM suite defined in test-server.lisp (mirrors fraction-adapter).
(asdf:defsystem "mtt/past-tense-adapter"
  :depends-on ("mtt/server" "mtt/past-tense-tutor")
  :components ((:file "src/past-tense-adapter")))

(asdf:defsystem "mtt/past-tense-adapter-test"
  :depends-on ("mtt/past-tense-adapter" "mtt/server-test" "fiveam")
  :components ((:file "tests/test-past-tense-adapter")))

;;; Phase 11 — subtraction domain (second arithmetic adapter: 2-digit column
;;; subtraction with borrowing, conditional multi-step borrow columns). Model
;;; file under models/; tutor system loads+compiles it and appends the buggy
;;; library.
(asdf:defsystem "mtt/subtraction-tutor"
  :depends-on ("mtt")
  :components ((:file "examples/subtraction-tutor")))

(asdf:defsystem "mtt/subtraction-tutor-test"
  :depends-on ("mtt/subtraction-tutor" "fiveam")
  :components ((:file "tests/test-subtraction-tutor")))

;;; Phase 11 Task 2 — second arithmetic domain adapter (subtraction). Reuses
;;; mtt/subtraction-tutor model-load; the adapter is the domain brain (column
;;; arithmetic, bug detection, retrieval priming) and returns CONDITIONAL
;;; intent lists: a borrow column = 2 intents (visible subtract-ones-borrow,
;;; hidden propagate-borrow), other columns = 1. mtt/subtraction-adapter-test
;;; depends on mtt/server-test because the test file joins the :mtt/server
;;; FiveAM suite defined in test-server.lisp (mirrors the other adapters).
(asdf:defsystem "mtt/subtraction-adapter"
  :depends-on ("mtt/server" "mtt/subtraction-tutor")
  :components ((:file "src/subtraction-adapter")))

(asdf:defsystem "mtt/subtraction-adapter-test"
  :depends-on ("mtt/subtraction-adapter" "mtt/server-test" "fiveam")
  :components ((:file "tests/test-subtraction-adapter")))

;;; Phase 7 Task 5 — empirical validation harness. Synthetic-student traces drive
;;; the engine; assertions check tracing correctness + P(L) monotonicity/
;;; convergence/interval + per-KC distinctness. Cross-domain: fraction + addition.
;;; Own suite :mtt/empirical (does NOT join :mtt — pure engine validation, not a
;;; regression of core internals). Two legs: tracing correctness via
;;; server-step-session; P(L) math via direct compute-mastery (deterministic).
(asdf:defsystem "mtt/empirical-test"
  :depends-on ("mtt/fraction-adapter" "mtt/addition-adapter"
               "mtt/past-tense-adapter" "mtt/subtraction-adapter" "fiveam")
  :components ((:file "tests/test-empirical")))

;;; Phase 13 — multi-worker orchestration (complete orchestration layer).
;;; cluster.lisp: cluster-manager CLOS (join/heartbeat/scan/takeover ticks +
;;; checkpoint-store protocol + redis impl). proxy.lisp: the thin front proxy
;;; (routes by student_id/session_id from the redis routing table, forwards
;;; via dexador, one re-resolve retry on transport failure; /student/mastery
;;; is served from redis directly — location-free). Same package :mtt/cluster
;;; across both files (mirrors mtt/server's server.lisp + http-api.lisp).
(asdf:defsystem "mtt/cluster"
  :depends-on ("mtt/server" "mtt/redis-store" "dexador" "yason")
  :components ((:file "src/cluster")
               (:file "src/proxy")))

(asdf:defsystem "mtt/cluster-test"
  ;; Suite :mtt/cluster (the 10th, merge-gate suite). Self-starts redis-server
  ;; (skip if absent); the e2e file additionally spawns SBCL worker
  ;; subprocesses via examples/cluster-worker.lisp.
  :depends-on ("mtt/cluster" "mtt/subtraction-adapter" "fiveam" "dexador")
  :components ((:file "tests/test-cluster")
               (:file "tests/test-cluster-e2e")))
