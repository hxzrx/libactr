;;;; tests/test-subtraction-adapter.lisp — subtraction adapter tests (Phase 11).
;;;; Suite :mtt/server (defined in tests/test-server.lisp). Drives the routing
;;;; matrix (spec §8.2) through the programmatic tutor-server API: on-path
;;;; borrow/no-borrow full problems, conditional 2-intent borrow steps (mastery
;;;; totals prove the hidden propagate-borrow is logged), the 3 bug branches,
;;;; unclassified off-path, and the degenerate mirror-equals-correct
;;;; documentation case (spec §2.1). The over-HTTP e2e is added in Task 3.
(defpackage :mtt/subtraction-adapter-test
  (:use :cl :5am))
(in-package :mtt/subtraction-adapter-test)
(in-suite :mtt/server)

(defun %server ()
  "tutor-server with subtraction model+adapter registered under \"sub\". No acceptor."
  (let ((s (mtt/server:start-tutor-server :port 0 :start-acceptor-p nil)))
    (mtt/server:register-model s "sub"
                               (mtt/subtraction-adapter:build-subtraction-model)
                               (mtt/subtraction-adapter:make-subtraction-adapter))
    s))

(defun %step (s sid value)
  "Report one column digit VALUE; return the trace-result (first value)."
  (nth-value 0
    (mtt/server:server-step-session
     s sid `(("type" . "digit") ("value" . ,(princ-to-string value))))))

(defun %status-name (r)
  (values (mtt:trace-result-status r)
          (and (mtt:trace-result-production r)
               (symbol-name (mtt:production-name
                             (mtt:trace-result-production r))))))

(defun %entry (mastery kc)
  (find kc mastery :key (lambda (e) (getf e :kc))))

(defun %full-problem (s student problem ones tens)
  "Drive one full 2-digit problem start->ones->tens->end (closed loop per the
Phase 10 lesson: server-start-session is idempotent on the student's ACTIVE
session, so each problem must end before the next starts)."
  (let ((sid (mtt/server:server-start-session s student problem "sub")))
    (%step s sid ones)
    (%step s sid tens)
    (mtt/server:server-end-session s sid)))

(test subtraction-adapter.on-path-borrow-full-problem
  "52-18: ones 4 (12-8 with borrow) -> on-path SUBTRACT-ONES-BORROW (the
FIRST/visible step of the conditional 2-intent list), NOT done; the hidden
propagate-borrow has already run server-side (stage now tens, top-tens
rewritten to 4), so the next digit action is a tens step: 3 -> on-path
SUBTRACT-TENS-DIRECT, done."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (mtt/server:server-start-session s "s1" "52-18" "sub")))
           (let ((r1 (%step s sid 4)))
             (multiple-value-bind (status name) (%status-name r1)
               (is (eq :on-path status))
               (is (string= "SUBTRACT-ONES-BORROW" name)))
             (is (null (mtt:step-done?
                        (mtt/subtraction-adapter:make-subtraction-adapter) r1 nil))))
           (let ((r2 (%step s sid 3)))
             (multiple-value-bind (status name) (%status-name r2)
               (is (eq :on-path status))
               (is (string= "SUBTRACT-TENS-DIRECT" name)))
             (is (mtt:step-done?
                  (mtt/subtraction-adapter:make-subtraction-adapter) r2 nil))))
      (mtt/server:stop-tutor-server s))))

(test subtraction-adapter.on-path-no-borrow-full-problem
  "47-25: ones 2 (7-5, no borrow) -> on-path SUBTRACT-ONES-DIRECT (single
intent); tens 2 -> on-path SUBTRACT-TENS-DIRECT, done."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (mtt/server:server-start-session s "s2" "47-25" "sub")))
           (multiple-value-bind (status name) (%status-name (%step s sid 2))
             (is (eq :on-path status))
             (is (string= "SUBTRACT-ONES-DIRECT" name)))
           (multiple-value-bind (status name) (%status-name (%step s sid 2))
             (is (eq :on-path status))
             (is (string= "SUBTRACT-TENS-DIRECT" name))))
      (mtt/server:stop-tutor-server s))))

(test subtraction-adapter.conditional-multi-step-logs-both-events
  "Borrow columns log TWO events per action (spec §8.2, Phase 6 invariant):
one full borrow problem (52-18) -> :borrow total=2 (subtract-ones-borrow +
hidden propagate-borrow) and :column-subtract total=1 (tens). A no-borrow
problem (47-25) for another student -> :column-subtract total=2 only, NO
:borrow entry — the multi-step list length is genuinely conditional."
  (let ((s (%server)))
    (unwind-protect
         (progn
           (%full-problem s "s3" "52-18" 4 3)
           (let ((m (mtt/server:server-student-mastery s "s3")))
             (is (= 2 (length m)))
             (is (= 2 (getf (%entry m :borrow) :total)))
             (is (= 1 (getf (%entry m :column-subtract) :total))))
           (%full-problem s "s4" "47-25" 2 2)
           (let ((m (mtt/server:server-student-mastery s "s4")))
             (is (= 1 (length m)))
             (is (eq :column-subtract (getf (first m) :kc)))
             (is (= 2 (getf (first m) :total)))))
      (mtt/server:stop-tutor-server s))))

(test subtraction-adapter.buggy-borrow-ignore
  "43-27 (ones 3-7): student reports 4 (mirror 7-3) -> off-path-buggy
BUGGY-BORROW-IGNORE with feedback present."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (mtt/server:server-start-session s "s5" "43-27" "sub")))
           (multiple-value-bind (status name) (%status-name (%step s sid 4))
             (is (eq :off-path-buggy status))
             (is (string= "BUGGY-BORROW-IGNORE" name)))
           ;; off-path does not advance the state: the SAME column is retried
           ;; and a correct digit now goes on-path
           (multiple-value-bind (status name) (%status-name (%step s sid 6))
             (is (eq :on-path status))
             (is (string= "SUBTRACT-ONES-BORROW" name))))
      (mtt/server:stop-tutor-server s))))

(test subtraction-adapter.buggy-always-borrow
  "46-23 (ones 6-3, NO borrow needed): student reports 13 (16-3) ->
off-path-buggy BUGGY-ALWAYS-BORROW."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (mtt/server:server-start-session s "s6" "46-23" "sub")))
           (multiple-value-bind (status name) (%status-name (%step s sid 13))
             (is (eq :off-path-buggy status))
             (is (string= "BUGGY-ALWAYS-BORROW" name))))
      (mtt/server:stop-tutor-server s))))

(test subtraction-adapter.buggy-off-by-one
  "43-27 (correct ones 6): student reports 5 (6-1) -> off-path-buggy
BUGGY-OFF-BY-ONE (attributed :column-subtract — the borrow was set up, the
subtraction fact slipped)."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (mtt/server:server-start-session s "s7" "43-27" "sub")))
           (multiple-value-bind (status name) (%status-name (%step s sid 5))
             (is (eq :off-path-buggy status))
             (is (string= "BUGGY-OFF-BY-ONE" name)))
           (let ((m (progn (mtt/server:server-end-session s sid)
                           (mtt/server:server-student-mastery s "s7"))))
             (is (eq :column-subtract (getf (%entry m :column-subtract) :kc)))))
      (mtt/server:stop-tutor-server s))))

(test subtraction-adapter.unclassified-off-path
  "43-27: student reports 9 (matches no bug formula) -> :off-path."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (mtt/server:server-start-session s "s8" "43-27" "sub")))
           (is (eq :off-path (mtt:trace-result-status (%step s sid 9)))))
      (mtt/server:stop-tutor-server s))))

(test subtraction-adapter.degenerate-mirror-equals-correct
  "52-17 is the degenerate case (bot_ones - top_ones = 5): the borrow-ignore
mirror (7-2=5) EQUALS the correct ones digit (12-7=5), so the digit routes
on-path at ones (spec §2.1) — such a student's error only shows at tens (the
un-decremented 4 instead of 3, unclassified there). Documents why b-t=5
problems stay out of the bug-path corpus."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (mtt/server:server-start-session s "s9" "52-17" "sub")))
           (multiple-value-bind (status name) (%status-name (%step s sid 5))
             (is (eq :on-path status))
             (is (string= "SUBTRACT-ONES-BORROW" name)))
           (is (eq :off-path (mtt:trace-result-status (%step s sid 4)))))
      (mtt/server:stop-tutor-server s))))

;;; --- Phase 11 Task 3: full-problem e2e over real HTTP -------------------
;;; Mirrors fraction.e2e-full-problem: drive a complete 52-18 borrow problem
;;; (start -> digit 4 -> digit 3 -> GET /student/mastery -> end) over real
;;; HTTP. Asserts 200s, on-path traces with the visible lowercase wire
;;; production symbols, done=false after the borrow column and true after the
;;; tens column, and mastery returning 2 KCs (BORROW + COLUMN-SUBTRACT —
;;; kc->json is princ-to-string, keyword names print WITHOUT the colon,
;;; verified 2026-08-16). %find-free-port is defined locally here (mirrors
;;; test-fraction-adapter.lisp); usocket is a transitive dep via hunchentoot.

(defun %find-free-port ()
  (let ((sock (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (unwind-protect (usocket:get-local-port sock)
      (usocket:socket-close sock))))

(test subtraction.e2e-full-problem
  "Full 52-18 borrow problem over real HTTP: start -> digit 4 -> digit 3 ->
GET /student/mastery -> end. Asserts 200s, on-path, the visible productions,
done=false then true, and both KCs in mastery (array-of-objects wire shape)."
  (let* ((port (%find-free-port))
         (s (mtt/server:start-tutor-server :port port :start-acceptor-p t)))
    (unwind-protect
         (progn
           (mtt/server:register-model s "sub"
                                      (mtt/subtraction-adapter:build-subtraction-model)
                                      (mtt/subtraction-adapter:make-subtraction-adapter))
           (sleep 0.3)
           (labels ((post (path json)
                      (multiple-value-bind (body status)
                          (dex:post (format nil "http://127.0.0.1:~a~a" port path)
                                    :content json)
                        (values (yason:parse body :object-as :alist) status))))
             (let ((sid (cdr (assoc "session_id"
                                    (post "/session/start"
                                          "{\"student_id\":\"suo\",\"problem_id\":\"52-18\",\"model_id\":\"sub\"}")
                                    :test #'string=))))
               ;; ones 4 -> subtract-ones-borrow (on-path, NOT done)
               (multiple-value-bind (resp status)
                   (post "/session/step"
                         (format nil "{\"session_id\":\"~a\",\"action\":{\"type\":\"digit\",\"value\":\"4\"}}" sid))
                 (is (= 200 status))
                 (is (string= "on-path" (cdr (assoc "status" resp :test #'string=))))
                 (is (string= "subtract-ones-borrow"
                              (cdr (assoc "production" resp :test #'string=))))
                 (is (null (cdr (assoc "done" resp :test #'string=)))))
               ;; tens 3 -> subtract-tens-direct (on-path, done)
               (multiple-value-bind (resp status)
                   (post "/session/step"
                         (format nil "{\"session_id\":\"~a\",\"action\":{\"type\":\"digit\",\"value\":\"3\"}}" sid))
                 (is (= 200 status))
                 (is (string= "on-path" (cdr (assoc "status" resp :test #'string=))))
                 (is (string= "subtract-tens-direct"
                              (cdr (assoc "production" resp :test #'string=))))
                 (is (eq t (cdr (assoc "done" resp :test #'string=)))))
               ;; mastery: both KCs, entries as objects (Phase 9 recursive encode)
               (multiple-value-bind (body status)
                   (dex:get (format nil "http://127.0.0.1:~a/student/mastery?student_id=suo"
                                    port))
                 (is (= 200 status))
                 (let ((kcs (mapcar (lambda (entry)
                                      (cdr (assoc "kc" entry :test #'string=)))
                                    (cdr (assoc "kc" (yason:parse body :object-as :alist)
                                                :test #'string=)))))
                   (is (= 2 (length kcs)))
                   (is (find "BORROW" kcs :test #'string=))
                   (is (find "COLUMN-SUBTRACT" kcs :test #'string=))))
               ;; end
               (multiple-value-bind (body status)
                   (post "/session/end" (format nil "{\"session_id\":\"~a\"}" sid))
                 (declare (ignore body))
                 (is (= 200 status))))))
      (mtt/server:stop-tutor-server s))))

;;; --- Phase 12 Task 5: semantic problem validation + malformed-action 400 -----

(test subtraction.bad-problem-and-action-are-400
  "\"5-18\" (top < bot, negative result) is a semantic violation (so is
\"52-52\", non-positive result); a non-integer action value is malformed; a
digit action after DONE is graceful — all bad-tutor-request programmatically
and 400 over the handler (phase 12 debt #1/#2)."
  (let ((s (%server)))
    (unwind-protect
         (progn
           (signals mtt:bad-tutor-request
             (mtt/server:server-start-session s "sx" "5-18" "sub"))
           (signals mtt:bad-tutor-request
             (mtt/server:server-start-session s "sx2" "52-52" "sub"))
           (multiple-value-bind (r status)
               (mtt/server::handle-start s `(("student_id" . "sx")
                                             ("problem_id" . "5-18")
                                             ("model_id" . "sub")))
             (is (= 400 status))
             (is (search "positive answer" (getf r :error))))
           (let ((sid (mtt/server:server-start-session s "sy" "52-18" "sub")))
             (signals mtt:bad-tutor-request
               (mtt/server:server-step-session
                s sid '(("type" . "digit") ("value" . "x"))))
             (signals mtt:bad-tutor-request
               (mtt/server:server-step-session
                s sid '(("type" . "what") ("value" . "4"))))
             ;; graceful after DONE: full problem then one more digit
             (%step s sid 4)
             (%step s sid 3)
             (signals mtt:bad-tutor-request (%step s sid 9))))
      (mtt/server:stop-tutor-server s))))
