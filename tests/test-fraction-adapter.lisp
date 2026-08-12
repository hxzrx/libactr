;;;; tests/test-fraction-adapter.lisp — fraction adapter tests (Phase 7).
;;;; Suite :mtt/server (defined in tests/test-server.lisp). Unit tests here drive
;;;; the programmatic tutor-server API; the over-HTTP e2e is added in Task 4.
(defpackage :mtt/fraction-adapter-test
  (:use :cl :5am))
(in-package :mtt/fraction-adapter-test)
(in-suite :mtt/server)

(defun %server ()
  "tutor-server with fraction model+adapter registered under \"frac\". No acceptor."
  (let ((s (mtt/server:start-tutor-server :port 0 :start-acceptor-p nil)))
    (mtt/server:register-model s "frac"
                               (mtt/fraction-adapter:build-fraction-model)
                               (mtt/fraction-adapter:make-fraction-adapter))
    s))

(defun %step (s sid action)
  "Step and return the trace-result (first value)."
  (nth-value 0 (mtt/server:server-step-session s sid action)))

(test fraction-adapter.on-path-full-problem
  "1/2 + 1/3: common-denom 6 (on-path) -> sum 5/6 (on-path, done)."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (mtt/server:server-start-session s "f" "1/2+1/3" "frac")))
           ;; common-denom 6 -> find-common-denominator on-path
           (let ((r1 (%step s sid '(("type" . "common-denom") ("value" . "6")))))
             (is (eq :on-path (mtt:trace-result-status r1)))
             (is (string= "FIND-COMMON-DENOMINATOR"
                          (symbol-name (mtt:production-name
                                        (mtt:trace-result-production r1)))))
             (is (null (mtt:step-done? (mtt/fraction-adapter:make-fraction-adapter) r1 nil))))
           ;; sum 5/6 -> add-fractions on-path, done
           (let ((r2 (%step s sid '(("type" . "sum") ("num" . "5") ("denom" . "6")))))
             (is (eq :on-path (mtt:trace-result-status r2)))
             (is (string= "ADD-FRACTIONS"
                          (symbol-name (mtt:production-name
                                        (mtt:trace-result-production r2)))))
             (is (mtt:step-done? (mtt/fraction-adapter:make-fraction-adapter) r2 nil))))
      (mtt/server:stop-tutor-server s))))

(test fraction-adapter.buggy-add-across
  "1/2 + 1/3: correct cdenom 6, then student sums 2/5 (add-across) -> off-path-buggy
with buggy-add-across, feedback present."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (mtt/server:server-start-session s "f" "1/2+1/3" "frac")))
           (%step s sid '(("type" . "common-denom") ("value" . "6")))
           (let ((r (%step s sid '(("type" . "sum") ("num" . "2") ("denom" . "5")))))
             (is (eq :off-path-buggy (mtt:trace-result-status r)))
             (is (string= "BUGGY-ADD-ACROSS"
                          (symbol-name (mtt:production-name
                                        (mtt:trace-result-production r)))))
             (is (stringp (mtt:trace-result-feedback r)))))
      (mtt/server:stop-tutor-server s))))

(test fraction-adapter.buggy-use-product
  "1/4 + 1/6: LCM=12, product=24. Student reports 24 -> off-path-buggy use-product."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (mtt/server:server-start-session s "f" "1/4+1/6" "frac")))
           (let ((r (%step s sid '(("type" . "common-denom") ("value" . "24")))))
             (is (eq :off-path-buggy (mtt:trace-result-status r)))
             (is (string= "BUGGY-USE-PRODUCT"
                          (symbol-name (mtt:production-name
                                        (mtt:trace-result-production r)))))))
      (mtt/server:stop-tutor-server s))))

(test fraction-adapter.unclassified-off-path
  "1/2 + 1/3: student reports a wrong cdenom matching NO bug (e.g. 7) -> :off-path."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (mtt/server:server-start-session s "f" "1/2+1/3" "frac")))
           (let ((r (%step s sid '(("type" . "common-denom") ("value" . "7")))))
             (is (eq :off-path (mtt:trace-result-status r)))))
      (mtt/server:stop-tutor-server s))))
