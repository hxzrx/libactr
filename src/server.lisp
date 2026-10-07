;;;; src/server.lisp — tutor-server runtime container (Phase 5 service layer)
;;;; The infrastructure-state container: ALL per-server mutable state (acceptor,
;;;; students/sessions/models registries, redis-config) lives as INSTANCE SLOTS
;;;; on this CLOS object — there are NO global variables in this file. The
;;;; per-session bordeaux lock lives on the session-handle (NOT on the core
;;;; cognitive-session — locks stay in the service layer per the global
;;;; constraint). The libactr core remains zero-global and lock-free.
(defpackage :libactr/server
  (:use :cl :libactr)
  (:nicknames :libactr-server)
  (:export #:tutor-server #:tutor-server-p
           #:session-handle
           #:handle-session #:handle-lock #:handle-adapter
           #:start-tutor-server #:stop-tutor-server
           #:register-model
           #:server-start-session #:server-step-session
           #:server-end-session #:server-student-mastery
           #:server-health
           ;; Phase 14 C4 — KC stringification at data boundaries (proxy reuse)
           #:kc->json
           ;; Phase 14 C3 — canonical per-student event-log key
           #:student-events-key
           ;; Phase 14 A1 — zombie convergence: drop a stale local handle
           #:server-drop-session
           ;; Review F1/F3 — concurrency seams shared with libactr/cluster:
           ;; every registry access is locked; the per-student log lock
           ;; serializes shared-event-log reads against step-path appends.
           #:server-sessions-snapshot
           #:server-log-lock
           #:server-register-handle
           #:server-find-session-handle
           #:server-model-entry
           ;; slot readers/accessors used by tests and (Task 4) HTTP handlers
           #:server-acceptor #:server-port
           #:server-students #:server-sessions #:server-models
           #:server-redis-config
           ;; Review F8 — request body size cap in bytes (nil = unlimited)
           #:server-max-body-size
           ;; Phase 9 Task 2 — per-server kt-params (per-KC BKT overrides)
           #:server-kt-params
           ;; Task 4 — per-instance HTTP dispatch (subclass of easy-acceptor)
           #:tutor-acceptor #:tutor-acceptor-dispatch-table))
(in-package :libactr/server)

;;; Forward declarations for the soft libactr/redis-store dependency. The
;;; redis-event-log backend lives in libactr/redis-store, which libactr/server does NOT
;;; depend on (so hunchentoot-only deployments are free of cl-redis/yason). The
;;; redis branch of event-log-for is taken only when the operator passes
;;; :redis-config, in which case the deployment is expected to have loaded
;;; libactr/redis-store. The ftype declaim silences the undefined-function
;;; style-warning at compile time; the function is resolved at load time.
(declaim (ftype (function (&key (:key string) (:host string) (:port integer))
                          (values t &optional))
                libactr:make-redis-event-log))

;;; Forward declaration for install-handlers! (defined in src/http-api.lisp,
;;; loaded AFTER this file per libactr.asd :serial t). start-tutor-server calls it
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
The cognitive-session itself (libactr core) holds no lock slot."))

;;; --- tutor-server: the infrastructure-state container -------------------------

(defclass tutor-server ()
  ((acceptor       :accessor server-acceptor       :initform nil)
   (port           :reader   server-port           :initarg :port :initform 0)
   (students       :accessor server-students       :initform (make-hash-table :test #'equal))
   (students-lock  :reader   server-students-lock  :initform (bt:make-lock "tutor-server.students"))
   (sessions       :accessor server-sessions       :initform (make-hash-table :test #'equal))
   (models         :accessor server-models         :initform (make-hash-table :test #'equal))
   (redis-config   :reader   server-redis-config   :initarg :redis-config :initform nil)
   ;; Review F1: the students-lock is the REGISTRY lock — it guards EVERY read
   ;; and write of the students/sessions/models tables (plain CL hash tables
   ;; are not safe for concurrent reader+writer access; the step/mastery/health
   ;; read paths previously took no lock at all).
   ;; Review F3: per-student locks guarding each student's SHARED event log
   ;; (student-id -> bordeaux lock). The student log outlives any one session,
   ;; so no session lock can cover it; the mastery read path and the step/end
   ;; paths serialize on these. Entries are never removed (bounded by the
   ;; student registry's lifetime, like the student-session itself).
   (log-locks      :accessor server-log-locks       :initform (make-hash-table :test #'equal))
   ;; Review F4: per-student incremental BKT cache (student-id -> plist with
   ;; :last-seq / :kt-params / :entries). Guarded by the student's LOG lock
   ;; (read and written together with the log it summarizes).
   (mastery-cache  :accessor server-mastery-cache   :initform (make-hash-table :test #'equal))
   ;; Review F8: request-body size cap in bytes (nil = unlimited). Enforced in
   ;; the HTTP wrappers (content-length checked BEFORE the body is read).
   (max-body-size  :reader   server-max-body-size  :initarg :max-body-size :initform 65536)
   ;; Phase 9 Task 2: per-server kt-params (one kt-params instance carrying per-KC
   ;; overrides; works across multiple models via compute-mastery's per-KC lookup).
   ;; Initform gives a fresh default when :kt-params is not supplied; start-tutor-
   ;; server uses (or kt-params (libactr:make-kt-params)) so an explicitly-nil key still
   ;; yields a real kt-params (avoids overriding the initform with nil).
   (kt-params      :reader   server-kt-params      :initarg :kt-params
                   :initform (libactr:make-kt-params)))
  (:documentation "Infrastructure-state container. Each instance owns its own
acceptor, registries, and per-student event logs. Multiple tutor-servers can
coexist (no global mutable state) — the multi-user-safety invariant is
structural, exactly as in Phase 4's concurrent proof.

Lock discipline (reviews F1/F3; acquisition chains only ever run SESSION ->
LOG -> REGISTRY — the SESSION lock is outermost, the REGISTRY lock is the
innermost leaf, held only for single hash-table operations; no path acquires
them in any other order, so no cycle is possible):
  * students-lock (the REGISTRY lock) serializes every access to the
    students/sessions/models/log-locks/mastery-cache tables — including the
    READ paths (step/mastery/health lookups), which previously took no lock.
    Same-student concurrent starts remain idempotent (first caller creates,
    rest observe that active session and return its id).
  * the per-session lock (on session-handle) serializes adapt + step + end for
    one session.
  * the per-student log lock (server-log-lock) serializes every append/read of
    that student's shared event log and guards its mastery-cache entry (the
    step and end paths hold it across their log writes; the mastery path holds
    it across its read+fold; the cache table update itself takes the registry
    lock inside)."))

(defun tutor-server-p (x)
  "Type predicate for tutor-server."
  (typep x 'tutor-server))

(defun make-session-id ()
  "Generate a unique session-id string. Cross-process uniqueness (phase 14
A2): universal time (seconds) + get-internal-real-time (sub-second wall-clock
resolution at call time — microseconds on SBCL) + the per-image gensym counter.
Fresh SBCL images used to emit colliding `sess-s1` sequences (per-image gensym
counter AND a deterministically seeded *random-state* — probed 2026-08-31), so
the two time components carry the cross-image entropy: a collision requires
two images calling in the same microsecond with aligned gensym counters
(workers additionally burn a worker-id-derived gensym offset first —
examples/cluster-worker.lisp — as defense-in-depth). No global counter is
introduced (this file stays zero-defvar/defparameter). The sid remains an
opaque string to consumers."
  (format nil "sess-~36r-~36r-~a"
          (get-universal-time)
          (get-internal-real-time)
          (gensym "s")))

(defun student-events-key (student-id)
  "Canonical redis key for STUDENT-ID's shared event log — the single source
of the libactr:student:<id>:events layout (phase 14 C3; used by event-log-for
here, cluster adoption, and the proxy's location-free mastery)."
  (format nil "libactr:student:~a:events" student-id))

(defun event-log-for (server student-id)
  "Return the event-log to attach to a new student-session. If SERVER has a
redis-config, build a redis-event-log keyed per-student (durable); otherwise a
fresh in-memory event-log.

SOFT DEPENDENCY: the redis-event-log class lives in the separate
libactr/redis-store system (which libactr/server does NOT depend on, to keep
hunchentoot-only deployments free of cl-redis/yason). The redis branch is only
taken when the operator passes :redis-config at start-tutor-server time, in
which case the deployment is expected to have loaded libactr/redis-store."
  (let ((rc (server-redis-config server)))
    (if rc
        (libactr:make-redis-event-log :key (student-events-key student-id)
                                  :host (getf rc :host) :port (getf rc :port))
        (libactr:make-event-log))))

;;; --- registry / log-lock seams (reviews F1/F3) --------------------------------
;;;
;;; Plain CL hash tables are NOT safe under concurrent reader+writer access on
;;; any supported implementation (SBCL and CCL both document this); before the
;;; F1 fix the step/mastery/health read paths touched the registries with no
;;; lock at all while start/end/drop wrote them. The helpers below are the ONE
;;; locked path per access shape; the exported ones double as the cluster
;;; layer's seams (scan tick and zombie sweep iterate a SNAPSHOT, never a live
;;; maphash over a table that request threads may be mutating).

(defun %ensure-log-lock-locked (server student-id)
  "Return (creating on first use) STUDENT-ID's log lock. CALLER HOLDS the
registry lock (this is the registry-held half of server-log-lock)."
  (or (gethash student-id (server-log-locks server))
      (setf (gethash student-id (server-log-locks server))
            (bt:make-lock (format nil "student-log-~a" student-id)))))

(defun server-log-lock (server student-id)
  "The per-student lock serializing every access to STUDENT-ID's SHARED event
log (step-path appends, end/checkpoint log-last-seq reads, mastery reads) and
guarding the student's mastery-cache entry. The student log outlives any one
session, so no session lock can cover it (review F3: a mastery read on one
thread used to iterate the same in-memory vector another thread was extending,
and on the redis backend two ops interleaved on one socket). Takes the registry
lock only to find-or-create the lock object (released before the caller
acquires it — the acquisition chain stays SESSION -> LOG -> REGISTRY)."
  (bt:with-lock-held ((server-students-lock server))
    (%ensure-log-lock-locked server student-id)))

(defun server-sessions-snapshot (server)
  "A fresh alist (session-id . session-handle) copying the sessions registry
under the registry lock (review F1: iterating a live maphash races concurrent
setf/remhash from request threads — the cluster scan/takeover ticks and any
other external iterator must walk this snapshot instead)."
  (bt:with-lock-held ((server-students-lock server))
    (let (acc)
      (maphash (lambda (sid handle) (push (cons sid handle) acc))
               (server-sessions server))
      acc)))

(defun server-register-handle (server session-id handle)
  "Install HANDLE under SESSION-ID in the sessions registry (under the registry
lock — review F1: the cluster takeover path previously setf'd the table
unlocked). Returns SESSION-ID."
  (bt:with-lock-held ((server-students-lock server))
    (setf (gethash session-id (server-sessions server)) handle))
  session-id)

(defun server-find-session-handle (server session-id)
  "Registry-locked session-handle lookup (review F1 read path — every reader
of the sessions table goes through here or a snapshot)."
  (bt:with-lock-held ((server-students-lock server))
    (gethash session-id (server-sessions server))))

(defun server-model-entry (server model-id)
  "Registry-locked model-registry lookup (review F1 read path)."
  (bt:with-lock-held ((server-students-lock server))
    (gethash model-id (server-models server))))

(defun %check-student-id (student-id)
  "Review F8 hardening: STUDENT-ID is embedded in redis keys and event records,
so it must be a non-empty string of at most 128 characters with no control
characters (a missing/empty/oversized id previously created degenerate
registry entries and odd keys). Signals bad-tutor-request (400 over HTTP)."
  (unless (and (stringp student-id)
               (plusp (length student-id))
               (<= (length student-id) 128)
               (notany (lambda (c)
                         (or (char< c #\space) (char= c #\Del)))
                       student-id))
    (libactr:signal-bad-request
     "libactr/server: student_id must be a non-empty string of at most 128 printable characters, got ~s"
     student-id)))

;;; --- incremental mastery (review F4) ------------------------------------------
;;;
;;; The step response's inline :mastery and GET /student/mastery previously
;;; folded the student's ENTIRE event history on every call (log-all-events:
;;; on the redis backend a full LRANGE 0 -1 plus one JSON parse per event per
;;; step — cost grew without bound with the student's cross-problem history).
;;; BKT is increment-friendly: per KC, P(L) folds one observation at a time, so
;;; caching (per-KC counts + P(L) + the last-seq folded) lets subsequent calls
;;; process only log-events-since. Full replay via compute-mastery remains the
;;; first-call / params-change / stale-cache path, so results are bit-identical
;;; to a from-scratch fold by construction (the same kt-update reduce over the
;;; same chronological sequence).

(defun %sort-mastery-entries (entries)
  "compute-mastery's emission order: a sorted COPY (the cached alist itself is
never mutated by the sort) by princ-to-string of the kc."
  (sort (copy-list entries) #'string<
        :key (lambda (p) (princ-to-string (getf p :kc)))))

(defun %fold-mastery-entries (entries new-events params)
  "Fold NEW-EVENTS (log-event list, chronological) into ENTRIES (alist kc ->
per-kc plist in compute-mastery's shape), returning a FRESH alist. A fresh KC
starts at its L0 (kt-params-for) — kt-posterior's empty-observation value — so
this continuation equals compute-mastery's from-scratch reduce."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (e entries) (setf (gethash (getf e :kc) table) e))
    (dolist (e new-events)
      (let* ((ke (libactr:log-event-kc-event e))
             (kc (and ke (libactr:kc-event-kc ke))))
        (when kc
          (let* ((params (libactr:kt-params-for kc params))
                 (entry (or (gethash kc table)
                            (list :kc kc :correct 0 :total 0
                                  :accuracy 0.0d0
                                  :p-l (libactr:kt-params-l0 params))))
                 (correct-p (libactr:kc-event-correct-p ke))
                 (correct (+ (getf entry :correct) (if correct-p 1 0)))
                 (total (1+ (getf entry :total))))
            (setf (gethash kc table)
                  (list :kc kc
                        :correct correct
                        :total total
                        :accuracy (coerce (/ correct total) 'double-float)
                        :p-l (libactr:kt-update (getf entry :p-l) correct-p params)))))))
    (let (out)
      (maphash (lambda (kc e) (declare (ignore kc)) (push e out)) table)
      out)))

(defun %student-mastery (server student-id &optional ss)
  "Per-student mastery with the incremental BKT cache. SS defaults to the
student-session looked up under the registry lock. All under the student's LOG
lock (the cache entry and the log are read/written together); the cache table
update takes the registry lock inside. Cache invalidation: first call,
kt-params instance change, or a log whose last-seq went DOWN (replaced/shrunk
log — full replay). Returns nil when the student is unknown."
  (let ((ss (or ss (bt:with-lock-held ((server-students-lock server))
                    (gethash student-id (server-students server))))))
    (when ss
      (bt:with-lock-held ((server-log-lock server student-id))
        (let* ((log (libactr:student-session-log ss))
               (params (server-kt-params server))
               (cache (bt:with-lock-held ((server-students-lock server))
                        (gethash student-id (server-mastery-cache server))))
               (last-seq (libactr:log-last-seq log))
               (entries
                 (cond
                   ((or (null cache)
                        (not (eq (getf cache :kt-params) params))
                        (< last-seq (getf cache :last-seq)))
                    ;; full replay: first call, changed params, or a shrunken log.
                    (let ((entries (libactr:compute-mastery
                                    (libactr:log-all-events log) :kt-params params)))
                      (bt:with-lock-held ((server-students-lock server))
                        (setf (gethash student-id (server-mastery-cache server))
                              (list :last-seq last-seq :kt-params params :entries entries)))
                      entries))
                   (t
                    (let ((new (libactr:log-events-since log (getf cache :last-seq))))
                      (if (null new)
                          (getf cache :entries)
                          (let ((entries (%fold-mastery-entries
                                          (getf cache :entries) new params)))
                            (bt:with-lock-held ((server-students-lock server))
                              (setf (gethash student-id (server-mastery-cache server))
                                    (list :last-seq last-seq :kt-params params :entries entries)))
                            entries)))))))
          (%sort-mastery-entries entries))))))

(defun start-tutor-server (&key (port 0) (start-acceptor-p t) redis-config kt-params
                             (max-body-size 65536))
  "Create a tutor-server. When START-ACCEPTOR-P is true (the default), create
and start a Hunchentoot easy-acceptor (one-thread-per-connection taskmaster).
PORT 0 lets the OS assign a free port. REDIS-CONFIG, when supplied as a plist
\(:host :port), makes per-student event logs durable via redis-event-log.
KT-PARAMS (Phase 9 Task 2), when supplied as a libactr:kt-params instance, threads
through to both compute-mastery call sites (server-student-mastery and the
inline :mastery in handle-step) so per-KC BKT overrides reach HTTP mastery.
Omitting it yields a fresh (make-kt-params) — identical to 期8 behavior. The
\(or kt-params (libactr:make-kt-params)) guard is essential: make-instance with
:kt-params nil would OVERRIDE the slot's initform with nil (yielding a nil
kt-params -> wrong-type bug downstream in compute-mastery); the guard ensures
an explicitly-nil key still gets a real default. Review F9: a supplied (or
defaulted) kt-params set is validated HERE (check-kt-params) — a G+S>=1
override used to divide by zero at mastery time.
MAX-BODY-SIZE (review F8) caps accepted request bodies in bytes (the HTTP
wrappers reject larger requests with 413 before reading the body); nil
disables the cap.
The HTTP dispatch table is wired in Task 4 (http-api); we still start the acceptor
if requested so Task 4 can install handlers into a running server."
  (let ((params (or kt-params (libactr:make-kt-params))))
    (libactr:check-kt-params params "start-tutor-server :kt-params")
    (let ((server (make-instance 'tutor-server
                                  :port port :redis-config redis-config
                                  :kt-params params
                                  :max-body-size max-body-size)))
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
      server)))

(defun stop-tutor-server (server)
  "Stop the Hunchentoot acceptor (soft) if running, disconnect each student's
event log (no-op for in-memory; closes redis), and clear the acceptor slot.
Returns SERVER. Safe to call multiple times. The student table is snapshot
under the registry lock first (review F1: no live maphash), and the
disconnections run OUTSIDE it (disconnect-log takes the redis backend's own
per-log lock)."
  (when (server-acceptor server)
    (hunchentoot:stop (server-acceptor server) :soft t))
  (setf (server-acceptor server) nil)
  (let ((students (bt:with-lock-held ((server-students-lock server))
                    (let (acc)
                      (maphash (lambda (id ss)
                                 (declare (ignore id))
                                 (push ss acc))
                               (server-students server))
                      acc))))
    (dolist (ss students)
      (disconnect-log (libactr:student-session-log ss))))
  server)

(defun register-model (server model-id model adapter)
  "Preload a compiled read-only model-definition paired with its domain-adapter
under MODEL-ID (string). Subsequent server-start-session calls reference the
model by id. Returns SERVER. The registry write takes the registry lock
(review F1: registration racing a request-thread lookup used to be an
unlocked writer-vs-reader pair)."
  (bt:with-lock-held ((server-students-lock server))
    (setf (gethash model-id (server-models server)) (cons model adapter)))
  server)

(defun ensure-student (server student-id)
  "Look up or create the student-session for STUDENT-ID. The student-session
owns the per-student (possibly durable) event log shared across all of that
student's cognitive-sessions.

Concurrency: this function is NOT thread-safe by itself — callers must hold
the server's students-lock (server-start-session does). The lock serializes
the gethash-or-create path so two concurrent server-start-session calls for
the same NEW student-id cannot orphan one caller's student-session/event-log."
  (let ((table (server-students server)))
    (or (gethash student-id table)
        (setf (gethash student-id table)
              (libactr:start-student-session student-id
                                         :event-log (event-log-for server student-id))))))

(defun find-active-session-id (server student-session)
  "Return the session-id of the first ACTIVE cognitive-session registered under
STUDENT-SESSION, or nil if the student has no active session. NOT thread-safe
by itself — callers must hold the server's students-lock (so the sessions
registry and the per-session cognitive-session status are observed
consistently)."
  (loop :for sid :in (libactr:student-session-sessions student-session)
        :for handle = (gethash sid (server-sessions server))
        :when (and handle
                   (eq :active (libactr:session-status (handle-session handle))))
        :return sid))

(defun server-start-session (server student-id problem-id model-id)
  "Start a new cognitive-session for STUDENT-ID working on PROBLEM-ID against the
pre-registered MODEL-ID. Reuses (or creates) the student-session so the event
log is shared across the student's sessions. Runs the adapter's prepare-session,
registers the cognitive-session under the student, installs a session-handle
(session + per-session lock + adapter) in the sessions registry, and returns
the new session-id (string).

IDEMPOTENT UNDER SAME-STUDENT CONCURRENT STARTS: if STUDENT-ID already has an
ACTIVE cognitive-session, return that session's id WITHOUT creating a new one.
This eliminates the same-student concurrent-start race (no second session is
created, no pushnew-on-shared-list race, no server-sessions hash-table setf
race — all 16 concurrent callers observe the same active session-id). The
active-check + create is serialized under the server's registry lock: the
first caller through the lock creates the session; the rest see it active and
return its id.

Review F1 (lock narrowing): the candidate session is BUILT and PREPARED
outside every lock (adapter code, and its bad-tutor-request signals, must not
hold unrelated students' starts hostage); only the ensure-student phase and
the active-check-and-register phase take the registry lock. A losing racer's
prepared session is simply discarded.

STUDENT-ID is validated first (review F8: non-empty printable string of at
most 128 characters — it is embedded in redis keys and event records)."
  (%check-student-id student-id)
  (let ((entry (server-model-entry server model-id)))
    (unless entry
      (error "unknown model-id ~a" model-id))
    (let ((model (car entry))
          (adapter (cdr entry)))
      ;; Phase 1 (registry): ensure the student-session + the log lock; capture
      ;; the shared log to inject into the candidate session.
      (multiple-value-bind (ss log-lock)
          (bt:with-lock-held ((server-students-lock server))
            (values (ensure-student server student-id)
                    (%ensure-log-lock-locked server student-id)))
        (declare (ignore log-lock))
        ;; Phase 2 (no locks): build + prepare the candidate session. A losing
        ;; same-student racer discards it at phase 3; a bad problem-id signals
        ;; here with nothing registered.
        (let* ((sid (make-session-id))
               (session (libactr:start-session model student-id problem-id
                                               :event-log (libactr:student-session-log ss)
                                               :model-id model-id :session-id sid)))
          (libactr:prepare-session adapter session problem-id)
          ;; Phase 3 (registry): idempotent active-check + register.
          (bt:with-lock-held ((server-students-lock server))
            (or (find-active-session-id server ss)
                (progn
                  (libactr:register-cognitive-session ss session)
                  (setf (gethash sid (server-sessions server))
                        (make-instance 'session-handle
                                       :session session
                                       :lock (bt:make-lock (format nil "session-~a" sid))
                                       :adapter adapter))
                  sid))))))))

(defun server-step-session (server session-id action)
  "Trace one student step against the session registered under SESSION-ID.
ACTION is the alist the HTTP layer decoded (the adapter translates it to a
step-intent). Returns three values:
  (values trace-result adapter session)   ; on success
  (values nil :not-found)                 ; unknown session-id
  (values nil :conflict)                  ; session already ended

Concurrency (reviews F1/F3): the registry lookup takes the registry lock
(released before the session lock is acquired — acquisition chains run
SESSION -> LOG -> REGISTRY). The per-session bordeaux lock serializes the WHOLE
step — adapt-action (which may prime the retrieval buffer as a side-effect) AND
step-session (model lookup + state update + event append). The student's LOG
lock is held across the step-session calls because they append to the student's
SHARED event log (a mastery read on another thread must never observe a
mid-step log, on either backend). An outside-lock fast-path :ended check is
kept for cheap rejection, but the authoritative :ended check is INSIDE the lock
to close the TOCTOU window against a concurrent server-end-session."
  (let ((handle (server-find-session-handle server session-id)))
    (unless handle
      (return-from server-step-session (values nil :not-found)))
    (let ((session (handle-session handle))
          (adapter (handle-adapter handle))
          (lock (handle-lock handle)))
      ;; Outside-lock fast path: cheap rejection of clearly-ended sessions.
      (when (eq :ended (libactr:session-status session))
        (return-from server-step-session (values nil :conflict)))
      (bt:with-lock-held (lock)
        ;; Authoritative re-check under the lock: a concurrent server-end-session
        ;; may have ended this session between the fast-path check and lock
        ;; acquisition.
        (when (eq :ended (libactr:session-status session))
          (return-from server-step-session (values nil :conflict)))
        ;; adapt-action is inside the lock because it may mutate the session's
        ;; retrieval buffer; priming + step must be serialized together. Phase 6
        ;; multi-step: adapt-action may return a single intent OR a list; each
        ;; intent's PRIME (buffer . chunk) pairs are installed before that step;
        ;; the FIRST step's trace-result is the student-facing result.
        (let* ((raw (libactr:adapt-action adapter action session))
               (intents (if (libactr:step-intent-p raw) (list raw) raw))
               (results nil))
          (bt:with-lock-held
              ((server-log-lock server (libactr:session-student-id session)))
            (dolist (intent intents)
              ;; Install this step's prime buffers (if any) before tracing.
              (dolist (p (libactr:step-intent-prime intent))
                (setf (libactr:buffer-chunk (libactr:session-state session) (car p)) (cdr p)))
              (push (libactr:step-session session intent) results)))
          ;; FIRST step's result is the student-facing primary result.
          (values (first (nreverse results)) adapter session))))))

(defun server-end-session (server session-id)
  "End the session under SESSION-ID: take the final checkpoint, mark the
cognitive-session :ended, and remove the handle from the sessions registry.
Returns the end-session summary plist (which carries :status :ended), or
  (values nil :not-found)   ; unknown session-id
Serialized by the session-handle's lock; the student's LOG lock is held across
end-session (its checkpoint reads log-last-seq from the shared student log) and
the registry remhash takes the registry lock inside (review F1: end previously
remhash'd with NO registry lock — an unlocked writer against the concurrent
step/mastery readers)."
  (let ((handle (server-find-session-handle server session-id)))
    (unless handle
      (return-from server-end-session (values nil :not-found)))
    (let ((lock (handle-lock handle))
          (session (handle-session handle)))
      (bt:with-lock-held (lock)
        (bt:with-lock-held
            ((server-log-lock server (libactr:session-student-id session)))
          (prog1 (libactr:end-session session)
            (bt:with-lock-held ((server-students-lock server))
              (remhash session-id (server-sessions server)))))))))

(defun server-drop-session (server session-id)
  "Remove the session-handle registered under SESSION-ID WITHOUT ending the
underlying cognitive-session — no end-event is appended, the shared student
event log is untouched. Phase 14 A1 zombie convergence: a worker whose lease
lapsed and whose sessions were adopted away drops those stale local handles
so it can no longer step or checkpoint them (also usable for admin eviction).
Serialized under the server's students-lock. Returns SESSION-ID when a
handle was present and removed, nil otherwise."
  (bt:with-lock-held ((server-students-lock server))
    (when (gethash session-id (server-sessions server))
      (remhash session-id (server-sessions server))
      session-id)))

(defun server-student-mastery (server student-id)
  "Aggregate mastery for STUDENT-ID across all of that student's cognitive-
sessions from the shared student log. Returns a list of plists ((:kc <kc>
:correct <n> :total <n> :accuracy <float> :p-l <float>) ...), or
  (values nil :not-found)   ; unknown student-id
Threads the server's kt-params (Phase 9 Task 2) so per-KC BKT overrides reach
the mastery computation.

Concurrency + performance (reviews F1/F3/F4): the students lookup takes the
registry lock; the fold runs under the student's LOG lock (serialized against
the step path's appends to the same shared log) and maintains the per-student
INCREMENTAL BKT cache — only events appended since the last call are folded
(log-events-since); full replay via compute-mastery happens on first call, a
kt-params instance change, or a shrunken log. Results are identical to the
from-scratch fold by construction (see %fold-mastery-entries)."
  (let ((ss (bt:with-lock-held ((server-students-lock server))
              (gethash student-id (server-students server)))))
    (if (null ss)
        (values nil :not-found)
        (%student-mastery server student-id ss))))

(defun server-health (server)
  "Return a shallow health plist: liveness plus counter shape. (The HTTP layer
in Task 4 serializes this to JSON.) The registry counts are read under the
registry lock (review F1: hash-table-count on a table a request thread may be
mutating is an unlocked reader)."
  (bt:with-lock-held ((server-students-lock server))
    (list :status "ok"
          :active_sessions (hash-table-count (server-sessions server))
          :students (hash-table-count (server-students server)))))
