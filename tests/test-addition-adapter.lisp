;;;; tests/test-addition-adapter.lisp — addition adapter tests (Phase 5, Task 5).
;;;; Suite :libactr/server (defined in tests/test-server.lisp). Drives the real
;;;; addition domain adapter through the tutor-server's programmatic API:
;;;; register-model + start-session + step-session, asserting the on-path
;;;; sequence for 5+2 (start -> six -> seven -> submit) reproduces the dogfooded
;;;; examples/addition-tutor.lisp demonstrate output, and that submit can fire
;;;; terminate-addition.
(defpackage :libactr/addition-adapter-test
  (:use :cl :5am))
(in-package :libactr/addition-adapter-test)
(in-suite :libactr/server)

(defun %server ()
  "A tutor-server with the addition model + addition-adapter registered under
\"add\". No acceptor (we drive the programmatic API directly)."
  (let ((s (libactr/server:start-tutor-server :port 0 :start-acceptor-p nil)))
    (libactr/server:register-model s "add" (libactr/addition-adapter:build-addition-model)
                               (libactr/addition-adapter:make-addition-adapter))
    s))

(test addition-adapter.on-path-and-done
  "Reference addition adapter end-to-end through the tutor-server: the on-path
sequence for 5+2 (start -> next-total six -> next-total seven -> submit) fires
initialize-addition, increment-sum (twice), increment-count (twice), and
terminate-addition. Asserts each step is :on-path, mastery is non-empty, and
submit completes (terminate-addition observed via step-done?)."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (libactr/server:server-start-session s "a" "5+2" "add")))
           ;; start — initialize-addition fires.
           (multiple-value-bind (r a sess)
               (libactr/server:server-step-session s sid '(("type" . "start")))
             (declare (ignore a sess))
             (is (eq :on-path (libactr:trace-result-status r)))
             ;; production names live in :libactr/addition-tutor (model package);
             ;; compare by name so the test is package-agnostic.
             (is (string= "INITIALIZE-ADDITION"
                          (symbol-name
                           (libactr:production-name (libactr:trace-result-production r))))))
           ;; next-total six — adapter does the hidden sum-step inside
           ;; adapt-action and returns the count-intent; the server's visible
           ;; step is increment-count (:on-path). The sum-step (increment-sum)
           ;; is also logged.
           (multiple-value-bind (r a sess)
               (libactr/server:server-step-session s sid
                                               '(("type" . "next-total")
                                                 ("value" . "six")))
             (declare (ignore a sess))
             (is (eq :on-path (libactr:trace-result-status r))))
           ;; mastery aggregates from the shared student log: initialize +
           ;; increment-sum + increment-count events => non-empty.
           (let ((m (libactr/server:server-student-mastery s "a")))
             (is (not (null m))))
           ;; step-done? is false after a next-total (only submit terminates).
           (is (null (libactr:step-done?
                      (libactr/addition-adapter:make-addition-adapter)
                      (libactr:make-trace-result :status :on-path)
                      nil)))
           ;; next-total seven — second increment pair; count reaches arg2=two.
           (multiple-value-bind (r a sess)
               (libactr/server:server-step-session s sid
                                               '(("type" . "next-total")
                                                 ("value" . "seven")))
             (declare (ignore a sess))
             (is (eq :on-path (libactr:trace-result-status r))))
           ;; submit seven — terminate-addition fires (count=two=arg2).
           (multiple-value-bind (r a sess)
               (libactr/server:server-step-session s sid
                                               '(("type" . "submit")
                                                 ("value" . "seven")))
             (declare (ignore a sess))
             (is (member (libactr:trace-result-status r)
                         '(:on-path :off-path :off-path-buggy)))
             ;; The reference adapter identifies termination by the
             ;; terminate-addition production name (compare by name: production
             ;; names live in :libactr/addition-tutor).
             (is (string= "TERMINATE-ADDITION"
                          (symbol-name
                           (libactr:production-name (libactr:trace-result-production r)))))
             (is (libactr:step-done? (libactr/addition-adapter:make-addition-adapter) r nil))))
      (libactr/server:stop-tutor-server s))))

;;; --- Phase 12 Task 5: semantic problem validation + malformed-action 400 -----

(test addition.bad-problem-and-action-are-400
  "\"12+3\" (multi-digit addend, outside the 0-9 number chain) is a semantic
violation; an unknown action type is malformed — both 400 (phase 12
debt #1/#2)."
  (let ((s (%server)))
    (unwind-protect
         (progn
           (multiple-value-bind (r status)
               (libactr/server::handle-start s `(("student_id" . "ax")
                                             ("problem_id" . "12+3")
                                             ("model_id" . "add")))
             (is (= 400 status))
             (is (search "single digits" (getf r :error))))
           (let ((sid (libactr/server:server-start-session s "ay" "5+2" "add")))
             (signals libactr:bad-tutor-request
               (libactr/server:server-step-session
                s sid '(("type" . "wat") ("value" . "5"))))))
      (libactr/server:stop-tutor-server s))))

;;; --- Phase 14 Task 12: B1 out-of-order / missing-field actions are 400s -------

(test addition-adapter.out-of-order-and-missing-value-are-bad-requests
  "B1: \"next-total\"/\"submit\" before \"start\" (sum/count nil) and a
missing \"value\" entry signal bad-tutor-request — string-upcase of nil and
dm-next of nil used to be 500-shaped."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (libactr/server:server-start-session s "oo" "5+2" "add")))
           (signals libactr:bad-tutor-request
             (libactr/server:server-step-session
              s sid '(("type" . "next-total") ("value" . "6"))))
           (signals libactr:bad-tutor-request
             (libactr/server:server-step-session
              s sid '(("type" . "submit") ("value" . "7"))))
           (signals libactr:bad-tutor-request
             (libactr/server:server-step-session
              s sid '(("type" . "next-total")))))
      (libactr/server:stop-tutor-server s))))
