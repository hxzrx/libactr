;;;; src/server.lisp — tutor-server runtime container (Phase 5 service layer)
;;;; The infrastructure-state container: ALL per-server mutable state (acceptor,
;;;; students/sessions/models registries, redis-config) lives as INSTANCE SLOTS
;;;; on this CLOS object — there are NO global variables in this file. The
;;;; per-session bordeaux lock lives on the session-handle (NOT on the core
;;;; cognitive-session — locks stay in the service layer per the global
;;;; constraint). The mtt core remains zero-global and lock-free.
(defpackage :mtt/server
  (:use :cl :mtt)
  (:nicknames :mtt-server)
  (:export #:tutor-server #:tutor-server-p
           #:session-handle
           #:handle-session #:handle-lock #:handle-adapter
           #:start-tutor-server #:stop-tutor-server
           #:register-model
           #:server-start-session #:server-step-session
           #:server-end-session #:server-student-mastery
           #:server-health
           ;; slot readers/accessors used by tests and (Task 4) HTTP handlers
           #:server-acceptor #:server-port
           #:server-students #:server-sessions #:server-models
           #:server-redis-config
           ;; Task 4 — per-instance HTTP dispatch (subclass of easy-acceptor)
           #:tutor-acceptor #:tutor-acceptor-dispatch-table))
(in-package :mtt/server)

;;; Forward declarations for the soft mtt/redis-store dependency. The
;;; redis-event-log backend lives in mtt/redis-store, which mtt/server does NOT
;;; depend on (so hunchentoot-only deployments are free of cl-redis/yason). The
;;; redis branch of event-log-for is taken only when the operator passes
;;; :redis-config, in which case the deployment is expected to have loaded
;;; mtt/redis-store. The ftype declaim silences the undefined-function
;;; style-warning at compile time; the function is resolved at load time.
(declaim (ftype (function (&key (:key string) (:host string) (:port integer))
                          (values t &optional))
                mtt:make-redis-event-log))

;;; Forward declaration for install-handlers! (defined in src/http-api.lisp,
;;; loaded AFTER this file per mtt.asd :serial t). start-tutor-server calls it
;;; at runtime; the notinline declaim lets the call compile before http-api is
;;; loaded without a style-warning, and explicitly permits the late redefinition.
(declaim (notinline install-handlers!))

;;; --- tutor-acceptor: per-instance dispatch table -----------------------------
;;;
;;; Hunchentoot's `easy-acceptor` reads the GLOBAL `hunchentoot:*dispatch-table*`
;;; (special variable) in its `acceptor-dispatch-request` method. There is no
;;; exported per-acceptor dispatch slot. To preserve the multi-tutor-server
;;; isolation invariant (multiple servers can coexist with no shared/global
;;; mutable state — server.lisp line 58), we subclass `easy-acceptor` with our
;;; own dispatch-table slot and specialize `acceptor-dispatch-request` to
;;; consult THAT instead of the global. install-handlers! (http-api.lisp) sets
;;; this slot. Each tutor-server's dispatchers close over that server's
;;; handlers, which close over the server instance — so the dispatcher graph
;;; is structurally isolated per server.

(defclass tutor-acceptor (hunchentoot:easy-acceptor)
  ((dispatch-table :accessor tutor-acceptor-dispatch-table :initform nil))
  (:documentation "Subclass of easy-acceptor with a per-instance dispatch-table
slot, so each tutor-server has its own dispatcher list (no shared global
hunchentoot:*dispatch-table* state)."))

(defmethod hunchentoot:acceptor-dispatch-request ((acceptor tutor-acceptor) request)
  "Iterate the per-instance dispatch-table; on a miss, defer to the next method
(easy-acceptor's default, which would consult hunchentoot:*dispatch-table* —
empty by default in this deployment)."
  (loop :for dispatcher :in (tutor-acceptor-dispatch-table acceptor)
        :for action = (funcall dispatcher request)
        :when action :return (funcall action)
        :finally (return (call-next-method))))

;;; --- session-handle: per-session cognitive-session + lock + adapter -----------

(defclass session-handle ()
  ((session :reader handle-session :initarg :session)
   (lock    :reader handle-lock    :initarg :lock)
   (adapter :reader handle-adapter :initarg :adapter))
  (:documentation "Service-layer wrapper around one cognitive-session: carries
the per-session bordeaux lock and a back-reference to the model's domain-adapter.
The cognitive-session itself (mtt core) holds no lock slot."))

;;; --- tutor-server: the infrastructure-state container -------------------------

(defclass tutor-server ()
  ((acceptor       :accessor server-acceptor       :initform nil)
   (port           :reader   server-port           :initarg :port :initform 0)
   (students       :accessor server-students       :initform (make-hash-table :test #'equal))
   (students-lock  :reader   server-students-lock  :initform (bt:make-lock "tutor-server.students"))
   (sessions       :accessor server-sessions       :initform (make-hash-table :test #'equal))
   (models         :accessor server-models         :initform (make-hash-table :test #'equal))
   (redis-config   :reader   server-redis-config   :initarg :redis-config :initform nil))
  (:documentation "Infrastructure-state container. Each instance owns its own
acceptor, registries, and per-student event logs. Multiple tutor-servers can
coexist (no global mutable state) — the multi-user-safety invariant is
structural, exactly as in Phase 4's concurrent proof. The students-lock
serializes the gethash-or-create path in ensure-student so two concurrent
server-start-session calls for the same NEW student-id cannot orphan one
caller's student-session/event-log."))

(defun tutor-server-p (x)
  "Type predicate for tutor-server."
  (typep x 'tutor-server))

(defun make-session-id ()
  "Generate a unique session-id string."
  (format nil "sess-~(~a~)" (gensym "s")))

(defun event-log-for (server student-id)
  "Return the event-log to attach to a new student-session. If SERVER has a
redis-config, build a redis-event-log keyed per-student (durable); otherwise a
fresh in-memory event-log.

SOFT DEPENDENCY: the redis-event-log class lives in the separate
mtt/redis-store system (which mtt/server does NOT depend on, to keep
hunchentoot-only deployments free of cl-redis/yason). The redis branch is only
taken when the operator passes :redis-config at start-tutor-server time, in
which case the deployment is expected to have loaded mtt/redis-store."
  (let ((rc (server-redis-config server)))
    (if rc
        (mtt:make-redis-event-log :key (format nil "mtt:student:~a:events" student-id)
                                  :host (getf rc :host) :port (getf rc :port))
        (mtt:make-event-log))))

(defun start-tutor-server (&key (port 0) (start-acceptor-p t) redis-config)
  "Create a tutor-server. When START-ACCEPTOR-P is true (the default), create
and start a Hunchentoot easy-acceptor (one-thread-per-connection taskmaster).
PORT 0 lets the OS assign a free port. REDIS-CONFIG, when supplied as a plist
\(:host :port), makes per-student event logs durable via redis-event-log. The
HTTP dispatch table is wired in Task 4 (http-api); we still start the acceptor
if requested so Task 4 can install handlers into a running server."
  (let ((server (make-instance 'tutor-server :port port :redis-config redis-config)))
    (when start-acceptor-p
      (setf (server-acceptor server)
            (make-instance 'tutor-acceptor :port port
                           :taskmaster (make-instance
                                        'hunchentoot:one-thread-per-connection-taskmaster)))
      ;; Wire the 5 HTTP endpoint handlers (defined in http-api.lisp) into the
      ;; acceptor's per-instance dispatch table BEFORE hunchentoot:start so
      ;; they are live from the moment the acceptor starts accepting
      ;; connections. Done only when start-acceptor-p is true (tests use
      ;; :start-acceptor-p nil and drive handle-* directly).
      (install-handlers! server)
      (hunchentoot:start (server-acceptor server)))
    server))

(defun stop-tutor-server (server)
  "Stop the Hunchentoot acceptor (soft) if running and clear the slot. Returns
SERVER. Safe to call multiple times."
  (when (server-acceptor server)
    (hunchentoot:stop (server-acceptor server) :soft t))
  (setf (server-acceptor server) nil)
  server)

(defun register-model (server model-id model adapter)
  "Preload a compiled read-only model-definition paired with its domain-adapter
under MODEL-ID (string). Subsequent server-start-session calls reference the
model by id. Returns SERVER."
  (setf (gethash model-id (server-models server)) (cons model adapter))
  server)

(defun ensure-student (server student-id)
  "Look up or create the student-session for STUDENT-ID. The student-session
owns the per-student (possibly durable) event log shared across all of that
student's cognitive-sessions.

Concurrency: the gethash-or-create path is serialized by the server's
students-lock. Without it, two concurrent server-start-session calls for the
same NEW student-id would both miss the registry, both create a student-session
(with separate event logs), and the second setf would orphan the first —
silently splitting that student's mastery across two logs. The lock is held
only for the hash-table transaction, not for downstream session-start work."
  (let ((table (server-students server))
        (lock (server-students-lock server)))
    (bt:with-lock-held (lock)
      (or (gethash student-id table)
          (setf (gethash student-id table)
                (mtt:start-student-session student-id
                                           :event-log (event-log-for server student-id)))))))

(defun server-start-session (server student-id problem-id model-id)
  "Start a new cognitive-session for STUDENT-ID working on PROBLEM-ID against the
pre-registered MODEL-ID. Reuses (or creates) the student-session so the event
log is shared across the student's sessions. Runs the adapter's prepare-session,
registers the cognitive-session under the student, installs a session-handle
(session + per-session lock + adapter) in the sessions registry, and returns
the new session-id (string)."
  (let ((entry (gethash model-id (server-models server))))
    (unless entry
      (error "unknown model-id ~a" model-id))
    (let* ((model (car entry))
           (adapter (cdr entry))
           (ss (ensure-student server student-id))
           (sid (make-session-id))
           (session (mtt:start-session model student-id problem-id
                                       :event-log (mtt:student-session-log ss)
                                       :model-id model-id :session-id sid)))
      (mtt:prepare-session adapter session problem-id)
      (mtt:register-cognitive-session ss session)
      (setf (gethash sid (server-sessions server))
            (make-instance 'session-handle
                           :session session
                           :lock (bt:make-lock (format nil "session-~a" sid))
                           :adapter adapter))
      sid)))

(defun server-step-session (server session-id action)
  "Trace one student step against the session registered under SESSION-ID.
ACTION is the alist the HTTP layer decoded (the adapter translates it to a
step-intent). Returns three values:
  (values trace-result adapter session)   ; on success
  (values nil :not-found)                 ; unknown session-id
  (values nil :conflict)                  ; session already ended

Concurrency: the per-session bordeaux lock serializes the WHOLE step —
adapt-action (which may prime the retrieval buffer as a side-effect) AND
step-session (model lookup + state update + event append). An outside-lock
fast-path :ended check is kept for cheap rejection, but the authoritative
:ended check is INSIDE the lock to close the TOCTOU window against a concurrent
server-end-session."
  (let ((handle (gethash session-id (server-sessions server))))
    (unless handle
      (return-from server-step-session (values nil :not-found)))
    (let ((session (handle-session handle))
          (adapter (handle-adapter handle))
          (lock (handle-lock handle)))
      ;; Outside-lock fast path: cheap rejection of clearly-ended sessions.
      (when (eq :ended (mtt:session-status session))
        (return-from server-step-session (values nil :conflict)))
      (bt:with-lock-held (lock)
        ;; Authoritative re-check under the lock: a concurrent server-end-session
        ;; may have ended this session between the fast-path check and lock
        ;; acquisition.
        (when (eq :ended (mtt:session-status session))
          (return-from server-step-session (values nil :conflict)))
        ;; adapt-action is inside the lock because it may mutate the session's
        ;; retrieval buffer; priming + step must be serialized together.
        (let ((intent (mtt:adapt-action adapter action session)))
          (values (mtt:step-session session intent) adapter session))))))

(defun server-end-session (server session-id)
  "End the session under SESSION-ID: take the final checkpoint, mark the
cognitive-session :ended, and remove the handle from the sessions registry.
Returns the end-session summary plist (which carries :status :ended), or
  (values nil :not-found)   ; unknown session-id
Serialized by the session-handle's lock."
  (let ((handle (gethash session-id (server-sessions server))))
    (unless handle
      (return-from server-end-session (values nil :not-found)))
    (let ((lock (handle-lock handle)))
      (bt:with-lock-held (lock)
        (prog1 (mtt:end-session (handle-session handle))
          (remhash session-id (server-sessions server)))))))

(defun server-student-mastery (server student-id)
  "Aggregate mastery for STUDENT-ID across all of that student's cognitive-
sessions by replaying the shared student log through compute-mastery. Returns a
list of plists ((:kc <kc> :correct <n> :total <n> :accuracy <float>) ...), or
  (values nil :not-found)   ; unknown student-id"
  (let ((ss (gethash student-id (server-students server))))
    (unless ss
      (return-from server-student-mastery (values nil :not-found)))
    (mtt:compute-mastery (mtt:log-all-events (mtt:student-session-log ss)))))

(defun server-health (server)
  "Return a shallow health plist: liveness plus counter shape. (The HTTP layer
in Task 4 serializes this to JSON.)"
  (list :status "ok"
        :active_sessions (hash-table-count (server-sessions server))
        :students (hash-table-count (server-students server))))
