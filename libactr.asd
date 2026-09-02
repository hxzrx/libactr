;;;; libactr.asd — Model-Tracing Tutor engine

(asdf:defsystem "libactr"
  :version "0.3.1"
  :description "Independent, multi-user-safe model-tracing production engine"
  :long-description "libactr is the Path-B deliverable of the ACT-R project: an independent, multi-user-safe model-tracing tutor engine for cognitive-tutor deployments, following the Carnegie Learning / MATHia lineage of authoring models in ACT-R and shipping a dedicated runtime. The core holds zero global mutable state — every piece of per-session and per-student state lives on CLOS instances and locks stay in the service layer — so one Lisp image can trace many students concurrently; the core system itself has no dependencies. act-r/ is used strictly as a development-time dual-track oracle (libactr/oracle, libactr/dual); runtime deployments never load it."
  :license "MIT"
  :author "The libactr authors"
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
  :in-order-to ((test-op (test-op "libactr/test"))))

;;; act-r/ dual-track oracle — dev-time only, pulls in act-r.
(asdf:defsystem "libactr/oracle"
  :description "act-r/ dual-track oracle adapter (dev-time)"
  :depends-on ("libactr" "act-r")
  :components ((:file "src/oracle")))

;;; Fast unit tests — no act-r dependency.
(asdf:defsystem "libactr/test"
  :depends-on ("libactr" "fiveam")
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
(asdf:defsystem "libactr/dual"
  :depends-on ("libactr/test" "libactr/oracle")
  :components ((:file "tests/test-dual-track")
               (:file "tests/test-tracer-dual")))

;;; Fuller example tutor — a consumer of the core, not part of libactr itself.
(asdf:defsystem "libactr/addition-tutor"
  :depends-on ("libactr")
  :components ((:file "examples/addition-tutor")))

;;; Phase 4 concurrent-isolation proof — needs bordeaux-threads (portable APIv2).
(asdf:defsystem "libactr/concurrent"
  :depends-on ("libactr/test" "bordeaux-threads")
  :components ((:file "tests/test-concurrent")))

;;; Phase 4 portable image-dump smoke — de-risks Phase 5 deployment.
(asdf:defsystem "libactr/image"
  :depends-on ("libactr")
  :components ((:file "examples/image-smoke")))

;;; Phase 5 durable event-log backend — cl-redis (AOF). Own suite :libactr/redis-store.
(asdf:defsystem "libactr/redis-store"
  :depends-on ("libactr" "cl-redis" "yason")
  :components ((:file "src/redis-store"))
  :in-order-to ((test-op (test-op "libactr/redis-store-test"))))

(asdf:defsystem "libactr/redis-store-test"
  ;; libactr/past-tense-tutor: Phase 10 symbol specialization test interns
  ;; model-package symbols (:libactr/past-tense-tutor) for summary round-trip —
  ;; light system (depends on libactr only), no server stack pulled in.
  :depends-on ("libactr/redis-store" "libactr/past-tense-tutor" "fiveam")
  :components ((:file "tests/test-redis-store")))

;;; Phase 5 service layer — Hunchentoot + bordeaux-threads (domain-agnostic engine).
;;; adapter.lisp lives in the :libactr package (it is core-adjacent: the three protocol
;;; generics are exported from :libactr). server.lisp defines the :libactr/server package.
;;; http-api.lisp (Task 4) loads AFTER server.lisp because it references
;;; tutor-server accessors and the server-* ops defined there; it provides
;;; install-handlers!, which start-tutor-server (in server.lisp) calls at
;;; runtime. server.lisp carries a (declaim (notinline install-handlers!)) to
;;; silence the undefined-function compile-time warning; yason is pulled in for
;;; JSON encode/decode at the HTTP boundary.
(asdf:defsystem "libactr/server"
  :depends-on ("libactr" "hunchentoot" "bordeaux-threads" "yason")
  :serial t
  :components ((:file "src/adapter")
               (:file "src/server")
               (:file "src/http-api")))

(asdf:defsystem "libactr/server-test"
  ;; dexador: real-HTTP client for Task 6's over-the-wire smoke + concurrency
  ;;   tests. libactr/addition-adapter: provides build-addition-model +
  ;;   make-addition-adapter so the smoke tests exercise the real reference
  ;;   adapter (not just the stub). No cycle: libactr/addition-adapter (library)
  ;;   depends on libactr/server + libactr/addition-tutor only — not on any test system.
  :depends-on ("libactr/server" "libactr/addition-adapter" "fiveam" "dexador")
  :components ((:file "tests/test-server")
               (:file "tests/test-adapter-base")))

;;; Phase 5 Task 5 — reference addition domain adapter (reuses libactr/addition-tutor
;;; model-load + dm priming; implements the 3-method adapter protocol against the
;;; tutor-server). libactr/addition-adapter-test depends on libactr/server-test because
;;; the test file joins the :libactr/server FiveAM suite defined in test-server.lisp.
(asdf:defsystem "libactr/addition-adapter"
  :depends-on ("libactr/server" "libactr/addition-tutor")
  :components ((:file "src/addition-adapter")))

(asdf:defsystem "libactr/addition-adapter-test"
  :depends-on ("libactr/addition-adapter" "libactr/server-test" "fiveam")
  :components ((:file "tests/test-addition-adapter")))

;;; Phase 7 — fraction domain (second adapter). Model file is a data file under
;;; models/ (read by path); the tutor system loads+compiles it and appends the
;;; buggy library.
(asdf:defsystem "libactr/fraction-tutor"
  :depends-on ("libactr")
  :components ((:file "examples/fraction-tutor")))

(asdf:defsystem "libactr/fraction-tutor-test"
  :depends-on ("libactr/fraction-tutor" "fiveam")
  :components ((:file "tests/test-fraction-tutor")))

;;; Phase 7 Task 3 — reference fraction domain adapter (reuses libactr/fraction-tutor
;;; model-load; implements the 3-method adapter protocol against the
;;; tutor-server). The adapter is the domain brain: it computes correct answers,
;;; detects 4 bug patterns, and primes retrieval so the matcher routes
;;; on-path / off-path-buggy / off-path. libactr/fraction-adapter-test depends on
;;; libactr/server-test because the test file joins the :libactr/server FiveAM suite
;;; defined in test-server.lisp.
(asdf:defsystem "libactr/fraction-adapter"
  :depends-on ("libactr/server" "libactr/fraction-tutor")
  :components ((:file "src/fraction-adapter")))

(asdf:defsystem "libactr/fraction-adapter-test"
  :depends-on ("libactr/fraction-adapter" "libactr/server-test" "fiveam")
  :components ((:file "tests/test-fraction-adapter")))

;;; Phase 10 — past-tense domain (third adapter: retrieval-heavy, symbol slot
;;; values, single-step). Model file under models/; tutor system loads+compiles
;;; it and appends the buggy library.
(asdf:defsystem "libactr/past-tense-tutor"
  :depends-on ("libactr")
  :components ((:file "examples/past-tense-tutor")))

(asdf:defsystem "libactr/past-tense-tutor-test"
  ;; phase 14 C7: the sad-path gate test drives the ADAPTER's
  ;; %validate-specs! (the gate lives in make-past-tense-adapter, not the
  ;; tutor loader), so the adapter system must be in the image for the test
  ;; file to even read the symbol.
  :depends-on ("libactr/past-tense-tutor" "libactr/past-tense-adapter" "fiveam")
  :components ((:file "tests/test-past-tense-tutor")))

;;; Phase 10 Task 3 — third domain adapter (past-tense). Reuses
;;; libactr/past-tense-tutor model-load; the adapter is the domain brain (lexicon
;;; lookup, bug detection, retrieval priming). libactr/past-tense-adapter-test
;;; depends on libactr/server-test because the test file joins the :libactr/server
;;; FiveAM suite defined in test-server.lisp (mirrors fraction-adapter).
(asdf:defsystem "libactr/past-tense-adapter"
  :depends-on ("libactr/server" "libactr/past-tense-tutor")
  :components ((:file "src/past-tense-adapter")))

(asdf:defsystem "libactr/past-tense-adapter-test"
  :depends-on ("libactr/past-tense-adapter" "libactr/server-test" "fiveam")
  :components ((:file "tests/test-past-tense-adapter")))

;;; Phase 11 — subtraction domain (second arithmetic adapter: 2-digit column
;;; subtraction with borrowing, conditional multi-step borrow columns). Model
;;; file under models/; tutor system loads+compiles it and appends the buggy
;;; library.
(asdf:defsystem "libactr/subtraction-tutor"
  :depends-on ("libactr")
  :components ((:file "examples/subtraction-tutor")))

(asdf:defsystem "libactr/subtraction-tutor-test"
  :depends-on ("libactr/subtraction-tutor" "fiveam")
  :components ((:file "tests/test-subtraction-tutor")))

;;; Phase 11 Task 2 — second arithmetic domain adapter (subtraction). Reuses
;;; libactr/subtraction-tutor model-load; the adapter is the domain brain (column
;;; arithmetic, bug detection, retrieval priming) and returns CONDITIONAL
;;; intent lists: a borrow column = 2 intents (visible subtract-ones-borrow,
;;; hidden propagate-borrow), other columns = 1. libactr/subtraction-adapter-test
;;; depends on libactr/server-test because the test file joins the :libactr/server
;;; FiveAM suite defined in test-server.lisp (mirrors the other adapters).
(asdf:defsystem "libactr/subtraction-adapter"
  :depends-on ("libactr/server" "libactr/subtraction-tutor")
  :components ((:file "src/subtraction-adapter")))

(asdf:defsystem "libactr/subtraction-adapter-test"
  :depends-on ("libactr/subtraction-adapter" "libactr/server-test" "fiveam")
  :components ((:file "tests/test-subtraction-adapter")))

;;; Phase 7 Task 5 — empirical validation harness. Synthetic-student traces drive
;;; the engine; assertions check tracing correctness + P(L) monotonicity/
;;; convergence/interval + per-KC distinctness. Cross-domain: fraction + addition.
;;; Own suite :libactr/empirical (does NOT join :libactr — pure engine validation, not a
;;; regression of core internals). Two legs: tracing correctness via
;;; server-step-session; P(L) math via direct compute-mastery (deterministic).
(asdf:defsystem "libactr/empirical-test"
  :depends-on ("libactr/fraction-adapter" "libactr/addition-adapter"
               "libactr/past-tense-adapter" "libactr/subtraction-adapter" "fiveam")
  :components ((:file "tests/test-empirical")))

;;; Phase 13 — multi-worker orchestration (complete orchestration layer).
;;; cluster.lisp: cluster-manager CLOS (join/heartbeat/scan/takeover ticks +
;;; checkpoint-store protocol + redis impl). proxy.lisp: the thin front proxy
;;; (routes by student_id/session_id from the redis routing table, forwards
;;; via dexador, one re-resolve retry on transport failure; /student/mastery
;;; is served from redis directly — location-free). Same package :libactr/cluster
;;; across both files (mirrors libactr/server's server.lisp + http-api.lisp).
(asdf:defsystem "libactr/cluster"
  :depends-on ("libactr/server" "libactr/redis-store" "dexador" "yason")
  :components ((:file "src/cluster")
               (:file "src/proxy")))

(asdf:defsystem "libactr/cluster-test"
  ;; Suite :libactr/cluster (the 10th, merge-gate suite). Self-starts redis-server
  ;; (skip if absent); the e2e file additionally spawns SBCL worker
  ;; subprocesses via examples/cluster-worker.lisp.
  :depends-on ("libactr/cluster" "libactr/subtraction-adapter" "fiveam" "dexador")
  :components ((:file "tests/test-cluster")
               (:file "tests/test-cluster-e2e")))
