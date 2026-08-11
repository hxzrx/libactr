;;;; tests/test-server.lisp — mtt/server runtime tests (Phase 5, Task 3).
;;;; Own FiveAM suite :mtt/server (does NOT join :mtt). Tests the tutor-server
;;;; container, model registry, per-session lock, and the programmatic ops using
;;;; a STUB domain-adapter (the real addition-adapter lands in Task 5).
(in-package :cl-user)

(defpackage :mtt/server-test
  (:use :cl :5am :mtt)
  (:import-from #:mtt/server
                #:tutor-server #:start-tutor-server #:stop-tutor-server
                #:register-model
                #:server-start-session #:server-step-session
                #:server-end-session #:server-student-mastery
                #:server-health)
  (:import-from #:mtt/server #:session-handle #:handle-session #:handle-lock #:handle-adapter)
  (:import-from #:mtt/server #:server-models #:server-sessions #:server-students)
  ;; session-status is exported from :mtt; re-imported for clarity.
  (:import-from #:mtt #:session-status))

(in-package :mtt/server-test)

(def-suite :mtt/server :description "mtt service layer")
(in-suite :mtt/server)

;;; --- local model loader (mirrors tests/test-tracer.lisp) ---------------------
;;; We avoid depending on :mtt/test (which would pull in the entire :mtt test
;;; suite). The model file lives in the act-r/ system (registered in the source
;;; registry); asdf:system-relative-pathname resolves the path without loading
;;; act-r's code.

(defun %addition-compiled-model ()
  "Read+compile tutorial addition.lisp once. Same loader used in tests/test-tracer."
  (compile-model (read-model-file
                  (asdf:system-relative-pathname "act-r" "tutorial/unit1/addition.lisp"))))

;;; --- STUB domain adapter -----------------------------------------------------
;;; Plain CLOS (deviation 2: no closer-mop, no alexandria). For ANY action,
;;; returns the hardcoded on-path intent that drives initialize-addition in the
;;; compiled addition model (matches the proven-on-path intent from
;;; tests/test-concurrent.lisp).

(defclass stub-adapter (mtt:domain-adapter) ()
  (:documentation "Test stub: every action maps to the initialize-addition intent."))

(defmethod mtt:prepare-session ((a stub-adapter) session problem-id)
  (declare (ignore a problem-id))
  session)

(defmethod mtt:adapt-action ((a stub-adapter) action session)
  (declare (ignore a action session))
  ;; Hardcoded on-path intent for the addition model (initialize-addition fires).
  (mtt:make-step-intent :assignments '((goal sum five) (goal count zero))))

(defmethod mtt:step-done? ((a stub-adapter) trace-result session)
  (declare (ignore a session))
  (eq :on-path (mtt:trace-result-status trace-result)))

(defun %stub-model+adapter ()
  "Return (values compiled-model adapter)."
  (values (%addition-compiled-model) (make-instance 'stub-adapter)))

;;; --- tests -------------------------------------------------------------------

(test tutor-server.start-stop-and-model-registry
  "A tutor-server with :start-acceptor-p nil has no acceptor slot set; register-model
stores the (model . adapter) pair in the models registry."
  (let ((server (start-tutor-server :port 0 :start-acceptor-p nil)))
    (unwind-protect
         (progn
           (is (typep server 'tutor-server))
           (is (null (mtt/server::server-acceptor server)))   ; no acceptor started
           (multiple-value-bind (md adapter) (%stub-model+adapter)
             (is (eq server (register-model server "add" md adapter)))
             (is (not (null (gethash "add" (server-models server)))))
             (is (eq md (car (gethash "add" (server-models server)))))
             (is (eq adapter (cdr (gethash "add" (server-models server)))))))
      (stop-tutor-server server))))

(test server-session-lifecycle-and-mastery
  "End-to-end programmatic lifecycle: start a session, step it (the stub maps any
action to an on-path intent), check mastery aggregates, end the session."
  (let ((server (start-tutor-server :port 0 :start-acceptor-p nil)))
    (unwind-protect
         (progn
           (multiple-value-bind (md adapter) (%stub-model+adapter)
             (register-model server "add" md adapter))
           ;; start returns a string session-id; the handle is registered.
           (let ((sid (server-start-session server "alice" "5+2" "add")))
             (is (stringp sid))
             (is (not (null (gethash sid (server-sessions server)))))
             (let ((handle (gethash sid (server-sessions server))))
               (is (typep handle 'session-handle))
               (is (bt:lock-p (handle-lock handle)))            ; bordeaux lock present
               (is (typep (handle-adapter handle) 'stub-adapter)))
             ;; step: stub maps ((type . start)) to the on-path initialize intent.
             (multiple-value-bind (result adapter-found session)
                 (server-step-session server sid '((type . start)))
               (is (not (null result)))
               (is (eq :on-path (mtt:trace-result-status result)))
               (is (typep adapter-found 'stub-adapter))
               (is (eq :active (mtt:session-status session)))
               (is (eq session (handle-session (gethash sid (server-sessions server))))))
             ;; mastery aggregates from the shared student log.
             (let ((m (server-student-mastery server "alice")))
               (is (listp m))
               ;; one on-path step against initialize-addition produces one kc-event.
               (is (= 1 (length m))))
             ;; end: summary plist has :status :ended.
             (let ((summary (server-end-session server sid)))
               (is (eql :ended (getf summary :status))))
             ;; handle removed after end.
             (is (null (gethash sid (server-sessions server))))))
      (stop-tutor-server server))))

(test server-step-session.sentinals
  "server-step-session returns (values nil :not-found) for unknown session-id and
(values nil :conflict) when the session has been ended."
  (let ((server (start-tutor-server :port 0 :start-acceptor-p nil)))
    (unwind-protect
         (progn
           (multiple-value-bind (md adapter) (%stub-model+adapter)
             (register-model server "add" md adapter))
           ;; unknown session -> :not-found
           (multiple-value-bind (result sentinel)
               (server-step-session server "nope" '((type . start)))
             (is (null result))
             (is (eq :not-found sentinel)))
           ;; end-then-step -> :conflict
           (let ((sid (server-start-session server "alice" "5+2" "add")))
             (server-end-session server sid)
             ;; The handle was remhash'd on end, so a step now is :not-found
             ;; (the conflict path requires the handle to remain registered but
             ;; the underlying cognitive-session to be :ended; that is exercised
             ;; below with a direct manipulation of the registry).
             (multiple-value-bind (result sentinel)
                 (server-step-session server sid '((type . start)))
               (is (null result))
               (is (eq :not-found sentinel)))
             ;; Force the :conflict path: re-insert the handle pointing at the
             ;; ended cognitive-session.
             (let* ((ended-session
                      (mtt:start-session (%addition-compiled-model) "alice" "5+2"
                                         :session-id "ended-1"))
                    (adapter (cdr (gethash "add" (server-models server)))))
               (mtt:end-session ended-session)
               (setf (gethash "conflict-1" (server-sessions server))
                     (make-instance 'session-handle
                                    :session ended-session
                                    :lock (bt:make-lock "test-conflict")
                                    :adapter adapter))
               (multiple-value-bind (result sentinel)
                   (server-step-session server "conflict-1" '((type . start)))
                 (is (null result))
                 (is (eq :conflict sentinel))))))
      (stop-tutor-server server))))

(test server-student-mastery.not-found
  "server-student-mastery on an unknown student returns (values nil :not-found)."
  (let ((server (start-tutor-server :port 0 :start-acceptor-p nil)))
    (unwind-protect
         (multiple-value-bind (result sentinel)
             (server-student-mastery server "nobody")
           (is (null result))
           (is (eq :not-found sentinel)))
      (stop-tutor-server server))))

(test server-end-session.not-found
  "server-end-session on an unknown session returns (values nil :not-found)."
  (let ((server (start-tutor-server :port 0 :start-acceptor-p nil)))
    (unwind-protect
         (multiple-value-bind (result sentinel)
             (server-end-session server "nope")
           (is (null result))
           (is (eq :not-found sentinel)))
      (stop-tutor-server server))))

(test server-health-shapes
  "server-health returns a plist with :status \"ok\" and counter keys."
  (let ((server (start-tutor-server :port 0 :start-acceptor-p nil)))
    (unwind-protect
         (progn
           (multiple-value-bind (md adapter) (%stub-model+adapter)
             (register-model server "add" md adapter))
           (server-start-session server "alice" "5+2" "add")
           (let ((h (server-health server)))
             (is (equal "ok" (getf h :status)))
             (is (eql 1 (getf h :active_sessions)))
             (is (eql 1 (getf h :students)))))
      (stop-tutor-server server))))

(test server-shared-student-log-across-sessions
  "Two sessions under the same student share ONE student-session (and thus one
event log) in the students registry."
  (let ((server (start-tutor-server :port 0 :start-acceptor-p nil)))
    (unwind-protect
         (progn
           (multiple-value-bind (md adapter) (%stub-model+adapter)
             (register-model server "add" md adapter))
           (let ((sid1 (server-start-session server "alice" "5+2" "add"))
                 (sid2 (server-start-session server "alice" "3+1" "add")))
             (is (not (equal sid1 sid2)))
             ;; one student-session for both sessions
             (is (= 1 (hash-table-count (server-students server))))
             ;; both sessions registered
             (is (= 2 (hash-table-count (server-sessions server))))
             ;; stepping both contributes 2 events on the shared student log
             (server-step-session server sid1 '((type . start)))
             (server-step-session server sid2 '((type . start)))
             (let ((ss (gethash "alice" (server-students server))))
               (is (= 2 (mtt:log-last-seq (mtt:student-session-log ss)))))))
      (stop-tutor-server server))))

;;; --- concurrency tests (cover reviewer findings 1, 2, 3) ---------------------
;;;
;;; These tests demonstrate the three concurrency fixes structurally:
;;;   * ensure-student serializes on students-lock  -> exactly one student-session
;;;     is created when N threads race on the same NEW student-id (no orphaned
;;;     event log).
;;;   * server-step-session holds the per-session lock across adapt-action +
;;;     step-session -> priming side-effects never interleave.
;;;   * server-step-session re-checks :ended INSIDE the lock -> if a concurrent
;;;     server-end-session wins the race, the stepper observes :conflict (or
;;;     :not-found once the handle is remhash'd) rather than stepping an ended
;;;     session. The outside-lock fast path remains as a cheap rejection.

(test ensure-student.concurrent-same-new-student-id
  "N threads concurrently call server-start-session on the SAME brand-new
student-id. Without the students-lock, two callers would each miss the registry
and create a student-session; the second setf would orphan the first (spliting
mastery). With the lock, exactly ONE student-session exists afterward, and all
N session-ids are distinct and registered."
  (let ((server (start-tutor-server :port 0 :start-acceptor-p nil))
        (n 16))
    (unwind-protect
         (progn
           (multiple-value-bind (md adapter) (%stub-model+adapter)
             (register-model server "add" md adapter))
           (let ((threads
                   (loop repeat n collect
                         (bt:make-thread
                          (lambda ()
                            (server-start-session server "racer" "1+1" "add"))))))
             (let ((sids (mapcar #'bt:join-thread threads)))
               ;; all session-ids are distinct strings
               (is (= n (length sids)))
               (is (every #'stringp sids))
               (is (= n (length (remove-duplicates sids :test #'string=))))
               ;; exactly ONE student-session was created
               (is (= 1 (hash-table-count (server-students server))))
               ;; all N session-handles are registered
               (is (= n (hash-table-count (server-sessions server))))
               ;; the single student-session's log is shared by all N sessions
               (let ((ss (gethash "racer" (server-students server))))
                 (is (not (null ss)))
                 (is (= n (length (mtt:student-session-sessions ss))))))))
      (stop-tutor-server server))))

(test server-step-session.concurrent-step-vs-end-race
  "N stepper threads and 1 ender thread race against one session. Every stepper
must return either (values trace-result adapter session) on success or one of
the sentinels (values nil :conflict) / (values nil :not-found); no stepper ever
observes a torn write or steps an :ended cognitive-session. The ender either
returns the summary plist (:status :ended) or (values nil :not-found) if a
stepper beat it (not currently possible — steppers don't end the session — but
the assertion covers the contract)."
  (let ((server (start-tutor-server :port 0 :start-acceptor-p nil))
        (n 16))
    (unwind-protect
         (progn
           (multiple-value-bind (md adapter) (%stub-model+adapter)
             (register-model server "add" md adapter))
           (let ((sid (server-start-session server "racer" "1+1" "add")))
             ;; spawn N steppers + 1 ender; join all; collect steppers' results
             (let ((steppers
                     (loop repeat n collect
                           (bt:make-thread
                            (lambda ()
                              (multiple-value-list
                               (server-step-session server sid '((type . start))))))))
                   (ender (bt:make-thread
                           (lambda ()
                             (multiple-value-list
                              (server-end-session server sid))))))
               (let ((step-results (mapcar #'bt:join-thread steppers))
                     (end-result (bt:join-thread ender)))
                 ;; every stepper result is one of: success (non-nil first value)
                 ;; or :conflict or :not-found
                 (dolist (r step-results)
                   (let ((result (first r))
                         (sentinel (second r)))
                     (is (or (and (not (null result))
                                  (mtt:trace-result-p result))
                             (eq :conflict sentinel)
                             (eq :not-found sentinel))
                         (format nil "unexpected stepper result: ~a" r))))
                 ;; at least one stepper succeeded (the session was :active when
                 ;; the race began, and the ender cannot win until at least one
                 ;; stepper has finished queueing on the lock).
                 (is (some (lambda (r) (mtt:trace-result-p (first r))) step-results))
                 ;; ender either succeeded (summary plist with :ended) or got
                 ;; :not-found (impossible today, but contract-checked).
                 (let ((summary (first end-result))
                       (sentinel (second end-result)))
                   (is (or (and (listp summary) (eql :ended (getf summary :status)))
                           (eq :not-found sentinel))))
                 ;; invariant: the cognitive-session's status is :ended once the
                 ;; ender has run (whoever won the race, the session is now ended
                 ;; OR fully remhash'd). The handle is gone from the registry.
                 (is (null (gethash sid (server-sessions server))))))))
      (stop-tutor-server server))))


;;; --- Phase 5 Task 4: HTTP handler-logic tests -------------------------------
;;;
;;; These tests exercise the PURE handler-logic functions (handle-start,
;;; handle-step, handle-end, handle-mastery, handle-health) directly, NOT the
;;; Hunchentoot wrappers. Each logic fn has signature (server parsed-body) →
;;; (values response-plist http-status). Parsed-body is the alist produced by
;;; yason:parse with *parse-object-as* :alist (string keys).
;;;
;;; DEVIATION FROM BRIEF (noted): the brief's http.handle-start-step-end test
;;; asserts that a step AFTER handle-end yields 409 (:conflict). Per Task 3's
;;; server-end-session contract, however, end takes the session's lock and
;;; prog1 (mtt:end-session ...) (remhash ...) — the handle is removed atomically
;;; with the :ended marking. A subsequent step therefore finds NO handle and
;;; returns (values nil :not-found) → 404, not 409. The :conflict (409) path is
;;; only reachable in the step-vs-end race where a stepper reads the handle
;;; before the ender acquires the lock, then observes the (now :ended) session
;;; in its outside-lock fast path (server-step-session lines 187-188). That
;;; path is covered by server-step-session.concurrent-step-vs-end-race above
;;; and by http.step-conflict-via-ended-handle below (which re-inserts an
;;; :ended handle to deterministically exercise 409). The brief's verbatim
;;; assertion would never see 409 in a sequential test.
;;;
;;; DEVIATION FROM BRIEF (paren typos): the brief's http.errors test has 1
;;; extra close-paren in each of the unknown-model clause (line: ("model_id"
;;; . "nope")))) — should be 3 closes: pair, alist, handle-start, leaving mvb
;;; open for the body) and the mastery clause (line: "ghost")) — should be 1
;;; close, just handle-mastery). Without these fixes the file does not read.

(test http.handle-start-step-end
  "Pure handler-logic lifecycle: handle-start -> handle-step (200, :on-path) ->
handle-end (200, :ok t) -> handle-step again (404 — Task 3's server-end-session
remhashes the handle, so a sequential post-end step is :not-found, not
:conflict). The :conflict path is exercised separately below."
  (let ((server (start-tutor-server :port 0 :start-acceptor-p nil)))
    (unwind-protect
         (progn
           (multiple-value-bind (md adapter) (%stub-model+adapter)
             (register-model server "add" md adapter))
           (multiple-value-bind (resp status)
               (mtt/server::handle-start server '(("student_id" . "alice")
                                                  ("problem_id" . "5+2")
                                                  ("model_id" . "add")))
             (is (= 200 status))
             (is (stringp (getf resp :session_id)))
             (let ((sid (getf resp :session_id)))
               ;; step (stub maps to on-path)
               (multiple-value-bind (r2 s2)
                   (mtt/server::handle-step server `(("session_id" . ,sid)
                                                     ("action" ((type . start)))))
                 (is (= 200 s2))
                 (is (eq :on-path (getf r2 :status))))
               ;; end
               (multiple-value-bind (r3 s3)
                   (mtt/server::handle-end server `(("session_id" . ,sid)))
                 (is (= 200 s3))
                 (is (eql t (getf r3 :ok))))
               ;; step after end -> 404 (NOT 409). server-end-session remhashes
               ;; the handle atomically with marking :ended, so a sequential
               ;; post-end step sees no handle -> :not-found -> 404. Brief said
               ;; 409; see deviation note above.
               (multiple-value-bind (r4 s4)
                   (mtt/server::handle-step server `(("session_id" . ,sid)
                                                     ("action" ((type . start)))))
                 (declare (ignore r4))
                 (is (= 404 s4))))))
      (stop-tutor-server server))))

(test http.errors
  "Error-code mapping: unknown session -> 404, unknown model_id -> 404, unknown
student (mastery) -> 404."
  (let ((server (start-tutor-server :port 0 :start-acceptor-p nil)))
    (unwind-protect
         (progn
           (multiple-value-bind (md adapter) (%stub-model+adapter)
             (register-model server "add" md adapter))
           ;; unknown session -> 404
           (multiple-value-bind (_ s)
               (mtt/server::handle-step server '(("session_id" . "nope")
                                                 ("action" ((type . start)))))
             (declare (ignore _)) (is (= 404 s)))
           ;; unknown model -> 404
           (multiple-value-bind (_ s)
               (mtt/server::handle-start server '(("student_id" . "a")
                                                  ("problem_id" . "p")
                                                  ("model_id" . "nope")))
             (declare (ignore _)) (is (= 404 s)))
           ;; mastery for unknown student -> 404
           (multiple-value-bind (_ s)
               (mtt/server::handle-mastery server "ghost")
             (declare (ignore _)) (is (= 404 s))))
      (stop-tutor-server server))))

(test http.step-conflict-via-ended-handle
  "Deterministically exercise the :conflict (409) path: register a session,
capture its handle, end it (which remhashes), then re-insert the (now :ended)
handle and verify handle-step returns 409. This mirrors the race-window shape
that server-step-session.concurrent-step-vs-end-race tests at the programmatic
layer: a handle exists in the registry pointing at an :ended cognitive-session."
  (let ((server (start-tutor-server :port 0 :start-acceptor-p nil)))
    (unwind-protect
         (progn
           (multiple-value-bind (md adapter) (%stub-model+adapter)
             (register-model server "add" md adapter))
           (let ((sid (server-start-session server "alice" "5+2" "add")))
             (is (stringp sid))
             (let ((handle (gethash sid (server-sessions server))))
               (is (not (null handle)))
               ;; end: remhashes the handle, marks the cognitive-session :ended.
               (multiple-value-bind (r3 s3)
                   (mtt/server::handle-end server `(("session_id" . ,sid)))
                 (is (= 200 s3))
                 (is (eql t (getf r3 :ok))))
               (is (null (gethash sid (server-sessions server))))
               ;; re-insert the (now :ended) handle to force the :conflict path.
               (setf (gethash sid (server-sessions server)) handle)
               (multiple-value-bind (r4 s4)
                   (mtt/server::handle-step server `(("session_id" . ,sid)
                                                     ("action" ((type . start)))))
                 (declare (ignore r4))
                 (is (= 409 s4))))))
      (stop-tutor-server server))))

(test http.handle-health-shape
  "handle-health returns (values plist 200); plist has :status \"ok\" and
counter keys (delegating to server-health)."
  (let ((server (start-tutor-server :port 0 :start-acceptor-p nil)))
    (unwind-protect
         (progn
           (multiple-value-bind (md adapter) (%stub-model+adapter)
             (register-model server "add" md adapter))
           (server-start-session server "alice" "5+2" "add")
           (multiple-value-bind (resp status)
               (mtt/server::handle-health server)
             (is (= 200 status))
             (is (equal "ok" (getf resp :status)))
             (is (eql 1 (getf resp :active_sessions)))
             (is (eql 1 (getf resp :students)))))
      (stop-tutor-server server))))

;;; --- Phase 5 Task 6: real-HTTP smoke + concurrency isolation -----------------
;;;
;;; Tasks 3-4 unit-tested the PURE handler logic (handle-*) and the programmatic
;;; server API. Task 6 closes the last gap: prove the wiring is correct end-to-end
;;; over REAL HTTP (Hunchentoot acceptor on an ephemeral port + dexador client
;;; hitting all 5 endpoints), and prove the Phase 4 isolation invariant — each
;;; session is an independent unit of mutable state — holds under genuine
;;; concurrent HTTP traffic. This is the Phase 5 analog of Phase 4's
;;; tests/test-concurrent.lisp: different sessions driven in parallel must NOT
;;; crosstalk.
;;;
;;; NOTES:
;;;   * %find-free-port lives in THIS package (the redis-store test file defines
;;;     its own copy in :mtt/redis-store-test — we don't import across test
;;;     packages; tests stay decoupled).
;;;   * yason:parse is called with :object-as :alist. Verified against
;;;     yason-20250622-git/parse.lisp line 280: `parse` accepts (:object-as
;;;     *parse-object-as*) as a keyword arg and binds it for the call. No need
;;;     to wrap with (let ((yason:*parse-object-as* :alist)) ...).
;;;   * DEVIATION FROM BRIEF (closure capture): the brief's
;;;       (loop for sid in sids collect (bt:make-thread (lambda () ...sid...)))
;;;     captures the SAME loop-variable binding across all lambdas under SBCL
;;;     (verified: (loop for x in '(1 2 3) collect (lambda () x)) -> (3 3 3)),
;;;     so all N threads would step the LAST session only — defeating the test's
;;;     stated "DIFFERENT session" intent. Fixed via (let ((sid sid)) ...) inside
;;;     the loop body so each thread closes over a fresh binding.

(defun %find-free-port ()
  "Bind socket 0 on the loopback, read the OS-assigned port, close. usocket is a
transitive dependency via hunchentoot, so no extra asd dep needed. There is a
small TOCTOU window between close and hunchentoot:listen, but it is the standard
portable ephemeral-port idiom and is fine for smoke tests."
  (let ((sock (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (unwind-protect (usocket:get-local-port sock)
      (usocket:socket-close sock))))

(test http.real-smoke-over-wire
  "End-to-end over real HTTP: start a tutor-server with a live Hunchentoot
acceptor on an ephemeral port, register the reference addition model+adapter,
then dexador-drive /health, /session/start, and /session/step. Asserts each
response is 200 + has the expected JSON body shape. Proves the
tutor-acceptor per-instance dispatch-table is populated and routes hit the
pure handler fns (Tasks 4 + 5 wiring is live over the wire)."
  (let* ((port (%find-free-port))
         (s (mtt/server:start-tutor-server :port port :start-acceptor-p t)))
    (unwind-protect
         (progn
           (mtt/server:register-model s "add"
                                      (mtt/addition-adapter:build-addition-model)
                                      (mtt/addition-adapter:make-addition-adapter))
           (sleep 0.3)                          ; acceptor is up; brief's paranoia window
           ;; /health -> 200 + JSON {"status": "ok", ...}
           (multiple-value-bind (body status)
               (dex:get (format nil "http://127.0.0.1:~a/health" port))
             (is (= 200 status))
             (is (assoc "status" (yason:parse body :object-as :alist)
                        :test #'string=)))
           ;; /session/start -> 200 + JSON {"session_id": "...", "student_id": "a"}
           (multiple-value-bind (body status)
               (dex:post (format nil "http://127.0.0.1:~a/session/start" port)
                         :content "{\"student_id\":\"a\",\"problem_id\":\"5+2\",\"model_id\":\"add\"}")
             (is (= 200 status))
             (let ((sid (cdr (assoc "session_id"
                                    (yason:parse body :object-as :alist)
                                    :test #'string=))))
               (is (stringp sid))
               ;; /session/step -> 200 + JSON step response (action start fires
               ;; initialize-addition under the addition adapter).
               (multiple-value-bind (b2 s2)
                   (dex:post (format nil "http://127.0.0.1:~a/session/step" port)
                             :content (format nil "{\"session_id\":\"~a\",\"action\":{\"type\":\"start\"}}" sid))
                 (is (= 200 s2))
                 (is (assoc "status" (yason:parse b2 :object-as :alist)
                            :test #'string=))))))
      (mtt/server:stop-tutor-server s))))

(test http.concurrent-different-sessions-parallel
  "N threads each drive a DIFFERENT session over HTTP; all succeed independently
(Phase 5 isolation under real concurrent HTTP traffic). The server starts 1
student-session (shared log) and N distinct cognitive-sessions under it; each
thread POSTs a /session/step to ITS OWN session-id. Every step fires
initialize-addition under that session's per-session lock — no shared mutable
target across threads, so all N responses are 200 and there is no crosstalk.
This is the Phase 5 analog of Phase 4's tests/test-concurrent.lisp."
  (let* ((port (%find-free-port))
         (s (mtt/server:start-tutor-server :port port :start-acceptor-p t)))
    (unwind-protect
         (progn
           (mtt/server:register-model s "add"
                                      (mtt/addition-adapter:build-addition-model)
                                      (mtt/addition-adapter:make-addition-adapter))
           (sleep 0.3)
           (let* ((n 6)
                  ;; Pre-start N sessions SERIALLY (so session creation isn't
                  ;; part of the parallel stress — we want the step path
                  ;; parallelized, exactly per the brief).
                  (sids (loop repeat n collect
                              (cdr (assoc "session_id"
                                          (yason:parse
                                           (nth-value 0
                                            (dex:post
                                             (format nil "http://127.0.0.1:~a/session/start" port)
                                             :content "{\"student_id\":\"u\",\"problem_id\":\"5+2\",\"model_id\":\"add\"}"))
                                           :object-as :alist)
                                          :test #'string=))))
                  ;; DEVIATION (closure capture): (let ((sid sid)) ...) inside
                  ;; the loop body so each thread closes over a FRESH sid
                  ;; binding. See file header note for Phase 5 Task 6.
                  (threads (loop for sid in sids collect
                                 (let ((sid sid))
                                   (bt:make-thread
                                    (lambda ()
                                      (nth-value 1
                                       (dex:post
                                        (format nil "http://127.0.0.1:~a/session/step" port)
                                        :content (format nil "{\"session_id\":\"~a\",\"action\":{\"type\":\"start\"}}"
                                                         sid)))))))))
             (is (= n (length sids)))
             (is (= n (length (remove-duplicates sids :test #'string=))))
             (let ((results (mapcar #'bt:join-thread threads)))
               (is (= n (length results)))
               (is (every (lambda (x) (= 200 x)) results)
                   (format nil "expected all ~a results to be 200, got ~a" n results)))))
      (mtt/server:stop-tutor-server s))))
