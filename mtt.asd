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
               (:file "src/matcher"))
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
               (:file "tests/test-matcher")))

;;; Dual-track regression — needs act-r via oracle.
(asdf:defsystem "mtt/dual"
  :depends-on ("mtt/test" "mtt/oracle")
  :components ((:file "tests/test-dual-track")))
