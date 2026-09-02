;;;; tests/test-fraction-adapter.lisp — fraction adapter tests (Phase 7).
;;;; Suite :libactr/server (defined in tests/test-server.lisp). Unit tests here drive
;;;; the programmatic tutor-server API; the over-HTTP e2e is added in Task 4.
(defpackage :libactr/fraction-adapter-test
  (:use :cl :5am))
(in-package :libactr/fraction-adapter-test)
(in-suite :libactr/server)

(defun %server ()
  "tutor-server with fraction model+adapter registered under \"frac\". No acceptor."
  (let ((s (libactr/server:start-tutor-server :port 0 :start-acceptor-p nil)))
    (libactr/server:register-model s "frac"
                               (libactr/fraction-adapter:build-fraction-model)
                               (libactr/fraction-adapter:make-fraction-adapter))
    s))

(defun %step (s sid action)
  "Step and return the trace-result (first value)."
  (nth-value 0 (libactr/server:server-step-session s sid action)))

(test fraction-adapter.on-path-full-problem
  "1/2 + 1/3: common-denom 6 (on-path) -> sum 5/6 (on-path, done).
Phase 13: done assertions pass the REAL session (the conditional step-done?
override reads the goal's snum/sdenom); 5/6 has gcd 1, so semantics are
unchanged from the old default-termination behavior."
  (let ((s (%server)))
    (unwind-protect
         (let* ((sid (libactr/server:server-start-session s "f" "1/2+1/3" "frac"))
                (adapter (libactr/fraction-adapter:make-fraction-adapter))
                (session (libactr/server:handle-session
                          (gethash sid (libactr/server:server-sessions s)))))
           ;; common-denom 6 -> find-common-denominator on-path
           (let ((r1 (%step s sid '(("type" . "common-denom") ("value" . "6")))))
             (is (eq :on-path (libactr:trace-result-status r1)))
             (is (string= "FIND-COMMON-DENOMINATOR"
                          (symbol-name (libactr:production-name
                                        (libactr:trace-result-production r1)))))
             (is (null (libactr:step-done? adapter r1 session))))
           ;; sum 5/6 -> add-fractions on-path, done
           (let ((r2 (%step s sid '(("type" . "sum") ("num" . "5") ("denom" . "6")))))
             (is (eq :on-path (libactr:trace-result-status r2)))
             (is (string= "ADD-FRACTIONS"
                          (symbol-name (libactr:production-name
                                        (libactr:trace-result-production r2)))))
             (is (libactr:step-done? adapter r2 session))))
      (libactr/server:stop-tutor-server s))))

(test fraction-adapter.buggy-add-across
  "1/2 + 1/3: correct cdenom 6, then student sums 2/5 (add-across) -> off-path-buggy
with buggy-add-across, feedback present."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (libactr/server:server-start-session s "f" "1/2+1/3" "frac")))
           (%step s sid '(("type" . "common-denom") ("value" . "6")))
           (let ((r (%step s sid '(("type" . "sum") ("num" . "2") ("denom" . "5")))))
             (is (eq :off-path-buggy (libactr:trace-result-status r)))
             (is (string= "BUGGY-ADD-ACROSS"
                          (symbol-name (libactr:production-name
                                        (libactr:trace-result-production r)))))
             (is (stringp (libactr:trace-result-feedback r)))))
      (libactr/server:stop-tutor-server s))))

(test fraction-adapter.buggy-use-product
  "1/4 + 1/6: LCM=12, product=24. Student reports 24 -> off-path-buggy use-product."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (libactr/server:server-start-session s "f" "1/4+1/6" "frac")))
           (let ((r (%step s sid '(("type" . "common-denom") ("value" . "24")))))
             (is (eq :off-path-buggy (libactr:trace-result-status r)))
             (is (string= "BUGGY-USE-PRODUCT"
                          (symbol-name (libactr:production-name
                                        (libactr:trace-result-production r)))))))
      (libactr/server:stop-tutor-server s))))

(test fraction-adapter.unclassified-off-path
  "1/2 + 1/3: student reports a wrong cdenom matching NO bug (e.g. 7) -> :off-path."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (libactr/server:server-start-session s "f" "1/2+1/3" "frac")))
           (let ((r (%step s sid '(("type" . "common-denom") ("value" . "7")))))
             (is (eq :off-path (libactr:trace-result-status r)))))
      (libactr/server:stop-tutor-server s))))

;;; --- Phase 7 Task 3 deferred minor: dedicated bug-branch coverage -------------------
;;; The Task 3 review noted that 2 of the 4 bug branches (keep-left-denom,
;;; no-convert) had no dedicated test — a keyword typo there would silently break
;;; matching with no signal. These two tests close that gap, mirroring
;;; buggy-add-across (using the file's existing %server and %step helpers).
;;; For 1/2+1/3 with cdenom 6: num1=1, den1=2, num2=1, den2=3.
;;;   keep-left-denom: ssnum=num1+num2=2, ssdenom=den1=2 -> student reports 2/2.
;;;   no-convert:       ssnum=num1+num2=2, ssdenom=cdenom=6 -> student reports 2/6.

(test fraction-adapter.buggy-keep-left-denom
  "1/2 + 1/3: cdenom 6, then sum 2/2 (keep-left-denom) -> off-path-buggy buggy-keep-left-denom."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (libactr/server:server-start-session s "f" "1/2+1/3" "frac")))
           (%step s sid '(("type" . "common-denom") ("value" . "6")))
           (let ((r (%step s sid '(("type" . "sum") ("num" . "2") ("denom" . "2")))))
             (is (eq :off-path-buggy (libactr:trace-result-status r)))
             (is (string= "BUGGY-KEEP-LEFT-DENOM"
                          (symbol-name (libactr:production-name (libactr:trace-result-production r)))))))
      (libactr/server:stop-tutor-server s))))

(test fraction-adapter.buggy-no-convert
  "1/2 + 1/3: cdenom 6, then sum 2/6 (no-convert) -> off-path-buggy buggy-no-convert."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (libactr/server:server-start-session s "f" "1/2+1/3" "frac")))
           (%step s sid '(("type" . "common-denom") ("value" . "6")))
           (let ((r (%step s sid '(("type" . "sum") ("num" . "2") ("denom" . "6")))))
             (is (eq :off-path-buggy (libactr:trace-result-status r)))
             (is (string= "BUGGY-NO-CONVERT"
                          (symbol-name (libactr:production-name (libactr:trace-result-production r)))))))
      (libactr/server:stop-tutor-server s))))

;;; --- Phase 7 Task 4: full-problem e2e over real HTTP -------------------
;;;
;;; Mirrors addition.e2e-full-problem in tests/test-server.lisp: drive a complete
;;; 1/2+1/3 problem (start -> common-denom 6 -> sum 5/6 -> GET /student/mastery ->
;;; end) over real HTTP (Hunchentoot acceptor + dexador client). Asserts 200s on
;;; every call, on-path traces with the visible productions
;;; (find-common-denominator / add-fractions), done=true after the sum, and that
;;; /student/mastery returns 2 KCs (COMMON-DENOMINATOR + ADD-FRACTIONS) — proving
;;; the per-session event log is being aggregated into the shared student log
;;; under the fraction domain's KC tagging. %find-free-port is defined locally
;;; here (the file's existing %server uses :start-acceptor-p nil; this e2e needs a
;;; live acceptor on an ephemeral port); usocket is a transitive dep via
;;; hunchentoot, so no new asd dependency.

(defun %find-free-port ()
  (let ((sock (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (unwind-protect (usocket:get-local-port sock)
      (usocket:socket-close sock))))

(test fraction.e2e-full-problem
  "Full 1/2+1/3 problem over real HTTP: start -> common-denom 6 -> sum 5/6 ->
GET /student/mastery -> end. Asserts 200s, on-path, the visible productions,
and that mastery returns kc-tagged data (:common-denominator + :add-fractions)."
  (let* ((port (%find-free-port))
         (s (libactr/server:start-tutor-server :port port :start-acceptor-p t)))
    (unwind-protect
         (progn
           (libactr/server:register-model s "frac"
                                      (libactr/fraction-adapter:build-fraction-model)
                                      (libactr/fraction-adapter:make-fraction-adapter))
           (sleep 0.3)
           (labels ((post (path json)
                      (multiple-value-bind (body status)
                          (dex:post (format nil "http://127.0.0.1:~a~a" port path) :content json)
                        (values (yason:parse body :object-as :alist) status)))
                    (jstep (sid action)
                      (post "/session/step"
                            (format nil "{\"session_id\":\"~a\",\"action\":~a}" sid action))))
             (let ((sid (cdr (assoc "session_id"
                                    (post "/session/start"
                                          "{\"student_id\":\"flo\",\"problem_id\":\"1/2+1/3\",\"model_id\":\"frac\"}")
                                    :test #'string=))))
               ;; common-denom 6 -> find-common-denominator (on-path)
               (multiple-value-bind (resp status)
                   (jstep sid "{\"type\":\"common-denom\",\"value\":\"6\"}")
                 (is (= 200 status))
                 (is (string= "on-path" (cdr (assoc "status" resp :test #'string=))))
                 (is (string= "find-common-denominator"
                              (cdr (assoc "production" resp :test #'string=)))))
               ;; sum 5/6 -> add-fractions (on-path), done
               (multiple-value-bind (resp status)
                   (jstep sid "{\"type\":\"sum\",\"num\":\"5\",\"denom\":\"6\"}")
                 (is (= 200 status))
                 (is (string= "on-path" (cdr (assoc "status" resp :test #'string=))))
                 (is (string= "add-fractions"
                              (cdr (assoc "production" resp :test #'string=))))
                 (is (eq t (cdr (assoc "done" resp :test #'string=)))))
               ;; mastery: 2 KCs present. The mastery endpoint encodes per-KC
               ;; entries as JSON OBJECTS (Phase 9 recursive json-encode:
               ;; plists -> objects, list-of-plists -> array-of-objects), so
               ;; each parsed entry is an alist (("kc" . <NAME>) ("correct" . N)
               ;; ...) and the KC name is behind the "kc" alist cons.
               (multiple-value-bind (body status)
                   (dex:get (format nil "http://127.0.0.1:~a/student/mastery?student_id=flo" port))
                 (is (= 200 status))
                 (let ((kcs (mapcar (lambda (entry)
                                      (cdr (assoc "kc" entry :test #'string=)))
                                    (cdr (assoc "kc" (yason:parse body :object-as :alist)
                                                :test #'string=)))))
                   (is (= 2 (length kcs)))
                   (is (find "COMMON-DENOMINATOR" kcs :test #'string=))
                   (is (find "ADD-FRACTIONS" kcs :test #'string=))))
               ;; end
               (multiple-value-bind (body status)
                   (post "/session/end" (format nil "{\"session_id\":\"~a\"}" sid))
                 (declare (ignore body))
                 (is (= 200 status))))))
      (libactr/server:stop-tutor-server s))))

;;; --- Phase 12 Task 5: semantic problem validation + malformed-action 400 -----

(test fraction.bad-problem-and-action-are-400
  "\"1/0+2/3\" (zero denominator) previously crashed %lcm with a
division-by-zero 500; a non-integer num is malformed — both now
bad-tutor-request / 400 (phase 12 debt #1/#2)."
  (let ((s (%server)))
    (unwind-protect
         (progn
           (signals libactr:bad-tutor-request
             (libactr/server:server-start-session s "fx" "1/0+2/3" "frac"))
           (multiple-value-bind (r status)
               (libactr/server::handle-start s `(("student_id" . "fx")
                                             ("problem_id" . "1/0+2/3")
                                             ("model_id" . "frac")))
             (is (= 400 status))
             (is (search "denominators must be positive" (getf r :error))))
           (let ((sid (libactr/server:server-start-session s "fy" "1/2+1/3" "frac")))
             (%step s sid '(("type" . "common-denom") ("value" . "6")))
             (signals libactr:bad-tutor-request
               (libactr/server:server-step-session
                s sid '(("type" . "sum") ("num" . "x") ("denom" . "5"))))))
      (libactr/server:stop-tutor-server s))))

;;; --- Phase 13 Task 5: simplify action branch + conditional step-done? ---------
;;;
;;; The fraction problem now runs 3 steps when the summed fraction is
;;; simplifiable (cdenom -> sum -> simplify) and 2 steps when it is already in
;;; lowest terms. Termination is CONDITIONAL: SIMPLIFY on-path always ends the
;;; problem; ADD-FRACTIONS on-path ends it ONLY when gcd(snum,sdenom)=1 — the
;;; terminal-name list alone cannot express this (ANY-match would end
;;; simplifiable problems one step early), hence the local step-done? override.

(test fraction-adapter.simplify-full-problem
  "1/6 + 1/6: cdenom 6 -> sum 2/6 -> simplify 1/3 (SIMPLIFY on-path, done).
The sum step is NOT done (gcd 2 > 1) — the conditional step-done? override."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (libactr/server:server-start-session s "f" "1/6+1/6" "frac")))
           (%step s sid '(("type" . "common-denom") ("value" . "6")))
           (let* ((adapter (libactr/fraction-adapter:make-fraction-adapter))
                  (r2 (%step s sid '(("type" . "sum") ("num" . "2") ("denom" . "6"))))
                  (session (libactr/server:handle-session
                            (gethash sid (libactr/server:server-sessions s)))))
             (is (eq :on-path (libactr:trace-result-status r2)))
             (is (null (libactr:step-done? adapter r2 session)))   ; gcd(2,6)=2 -> not done
             (let ((r3 (%step s sid '(("type" . "simplify") ("num" . "1") ("denom" . "3")))))
               (is (eq :on-path (libactr:trace-result-status r3)))
               (is (string= "SIMPLIFY"
                            (symbol-name (libactr:production-name
                                          (libactr:trace-result-production r3)))))
               (is (libactr:step-done? adapter r3 session)))))
      (libactr/server:stop-tutor-server s))))

(test fraction-adapter.unsimplifiable-sum-still-done
  "1/2 + 1/3 = 5/6 (gcd 1): the sum step terminates the problem exactly as
before the simplify increment (ADD-FRACTIONS on-path -> done)."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (libactr/server:server-start-session s "f" "1/2+1/3" "frac")))
           (%step s sid '(("type" . "common-denom") ("value" . "6")))
           (let* ((adapter (libactr/fraction-adapter:make-fraction-adapter))
                  (r2 (%step s sid '(("type" . "sum") ("num" . "5") ("denom" . "6"))))
                  (session (libactr/server:handle-session
                            (gethash sid (libactr/server:server-sessions s)))))
             (is (eq :on-path (libactr:trace-result-status r2)))
             (is (libactr:step-done? adapter r2 session))))          ; gcd(5,6)=1
      (libactr/server:stop-tutor-server s))))

(test fraction-adapter.simplify-on-lowest-terms-rejected
  "A simplify attempt on an already-lowest-terms sum signals bad-tutor-request
(the step does not exist for this problem)."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (libactr/server:server-start-session s "f" "1/2+1/3" "frac")))
           (%step s sid '(("type" . "common-denom") ("value" . "6")))
           (%step s sid '(("type" . "sum") ("num" . "5") ("denom" . "6")))
           (signals libactr:bad-tutor-request
             (%step s sid '(("type" . "simplify") ("num" . "5") ("denom" . "6")))))
      (libactr/server:stop-tutor-server s))))

(test fraction-adapter.wrong-reduction-unclassified
  "Task-5 review pin: a WRONG reduction at a simplifiable sum (1/6+1/6 = 2/6,
student 'simplifies' to 2/3 — not the correct 1/3) gets a BARE intent (no
reduce-fact prime), so SIMPLIFY cannot match -> :off-path unclassified."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (libactr/server:server-start-session s "f" "1/6+1/6" "frac")))
           (%step s sid '(("type" . "common-denom") ("value" . "6")))
           (%step s sid '(("type" . "sum") ("num" . "2") ("denom" . "6")))
           (let ((r (%step s sid '(("type" . "simplify") ("num" . "2") ("denom" . "3")))))
             (is (eq :off-path (libactr:trace-result-status r)))
             (is (null (libactr:trace-result-feedback r)))))
      (libactr/server:stop-tutor-server s))))

;;; --- Phase 14 Task 12: B1 out-of-order actions are bad requests (500 -> 400) --

(test fraction-adapter.out-of-order-sum-and-simplify-are-bad-requests
  "B1: \"sum\" before common-denom (cdenom nil) and \"simplify\" before sum
(snum nil) signal bad-tutor-request (400 over HTTP) — they used to reach
TYPE-ERROR 500s at (/ cdenom den1) / (%gcd nil nil)."
  (let ((s (%server)))
    (unwind-protect
         (let ((sid (libactr/server:server-start-session s "oo" "1/2+1/3" "frac")))
           (signals libactr:bad-tutor-request
             (libactr/server:server-step-session
              s sid '(("type" . "sum") ("num" . "5") ("denom" . "6"))))
           (signals libactr:bad-tutor-request
             (libactr/server:server-step-session
              s sid '(("type" . "simplify") ("num" . "1") ("denom" . "1"))))
           ;; http-level mapping for one leg
           (multiple-value-bind (plist status)
               (libactr/server::handle-step
                s `(("session_id" . ,sid)
                    ("action" . (("type" . "sum") ("num" . "5") ("denom" . "6")))))
             (declare (ignore plist))
             (is (= 400 status))))
      (libactr/server:stop-tutor-server s))))
