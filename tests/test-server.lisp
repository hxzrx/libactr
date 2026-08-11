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
