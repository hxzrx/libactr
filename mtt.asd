;;;; mtt.asd — Model-Tracing Tutor engine

(asdf:defsystem "mtt"
  :version "0.1.0"
  :description "Independent, multi-user-safe model-tracing production engine"
  :license "TBD"
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
               (:file "src/student-session"))
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
               (:file "tests/test-student-session")))

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
  :depends-on ("mtt/redis-store" "fiveam")
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
  :depends-on ("mtt/server" "fiveam")
  :components ((:file "tests/test-server")))

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
