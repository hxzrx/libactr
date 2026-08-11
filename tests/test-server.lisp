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
