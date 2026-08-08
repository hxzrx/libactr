;;;; tests/test-types.lisp — type/data-model tests (placeholder; Task 2)
(in-package :mtt/test)
(in-suite :mtt)

;; Smoke test: loading the mtt/test system succeeds and the :mtt package exists.
;; (fboundp checks for defined-but-not-yet-implemented functions are deferred
;;  to later tasks; here we only verify the package was actually created.)
(test smoke-package-exists-after-load
  (is (find-package :mtt)))
