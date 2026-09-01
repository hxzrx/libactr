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
               (is (= 1 (length m)))
               ;; Phase 6: the stub's single on-path step yields one kc with P(L)=[t]=2/5.
               (let ((entry (first m)))
                 (is (numberp (getf entry :p-l)))
                 (is (< (abs (- (getf entry :p-l) 2/5)) 1e-6))))
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
  "Two SEQUENTIAL sessions under the same student share ONE student-session
(and thus one event log) in the students registry. server-start-session is
IDEMPOTENT per student: while one cognitive-session is ACTIVE, subsequent
same-student starts return the existing session's id. To get a SECOND distinct
session for the same student, the first must be ended first — which mirrors
the real lifecycle (one active problem attempt per student at a time, but the
shared student log accumulates across all of that student's attempts)."
  (let ((server (start-tutor-server :port 0 :start-acceptor-p nil)))
    (unwind-protect
         (progn
           (multiple-value-bind (md adapter) (%stub-model+adapter)
             (register-model server "add" md adapter))
           (let ((sid1 (server-start-session server "alice" "5+2" "add")))
             ;; step sid1 -> 1 event on the shared student log
             (server-step-session server sid1 '((type . start)))
             ;; end sid1 -> handle remhash'd, cognitive-session :ended; the
             ;; next same-student start can now create a NEW session.
             (server-end-session server sid1)
             (let ((sid2 (server-start-session server "alice" "3+1" "add")))
               (is (not (equal sid1 sid2)))
               ;; one student-session for both sessions
               (is (= 1 (hash-table-count (server-students server))))
               ;; only sid2 is currently active (sid1's handle was remhash'd)
               (is (= 1 (hash-table-count (server-sessions server))))
               ;; step sid2 -> 2 events total on the shared student log
               (server-step-session server sid2 '((type . start)))
               (let ((ss (gethash "alice" (server-students server))))
                 (is (= 2 (mtt:log-last-seq (mtt:student-session-log ss))))))))
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
student-id. server-start-session is IDEMPOTENT under same-student concurrent
starts: the first caller through the students-lock creates the cognitive-
session; the rest observe it ACTIVE and return its id. So 16 concurrent
same-student starts yield exactly ONE cognitive-session (no pushnew-on-shared-
list race, no server-sessions hash-table setf race), and ALL 16 returned ids
are EQUAL. This is deterministic — no flake."
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
               ;; all 16 calls returned a string
               (is (= n (length sids)))
               (is (every #'stringp sids))
               ;; all 16 returned ids are EQUAL — the idempotent invariant
               (is (= 1 (length (remove-duplicates sids :test #'string=)))
                   (format nil "expected all ~a sids equal, got ~a" n sids))
               ;; exactly ONE student-session was created
               (is (= 1 (hash-table-count (server-students server))))
               ;; exactly ONE cognitive-session handle is registered
               (is (= 1 (hash-table-count (server-sessions server))))
               ;; the single student-session has exactly one cognitive-session id
               (let ((ss (gethash "racer" (server-students server))))
                 (is (not (null ss)))
                 (is (= 1 (length (mtt:student-session-sessions ss))))))))
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

;;; --- Phase 9: recursive json-encode (nested plists -> objects) ----------------
;;;
;;; json-encode previously delegated to yason:encode-plist, which encodes only
;;; the TOP-level plist as a JSON object and FLATTENS any nested plist into an
;;; array of atoms (yason does not recurse on plists). The step response's
;;; :mastery and the mastery response's :kc are LISTS OF PLISTS (one per KC);
;;; real consumers expect [{"kc":"...","correct":3,...}, ...] but got
;;; array-of-arrays. The recursive encoder (plist -> hash-table/object,
;;; list-of-plists -> array-of-objects) fixes both at the single chokepoint.

(test http.json-encode-nested-mastery-is-array-of-objects
  "json-encode must serialize :mastery (a list of per-KC plists) as a JSON array
of OBJECTS, not yason's flat array-of-arrays. This is the consumer-facing
defect."
  (let* ((resp (list :status :on-path
                     :mastery (list (list :kc "add-fractions"
                                          :correct 3 :total 5 :accuracy 0.6 :p_l 2/5))))
         (json (mtt/server::json-encode resp))
         (parsed (yason:parse json :object-as :alist)))
    (is (string= "on-path" (cdr (assoc "status" parsed :test #'string=))))
    (let ((mastery (cdr (assoc "mastery" parsed :test #'string=))))
      (is (listp mastery))
      (is (= 1 (length mastery)))
      (let ((entry (first mastery)))
        ;; entry must be an OBJECT (alist with string keys), not a flat array
        ;; of atoms.
        (is (string= "add-fractions" (cdr (assoc "kc" entry :test #'string=))))
        (is (eql 3 (cdr (assoc "correct" entry :test #'string=))))
        (is (eql 5 (cdr (assoc "total" entry :test #'string=))))))))

(test http.json-encode-scalar-and-null-handling
  "Top-level keyword keys are lowercased; keyword values become lowercase
strings; t -> true; nil -> null; numbers/strings pass through."
  ;; NOTE: the brief's verbatim test used the keyword :kw-val (hyphen) but
  ;; asserted the JSON key \"kw_val\" (underscore). The brief's own reference
  ;; %jsonify does (string-downcase (symbol-name k)), which preserves hyphens,
  ;; and EVERY real response key in this codebase uses underscores literally
  ;; (:session_id, :student_id, :active_sessions, :p_l). The brief's test as
  ;; written could not pass under the brief's own implementation. Resolved to
  ;; :kw_val to match the codebase convention + the brief's implementation;
  ;; the value :on-path (hyphen, like every real status value) is unchanged.
  (let ((parsed (yason:parse (mtt/server::json-encode
                              (list :kw_val :on-path :flag t :absent nil :n 7 :s "x"))
                             :object-as :alist)))
    (is (string= "on-path" (cdr (assoc "kw_val" parsed :test #'string=))))
    (is (eql t (cdr (assoc "flag" parsed :test #'string=))))
    (is (null (cdr (assoc "absent" parsed :test #'string=))))
    (is (eql 7 (cdr (assoc "n" parsed :test #'string=))))
    (is (string= "x" (cdr (assoc "s" parsed :test #'string=))))))

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
(Phase 5 isolation under real concurrent HTTP traffic). The server starts N
DISTINCT student-sessions (one per student-id) — one cognitive-session each —
because server-start-session is now IDEMPOTENT per student (a same-student
second start returns the existing active session's id). Each thread POSTs a
/session/step to ITS OWN session-id. Every step fires initialize-addition
under that session's per-session lock — no shared mutable target across
threads, so all N responses are 200 and there is no crosstalk. This is the
Phase 5 analog of Phase 4's tests/test-concurrent.lisp."
  (let* ((port (%find-free-port))
         (s (mtt/server:start-tutor-server :port port :start-acceptor-p t)))
    (unwind-protect
         (progn
           (mtt/server:register-model s "add"
                                      (mtt/addition-adapter:build-addition-model)
                                      (mtt/addition-adapter:make-addition-adapter))
           (sleep 0.3)
           (let* ((n 6)
                  ;; Pre-start N sessions SERIALLY under N DIFFERENT student-ids
                  ;; (u1..u6) — server-start-session is now idempotent per
                  ;; student, so reusing one student-id would collapse to 1
                  ;; session. We want N genuinely-distinct sessions for the
                  ;; parallel-step isolation proof.
                  (sids (loop for i from 1 to n collect
                              (cdr (assoc "session_id"
                                          (yason:parse
                                           (nth-value 0
                                            (dex:post
                                             (format nil "http://127.0.0.1:~a/session/start" port)
                                             :content (format nil "{\"student_id\":\"u~a\",\"problem_id\":\"5+2\",\"model_id\":\"add\"}" i)))
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

;;; --- Phase 5 Task 7: addition full-problem end-to-end over real HTTP -----------
;;;
;;; Drives a COMPLETE 5+2 problem (start -> next-total six -> next-total seven ->
;;; submit -> GET /student/mastery -> end) over real HTTP against the reference
;;; addition model + adapter. This is the closing integration test of the Phase 5
;;; service layer: every endpoint, the addition adapter's two-step-per-action
;;; contract, and the shared student log all wired together. Asserts 200s on every
;;; step, and that /student/mastery returns kc-tagged mastery data (proves the
;;; shared student log is being aggregated from the per-session event log).
;;;
;;; NOTE (Phase 6): the addition adapter's :next-total now returns BOTH steps
;;; (increment-sum, then increment-count) as a primed intent list, so the VISIBLE
;;; (first) step is increment-sum — the student's reported total. Both steps are
;;; logged and feed mastery. We assert production = "increment-sum".

(test addition.e2e-full-problem
  (let* ((port (%find-free-port))
         (s (mtt/server:start-tutor-server :port port :start-acceptor-p t)))
    (unwind-protect
         (progn
           (mtt/server:register-model s "add" (mtt/addition-adapter:build-addition-model)
                                      (mtt/addition-adapter:make-addition-adapter))
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
                                          "{\"student_id\":\"lea\",\"problem_id\":\"5+2\",\"model_id\":\"add\"}")
                                    :test #'string=))))
               ;; full 5+2: start, six, seven, submit (mirror addition-tutor demonstrate)
               (is (= 200 (nth-value 1 (jstep sid "{\"type\":\"start\"}"))))
               ;; Phase 6 multi-step: :next-total's VISIBLE (first) step is now
               ;; increment-sum (was increment-count).
               (flet ((next-total-prod (action)
                        (cdr (assoc "production"
                                    (nth-value 0 (jstep sid action))
                                    :test #'string=))))
                 (is (string= "increment-sum"
                              (next-total-prod "{\"type\":\"next-total\",\"value\":\"six\"}")))
                 (is (string= "increment-sum"
                              (next-total-prod "{\"type\":\"next-total\",\"value\":\"seven\"}"))))
               (multiple-value-bind (resp status) (jstep sid "{\"type\":\"submit\",\"value\":\"seven\"}")
                 (declare (ignore resp))
                 (is (= 200 status)))
               ;; mastery for lea — the shared student log has aggregated the
               ;; kc-events from this session. Mirror fraction.e2e: confirm the
               ;; per-KC entries are JSON OBJECTS (each yields a KC name via the
               ;; "kc" cons) and that a known addition KC (increment-sum) appears.
               (multiple-value-bind (body status)
                   (dex:get (format nil "http://127.0.0.1:~a/student/mastery?student_id=lea" port))
                 (is (= 200 status))
                 (let ((kcs (mapcar (lambda (entry)
                                      (cdr (assoc "kc" entry :test #'string=)))
                                    (cdr (assoc "kc" (yason:parse body :object-as :alist)
                                                :test #'string=)))))
                   (is (find "INCREMENT-SUM" kcs :test #'string=))))
               ;; end
               (multiple-value-bind (body status)
                   (post "/session/end" (format nil "{\"session_id\":\"~a\"}" sid))
                 (declare (ignore body))
                 (is (= 200 status))))))
      (mtt/server:stop-tutor-server s))))

;;; --- Phase 9 Task 2: tutor-server configurable kt-params ----------------------
;;;
;;; compute-mastery already accepts &key (kt-params (make-kt-params)) (Phase 6)
;;; with per-KC overrides (Phase 7 kt-params-for), but the service layer called it
;;; WITHOUT kt-params in two places — server-student-mastery (server.lisp) and
;;; trace-result->response-plist (http-api.lisp, called by handle-step). So per-KC
;;; Bayesian overrides never reached HTTP mastery. These tests prove the
;;; per-server kt-params slot threads through to BOTH compute-mastery call sites:
;;; the GET /student/mastery path (test 1) and the inline :mastery in the step
;;; response (test 2). The stub's on-path step produces an initialize-addition KC
;;; (name-fallback, interned in :mtt/server-test); the tests key the override on
;;; 'initialize-addition (same package symbol -> eql match in kt-params-for).

(test server.kt-params-override-reaches-mastery
  "A tutor-server built with :kt-params carrying a per-KC override yields mastery
P(L) that reflects the override (proves the slot threads through to
compute-mastery via server-student-mastery). The stub's on-path step produces an
initialize-addition KC (name-fallback, interned in :mtt/server-test)."
  (flet ((master-p-l (server)
           (getf (first (server-student-mastery server "alice")) :p-l)))
    (let ((default-server (start-tutor-server :port 0 :start-acceptor-p nil))
          (override-server
            (start-tutor-server
             :port 0 :start-acceptor-p nil
             :kt-params (make-kt-params
                         :overrides (list (cons 'initialize-addition
                                                (make-kt-params :transit 0.01d0)))))))
      (unwind-protect
           (progn
             (dolist (s (list default-server override-server))
               (multiple-value-bind (md adapter) (%stub-model+adapter)
                 (register-model s "add" md adapter))
               (let ((sid (server-start-session s "alice" "5+2" "add")))
                 (server-step-session s sid '((type . start)))
                 (server-end-session s sid)))
             ;; default transit 0.1 -> [t] = 2/5 = 0.4
             (is (< (abs (- (master-p-l default-server) 2/5)) 1e-6))
             ;; override transit 0.01 climbs slower -> strictly lower P(L)
             (is (< (master-p-l override-server) (master-p-l default-server))))
        (stop-tutor-server default-server)
        (stop-tutor-server override-server)))))

(test server.kt-params-override-reaches-step-response
  "The step response's inline :mastery also reflects the server's kt-params
(proves trace-result->response-plist threads kt-params via handle-step)."
  (let ((s (start-tutor-server
            :port 0 :start-acceptor-p nil
            :kt-params (make-kt-params
                        :overrides (list (cons 'initialize-addition
                                               (make-kt-params :transit 0.01d0)))))))
    (unwind-protect
         (progn
           (multiple-value-bind (md adapter) (%stub-model+adapter)
             (register-model s "add" md adapter))
           (let ((sid (server-start-session s "alice" "5+2" "add")))
             (multiple-value-bind (resp status)
                 (mtt/server::handle-step s `(("session_id" . ,sid)
                                              ("action" ((type . start)))))
               (is (= 200 status))
               (let ((mastery (getf resp :mastery)))
                 (is (listp mastery))
                 ;; with transit 0.01 the single [t] P(L) is strictly below the
                 ;; default 2/5, proving the override reached this computation.
                 (is (< (getf (first mastery) :p_l) 2/5))))))
      (stop-tutor-server s))))

;;; ---------------------------------------------------------------------------
;;; Phase 12 Task 4: malformed-input 400 mapping (debt #2).
;;; ---------------------------------------------------------------------------

(defclass bad-problem-adapter (stub-adapter) ()
  (:documentation "Signals bad-tutor-request from prepare-session."))

(defmethod prepare-session ((a bad-problem-adapter) session problem-id)
  (declare (ignore session))
  (signal-bad-request "stub: bad problem ~a" problem-id))

(defclass bad-action-adapter (stub-adapter) ()
  (:documentation "Signals bad-tutor-request from adapt-action (prepare-session
inherited from the stub)."))

(defmethod adapt-action ((a bad-action-adapter) action session)
  (declare (ignore session))
  (signal-bad-request "stub: bad action ~a" (cdr (assoc "type" action :test #'string=))))

(test http.bad-request-maps-to-400
  "bad-tutor-request from prepare-session (start) or adapt-action (step) maps
to 400 + :error message; the programmatic layer still sees the condition;
other conditions still propagate (500 semantics unchanged)."
  (let ((server (start-tutor-server :port 0 :start-acceptor-p nil)))
    (unwind-protect
         (progn
           (multiple-value-bind (md adapter) (%stub-model+adapter)
             (declare (ignore adapter))
             (register-model server "bad-problem" md (make-instance 'bad-problem-adapter))
             (register-model server "bad-action" md (make-instance 'bad-action-adapter)))
           ;; start -> prepare-session signals -> 400
           (multiple-value-bind (r s)
               (mtt/server::handle-start server '(("student_id" . "a")
                                                  ("problem_id" . "junk")
                                                  ("model_id" . "bad-problem")))
             (is (= 400 s))
             (is (string= "stub: bad problem junk" (getf r :error))))
           ;; programmatic start still sees the condition itself
           (signals bad-tutor-request
                    (server-start-session server "a" "junk" "bad-problem"))
           ;; step -> adapt-action signals -> 400
           (let ((sid (server-start-session server "b" "5+2" "bad-action")))
             (multiple-value-bind (r s)
                 (mtt/server::handle-step server `(("session_id" . ,sid)
                                                   ("action" . (("type" . "x")))))
               (is (= 400 s))
               (is (string= "stub: bad action x" (getf r :error))))
             (signals bad-tutor-request
                      (server-step-session server sid '((type . x))))))
      (stop-tutor-server server))))

(test server.session-id-cross-process-components
  "Phase 14 A2: make-session-id carries time + sub-second + gensym components
(cross-process uniqueness root fix — fresh images used to emit colliding
`sess-s1` sequences). Shape: sess-<ut36>-<irt36>-<gensym>."
  (let ((a (mtt/server::make-session-id))
        (b (mtt/server::make-session-id)))
    (is (string= "sess-" (subseq a 0 5)))
    ;; two component separators after the prefix (ut | irt | gensym)
    (is (= 2 (count #\- (subseq a 5))))
    (is (not (string= a b)))))

(test server.kc->json-exported
  "Phase 14 C4: kc->json is exported from :mtt/server — the single source for
KC stringification at data boundaries (the proxy had to inline a copy)."
  (is (eq :external (nth-value 1 (find-symbol "KC->JSON" :mtt/server))))
  (is (string= "BORROW" (mtt/server:kc->json :borrow))))

(test server.student-events-key-single-source
  "Phase 14 C3: the event-log key layout has ONE definition point, exported —
server event logs, cluster adoption, and the proxy's location-free mastery
all build it via student-events-key (was: three hardcoded format strings)."
  (is (eq :external (nth-value 1 (find-symbol "STUDENT-EVENTS-KEY" :mtt/server))))
  (is (string= "mtt:student:lea:events" (mtt/server:student-events-key "lea"))))
