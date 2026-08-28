;;;; src/cluster.lisp — multi-worker orchestration (Phase 13, spec §4-5).
;;;; A cluster-manager is PER LOCAL SERVER (1:1): it owns the worker's redis
;;;; presence (join/heartbeat lease), the checkpoint scanner, and the takeover
;;;; scan. All mutable state lives on the instance (zero global mutable state);
;;;; the three loops are thin timer threads over SINGLE-STEPPABLE tick fns
;;;; (tests drive the ticks directly for determinism). The proxy (proxy.lisp)
;;;; shares this package. Composition only: no mtt/server or core file is
;;;; modified — takeover rebuilds sessions through exported APIs.
(defpackage :mtt/cluster
  (:use :cl)
  (:nicknames :mtt-cluster)
  (:export #:cluster-manager #:cluster-manager-p
           #:make-cluster-manager #:start-cluster-manager #:stop-cluster-manager
           #:cluster-server #:cluster-worker-id
           #:cluster-heartbeat-tick #:cluster-scan-tick #:cluster-takeover-tick
           #:cluster-live-workers #:cluster-adopt-session
           #:cluster-join #:cluster-leave #:cluster-threads
           #:cluster-route-get #:cluster-route-set
           #:checkpoint-store #:save-checkpoint #:load-checkpoint
           #:memory-checkpoint-store #:make-memory-checkpoint-store
           #:redis-checkpoint-store #:make-redis-checkpoint-store))
(in-package :mtt/cluster)

(defclass cluster-manager ()
  ((server             :reader cluster-server   :initarg :server)
   (worker-id          :reader cluster-worker-id :initarg :worker-id)
   (redis-host         :reader cluster-redis-host :initarg :redis-host :initform "127.0.0.1")
   (redis-port         :reader cluster-redis-port :initarg :redis-port :initform 6379)
   (prefix             :reader cluster-prefix   :initarg :prefix :initform "mtt:cluster:")
   (ttl                :reader cluster-ttl      :initarg :heartbeat-ttl :initform 15)
   (heartbeat-interval :reader cluster-heartbeat-interval :initarg :heartbeat-interval :initform 5)
   (scan-interval      :reader cluster-scan-interval :initarg :scan-interval :initform 2)
   (takeover-interval  :reader cluster-takeover-interval :initarg :takeover-interval :initform 5)
   (claim-ttl          :reader cluster-claim-ttl :initarg :claim-ttl :initform 30)
   (advertise-host     :reader cluster-advertise-host :initarg :advertise-host :initform "127.0.0.1")
   (store              :reader cluster-store :initarg :store :initform nil) ; Task 8
   (conn               :accessor cluster-conn :initform nil)
   ;; Controller-mandated (Task 7 review): cl-redis connections are
   ;; single-socket, not thread-safe — the three tick threads (heartbeat /
   ;; scan / takeover) multiplex this ONE connection, so all manager redis
   ;; use (lazy connect included) is serialized under this per-instance lock.
   (redis-lock         :reader cluster-redis-lock
                       :initform (bordeaux-threads:make-lock "cluster-redis"))
   (threads            :accessor cluster-threads :initform nil)
   (running            :accessor cluster-running :initform nil))
  (:documentation "Per-server orchestration state container (spec §4.2). All
state instance-held; zero global mutable state in this system."))

(defun cluster-manager-p (x) (typep x 'cluster-manager))

(defmacro with-cluster-redis ((m) &body body)
  "Ensure MANAGER's lazy cl-redis connection and dynamically bind
redis:*connection* to it for BODY (mirrors redis-store's with-redis — cl-redis
refuses to connect when *connection* is globally set, so each user rebinds).
BODY runs under the manager's redis LOCK: the three tick threads (heartbeat /
scan / takeover) multiplex this ONE connection, and cl-redis connections are
single-socket, not thread-safe — the lock serializes the lazy connect and
every command (controller-mandated, Task 7 review ruling)."
  (let ((mm (gensym)))
    `(let ((,mm ,m))
       (bordeaux-threads:with-lock-held ((cluster-redis-lock ,mm))
         (let* ((conn (or (cluster-conn ,mm)
                          (setf (cluster-conn ,mm)
                                (let ((redis:*connection* nil))
                                  (redis:connect :host (cluster-redis-host ,mm)
                                                 :port (cluster-redis-port ,mm)))))))
           (let ((redis:*connection* conn)) ,@body))))))

;; --- key layout (spec §5.1) -------------------------------------------------

(defun cluster-worker-key (m id)     (uiop:strcat (cluster-prefix m) "worker:" id))
(defun cluster-sess-key (m sid)      (uiop:strcat (cluster-prefix m) "sess:" sid))
(defun cluster-student-key (m id)    (uiop:strcat (cluster-prefix m) "student:" id))
(defun cluster-worker-sess-key (m id) (uiop:strcat (cluster-prefix m) "worker-sess:" id))
(defun cluster-claim-key (m sid)     (uiop:strcat (cluster-prefix m) "claim:" sid))

(defun worker-metadata-json (m)
  "The worker-key value: advertise host + the acceptor's ACTUAL bound port."
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "host" h) (cluster-advertise-host m)
          (gethash "port" h) (hunchentoot:acceptor-port
                              (mtt/server:server-acceptor (cluster-server m))))
    (with-output-to-string (s) (yason:encode h s))))

(defun cluster-heartbeat-tick (m)
  "One heartbeat: refresh this worker's lease key (SETEX = atomic set+ttl)."
  (with-cluster-redis (m)
    (redis:red-setex (cluster-worker-key m (cluster-worker-id m))
                     (cluster-ttl m)
                     (worker-metadata-json m))))

(defun cluster-join (m)
  "Register in the workers set + first heartbeat."
  (with-cluster-redis (m)
    (redis:red-sadd (uiop:strcat (cluster-prefix m) "workers") (cluster-worker-id m)))
  (cluster-heartbeat-tick m)
  m)

(defun cluster-leave (m)
  "Graceful leave: drop the lease key and registry entry. (Crash = lease
expires naturally — the takeover scan treats both identically, spec §5.2.)"
  (with-cluster-redis (m)
    (redis:red-del (cluster-worker-key m (cluster-worker-id m)))
    (redis:red-srem (uiop:strcat (cluster-prefix m) "workers") (cluster-worker-id m)))
  m)

(defun cluster-live-workers (m)
  "((id host port) ...) for every worker whose lease key exists."
  (with-cluster-redis (m)
    (loop :for id :in (redis:red-smembers (uiop:strcat (cluster-prefix m) "workers"))
          :for meta := (redis:red-get (cluster-worker-key m id))
          :when meta
            :collect (let ((a (yason:parse meta :object-as :alist)))
                       (list id
                             (cdr (assoc "host" a :test #'string=))
                             (cdr (assoc "port" a :test #'string=)))))))

;; --- checkpoint-store protocol (spec §5.1 ckpt:<sid>) ------------------------

(defgeneric save-checkpoint (store sid checkpoint)
  (:documentation "Persist CHECKPOINT (pure data from mtt:checkpoint-session)
under session-id SID, overwriting any previous one."))
(defgeneric load-checkpoint (store sid)
  (:documentation "Newest checkpoint for SID, or nil when none was saved."))

(defclass memory-checkpoint-store ()
  ((table :accessor memory-checkpoint-store-table :initform (make-hash-table :test 'equal)))
  (:documentation "In-memory checkpoint store (tests / single-process use)."))
(defun make-memory-checkpoint-store () (make-instance 'memory-checkpoint-store))
(defmethod save-checkpoint ((s memory-checkpoint-store) sid cp)
  (setf (gethash sid (memory-checkpoint-store-table s)) cp) s)
(defmethod load-checkpoint ((s memory-checkpoint-store) sid)
  (gethash sid (memory-checkpoint-store-table s)))

(defclass redis-checkpoint-store ()
  ((prefix :reader redis-checkpoint-store-prefix :initarg :prefix
           :initform "mtt:cluster:ckpt:")
   (host :reader redis-checkpoint-store-host :initarg :host :initform "127.0.0.1")
   (port :reader redis-checkpoint-store-port :initarg :port :initform 6379)
   (conn :accessor redis-checkpoint-store-conn :initform nil)
   ;; Controller-mandated (Task 7 review): cl-redis connections are
   ;; single-socket, not thread-safe — the scan thread (and Task 9's takeover)
   ;; multiplex this ONE connection, so all use is serialized under this lock.
   (lock :reader redis-checkpoint-store-lock
         :initform (bordeaux-threads:make-lock "cluster-store-redis")))
  (:documentation "Redis-backed checkpoint store. JSON via the Task-1 symbol
codec: explicit schema (spec §8 Interfaces) — top-level scalars, tagged status,
state as an ARRAY of {buffer isa slots[]} entries (buffer/slot names must keep
their packages, so they are VALUES not object keys), path as tagged array."))
(defun make-redis-checkpoint-store (&key (prefix "mtt:cluster:ckpt:")
                                    (host "127.0.0.1") (port 6379))
  (make-instance 'redis-checkpoint-store :prefix prefix :host host :port port))

(defmacro with-store-redis ((store) &body body)
  "Ensure STORE's lazy cl-redis connection and dynamically bind
redis:*connection* to it for BODY (mirrors with-cluster-redis). BODY runs
under the store's LOCK: the lazy connect AND every command are serialized —
cl-redis connections are single-socket, not thread-safe, and the scan thread
(Task 8) plus the takeover thread (Task 9) share this store's connection."
  (let ((st (gensym)))
    `(let ((,st ,store))
       (bordeaux-threads:with-lock-held ((redis-checkpoint-store-lock ,st))
         (let* ((conn (or (redis-checkpoint-store-conn ,st)
                          (setf (redis-checkpoint-store-conn ,st)
                                (let ((redis:*connection* nil))
                                  (redis:connect
                                   :host (redis-checkpoint-store-host ,st)
                                   :port (redis-checkpoint-store-port ,st)))))))
           (let ((redis:*connection* conn)) ,@body))))))

(defun %cp-hash (cp)
  "checkpoint plist -> yason-encodable hash-table (explicit schema walk;
symbols tagged via mtt:tag-symbols — numbers/strings pass through)."
  (let ((h (make-hash-table :test 'equal)))
    ;; [brief defect, run-evidenced: the brief encoded these keys via
    ;; (string-downcase (symbol-name k)) — hyphens ("session-id") — while the
    ;; spec §8 schema and the brief's own DECODER use underscores
    ;; ("session_id"), silently dropping all four scalar fields on the
    ;; round-trip. Encode the schema keys directly.]
    (dolist (k '(("session_id" . :session-id) ("student_id" . :student-id)
                 ("problem_id" . :problem-id) ("model_id" . :model-id)))
      (setf (gethash (car k) h) (mtt:tag-symbols (getf cp (cdr k)))))
    (setf (gethash "step_count" h) (or (getf cp :step-count) 0)
          (gethash "last_seq" h) (or (getf cp :last-seq) 0)
          (gethash "status" h) (mtt:tag-symbols (getf cp :status)))
    ;; :state entries are (buffer isa . slots-alist) — SBCL-probe verified:
    ;; serialize-buffer-state conses the buffer name onto serialize-chunk's
    ;; (isa . slots-alist) pair, so (car entry) = buffer, (cadr entry) = isa,
    ;; (cddr entry) = slots; a nil chunk yields the 1-element (buffer).
    (setf (gethash "state" h)
          (mapcar (lambda (entry)
                    (let ((ch (make-hash-table :test 'equal)))
                      (setf (gethash "buffer" ch) (mtt:tag-symbols (car entry)))
                      (when (cdr entry)
                        (setf (gethash "isa" ch) (mtt:tag-symbols (cadr entry))
                              (gethash "slots" ch)
                              (mapcar (lambda (cell)
                                        (let ((sh (make-hash-table :test 'equal)))
                                          (setf (gethash "slot" sh)
                                                (mtt:tag-symbols (car cell))
                                                (gethash "value" sh)
                                                (mtt:tag-symbols (cdr cell)))
                                          sh))
                                      (cddr entry))))
                      ch))
                  (getf cp :state)))
    (setf (gethash "path" h) (mapcar #'mtt:tag-symbols (getf cp :path)))
    h))

(defun %json-checkpoint (json)
  "yason-parsed (alist) tree -> checkpoint plist (inverse schema walk).
[deviation from brief, probe-verified: the brief applied mtt:untag-symbols to
the WHOLE parsed tree, but yason's :object-as :alist entries are dotted
(key . scalar) pairs — improper lists — and untag-symbols' cons branch mapcars
proper lists only, so the whole-tree walk signals TYPE-ERROR on the first
scalar field (\"session_id\" . \"s1\"). untag is applied at the LEAF value
subtrees instead — the same discipline as redis-store's decode-row: tag alists
intern, arrays of tags map to lists, scalars pass through.]"
  (flet ((ag (key alist) (cdr (assoc key alist :test #'string=)))
         (un (x) (mtt:untag-symbols x)))
    (list :session-id (un (ag "session_id" json))
          :student-id (un (ag "student_id" json))
          :problem-id (un (ag "problem_id" json))
          :model-id   (un (ag "model_id" json))
          :step-count (or (ag "step_count" json) 0)
          :status     (un (ag "status" json))
          :last-seq   (or (ag "last_seq" json) 0)
          :state      (map 'list
                           (lambda (e)
                             (cons (un (ag "buffer" e))
                                   (when (assoc "isa" e :test #'string=)
                                     (cons (un (ag "isa" e))
                                           (map 'list
                                                (lambda (sc)
                                                  (cons (un (ag "slot" sc))
                                                        (un (ag "value" sc))))
                                                (ag "slots" e))))))
                           (ag "state" json))
          :path       (un (ag "path" json)))))

(defmethod save-checkpoint ((s redis-checkpoint-store) sid cp)
  (with-store-redis (s)
    (redis:red-set (uiop:strcat (redis-checkpoint-store-prefix s) sid)
                   (with-output-to-string (out)
                     (yason:encode (%cp-hash cp) out)))
    s))

(defmethod load-checkpoint ((s redis-checkpoint-store) sid)
  (with-store-redis (s)
    (let ((json (redis:red-get (uiop:strcat (redis-checkpoint-store-prefix s) sid))))
      (and json (%json-checkpoint (yason:parse json :object-as :alist))))))

;; --- scan tick (spec §5.2 protocol 3): checkpoint + reverse-index reconcile --

(defun cluster-scan-tick (m)
  "One scan pass over the LOCAL server's active sessions: snapshot each under
its session lock (consistent state, no step-hot-path cost) into the
checkpoint store; then reconcile the worker-sess reverse index (sids no
longer local -> SREM + drop the sess route). Returns (values checked
dropped)."
  (let ((checked 0) (dropped 0) (seen nil))
    ;; [deviation from brief, one paren: the brief's maphash form was one
    ;; close short (lambda never closed -> maphash swallowed the following
    ;; with-cluster-redis form as a third argument); same class of defect as
    ;; Task 7's fixture tail.]
    (maphash (lambda (sid handle)
               (push sid seen)
               (incf checked)
               ;; double parens: with-lock-held's lock clause takes ONE form
               ;; (bordeaux apiv2 (place &key timeout)); a reader call is that
               ;; one form [brief defect — brief used single parens].
               (bordeaux-threads:with-lock-held ((mtt/server:handle-lock handle))
                 (save-checkpoint (cluster-store m) sid
                                  (mtt:checkpoint-session
                                   (mtt/server:handle-session handle)))))
             (mtt/server:server-sessions (cluster-server m)))
    (with-cluster-redis (m)
      (let ((key (cluster-worker-sess-key m (cluster-worker-id m))))
        (dolist (sid (redis:red-smembers key))
          (unless (member sid seen :test #'string=)
            (incf dropped)
            (redis:red-srem key sid)
            (redis:red-del (cluster-sess-key m sid))))))
    (values checked dropped)))

;; --- routes (shared with proxy.lisp; *connection* must be bound) -----------

(defun cluster-route-get (key)
  "Route table read: (values worker-id epoch) for a sess:/student: hash key,
nil when unrouted. [brief defect, run-evidenced: the brief parse-integer'd the
epoch field unconditionally — TYPE-ERROR on parse-integer's STRING parameter
when the hash carries only the worker field (the pre-takeover shape the tests
seed); a missing/garbled epoch reads as 0, the same default route-set's
HINCRBY counts up from.]"
  (let ((w (redis:red-hget key "worker")))
    (when w
      (let ((e (redis:red-hget key "epoch")))
        (values w (if e (or (parse-integer e :junk-allowed t) 0) 0))))))

(defun cluster-route-set (key worker-id)
  "Point KEY at WORKER-ID and bump its epoch (the future-fencing counter,
spec §5.5)."
  (redis:red-hset key "worker" worker-id)
  (redis:red-hincrby key "epoch" 1)
  worker-id)

;; --- takeover (spec §5.2 protocol 4) -----------------------------------------

(defun cluster-adopt-session (m sid checkpoint dead-worker)
  "Rebuild the session locally from CHECKPOINT and flip the routes to this
worker. Composition of exported core/server APIs only (spec §4.1): the
student's redis event log continues where the dead worker left it."
  (let* ((server (cluster-server m))
         (model-id (getf checkpoint :model-id))
         (entry (gethash model-id (mtt/server:server-models server))))
    (unless entry
      (error "mtt/cluster: takeover of ~a needs model ~a registered locally"
             sid model-id))
    (let* ((model (car entry))
           (adapter (cdr entry))
           (student-id (getf checkpoint :student-id))
           (log (mtt:make-redis-event-log
                 :key (format nil "mtt:student:~a:events" student-id)
                 :host (cluster-redis-host m) :port (cluster-redis-port m)))
           (session (mtt:restore-from-checkpoint checkpoint model log)))
      (setf (gethash sid (mtt/server:server-sessions server))
            (make-instance 'mtt/server:session-handle
                           :session session
                           :lock (bordeaux-threads:make-lock
                                  (format nil "session-~a" sid))
                           :adapter adapter))
      (with-cluster-redis (m)
        (cluster-route-set (cluster-sess-key m sid) (cluster-worker-id m))
        (cluster-route-set (cluster-student-key m student-id) (cluster-worker-id m))
        (redis:red-srem (cluster-worker-sess-key m dead-worker) sid)
        (redis:red-sadd (cluster-worker-sess-key m (cluster-worker-id m)) sid)
        (redis:red-del (cluster-claim-key m sid)))
      sid)))

(defun cluster-takeover-tick (m)
  "One takeover scan: find workers in the registry whose lease key has
expired (simulated cleanly by a DEL in tests — what TTL expiry does), then for
each sid in their reverse index: atomically claim (SETNX+EXPIRE), skip on a
local sid collision (warning), skip when no checkpoint exists (route stays —
the proxy 503s and the client restarts), else adopt. Returns (values taken
dead-worker-ids).

[deviation from brief, lock-discipline-mandated (Task 8 ruling): the brief
wrapped the whole tick in ONE with-cluster-redis and called
cluster-adopt-session — which opens its own — inside it: bordeaux locks are
non-recursive, guaranteed self-deadlock; it also nested the store lock
(load-checkpoint) inside the manager lock. Same commands, re-sequenced: the
manager lock is taken in SHORT scopes (dead-list, per-sid claim, per-sid
claim-drop) and the store lock only for load-checkpoint, always released
before adopt's own manager-lock scope — never nested (the scan tick already
sequences store-then-manager the same way).]"
  (labels ((claim (sid)
             (with-cluster-redis (m)
               (and (redis:red-setnx (cluster-claim-key m sid) (cluster-worker-id m))
                    (redis:red-expire (cluster-claim-key m sid) (cluster-claim-ttl m)))))
           (drop-claim (sid)
             (with-cluster-redis (m)
               (redis:red-del (cluster-claim-key m sid)))))
    (let* ((dead (with-cluster-redis (m)
                   (loop :for id :in (redis:red-smembers
                                      (uiop:strcat (cluster-prefix m) "workers"))
                         :unless (or (string= id (cluster-worker-id m))
                                     (redis:red-exists (cluster-worker-key m id)))
                           :collect id)))
           (taken 0))
      (dolist (w dead)
        (dolist (sid (with-cluster-redis (m)
                       (redis:red-smembers (cluster-worker-sess-key m w))))
          (when (claim sid)
            (cond
              ;; local sid already live (cross-process gensym collision): skip
              ((gethash sid (mtt/server:server-sessions (cluster-server m)))
               (format *error-output*
                       "mtt/cluster: takeover of ~a skipped — sid already live locally (cross-process gensym collision? spec §13.1)~%" sid)
               (drop-claim sid))
              (t (let ((cp (load-checkpoint (cluster-store m) sid)))  ; store lock
                   (cond
                     (cp (cluster-adopt-session m sid cp w) (incf taken))
                     (t (drop-claim sid)))))))))       ; no-ckpt window
      (values taken dead))))

;; --- thread lifecycle (thin timers over the tick fns) ------------------------

(defun %tick-loop (m tick interval)
  (loop :while (cluster-running m)
        :do (ignore-errors (funcall tick m))
            (sleep interval)))

(defun make-cluster-manager (&key server worker-id redis-host redis-port
                             (prefix "mtt:cluster:") (heartbeat-ttl 15)
                             (heartbeat-interval 5) (scan-interval 2)
                             (takeover-interval 5) (claim-ttl 30)
                             (advertise-host "127.0.0.1") store)
  "STORE defaults to a redis checkpoint store on the manager's own redis
(prefix + \"ckpt:\") — the scan tick persists checkpoints there (spec §5.1)."
  (let ((store* (or store
                    (make-redis-checkpoint-store
                     :prefix (uiop:strcat prefix "ckpt:")
                     :host (or redis-host "127.0.0.1")
                     :port (or redis-port 6379)))))
    (make-instance 'cluster-manager
                   :server server :worker-id worker-id
                   :redis-host redis-host :redis-port redis-port :prefix prefix
                   :heartbeat-ttl heartbeat-ttl :heartbeat-interval heartbeat-interval
                   :scan-interval scan-interval :takeover-interval takeover-interval
                   :claim-ttl claim-ttl :advertise-host advertise-host
                   :store store*)))

(defun start-cluster-manager (m)
  "Join the registry and spawn the three tick threads (heartbeat / scan /
takeover). The threads are plain drivers over the single-steppable ticks."
  (setf (cluster-running m) t
        (cluster-threads m)
        (list (bordeaux-threads:make-thread
               (lambda () (%tick-loop m #'cluster-heartbeat-tick
                                      (cluster-heartbeat-interval m)))
               :name (uiop:strcat "cluster-heartbeat-" (cluster-worker-id m)))
              (bordeaux-threads:make-thread
               (lambda () (%tick-loop m #'cluster-scan-tick (cluster-scan-interval m)))
               :name (uiop:strcat "cluster-scan-" (cluster-worker-id m)))
              (bordeaux-threads:make-thread
               (lambda () (%tick-loop m #'cluster-takeover-tick
                                      (cluster-takeover-interval m)))
               :name (uiop:strcat "cluster-takeover-" (cluster-worker-id m)))))
  (cluster-join m)
  m)

(defun stop-cluster-manager (m)
  "Stop the tick threads (they observe the running flag within one interval),
gracefully leave, disconnect redis — the MANAGER's connection and the default
store's (controller-mandated, Task 8 review ruling: the store holds its own
lazy redis conn that would otherwise outlive the manager). Safe to call
multiple times."
  (setf (cluster-running m) nil)
  (dolist (th (cluster-threads m))
    (ignore-errors (bordeaux-threads:destroy-thread th)))
  (setf (cluster-threads m) nil)
  (ignore-errors (cluster-leave m))
  (when (cluster-conn m)
    (let ((redis:*connection* (cluster-conn m)))
      (ignore-errors (redis:disconnect)))
    (setf (cluster-conn m) nil))
  ;; Controller-mandated (Task 8 review ruling): disconnect the store's own
  ;; lazy conn — guarded (only a redis-checkpoint-store with an open conn),
  ;; under the STORE's lock (the same single-socket serialization
  ;; with-store-redis applies), idempotent (conn slot nil'ed).
  (let ((store (cluster-store m)))
    (when (typep store 'redis-checkpoint-store)
      (bordeaux-threads:with-lock-held ((redis-checkpoint-store-lock store))
        (when (redis-checkpoint-store-conn store)
          (let ((redis:*connection* (redis-checkpoint-store-conn store)))
            (ignore-errors (redis:disconnect)))
          (setf (redis-checkpoint-store-conn store) nil)))))
  m)
