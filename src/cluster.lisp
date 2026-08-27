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
   (threads            :accessor cluster-threads :initform nil)
   (running            :accessor cluster-running :initform nil))
  (:documentation "Per-server orchestration state container (spec §4.2). All
state instance-held; zero global mutable state in this system."))

(defun cluster-manager-p (x) (typep x 'cluster-manager))

(defmacro with-cluster-redis ((m) &body body)
  "Ensure MANAGER's lazy cl-redis connection and dynamically bind
redis:*connection* to it for BODY (mirrors redis-store's with-redis — cl-redis
refuses to connect when *connection* is globally set, so each user rebinds)."
  (let ((mm (gensym)))
    `(let* ((,mm ,m)
            (conn (or (cluster-conn ,mm)
                      (setf (cluster-conn ,mm)
                            (let ((redis:*connection* nil))
                              (redis:connect :host (cluster-redis-host ,mm)
                                             :port (cluster-redis-port ,mm)))))))
       (let ((redis:*connection* conn)) ,@body))))

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

;; --- scan / takeover ticks: Task 8/9 fill these in (no-op stubs for now) ----

(defun cluster-scan-tick (m) (declare (ignore m)) (values 0 nil))
(defun cluster-takeover-tick (m) (declare (ignore m)) (values 0 nil))

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
  (make-instance 'cluster-manager
                 :server server :worker-id worker-id
                 :redis-host redis-host :redis-port redis-port :prefix prefix
                 :heartbeat-ttl heartbeat-ttl :heartbeat-interval heartbeat-interval
                 :scan-interval scan-interval :takeover-interval takeover-interval
                 :claim-ttl claim-ttl :advertise-host advertise-host :store store))

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
gracefully leave, disconnect redis. Safe to call multiple times."
  (setf (cluster-running m) nil)
  (dolist (th (cluster-threads m))
    (ignore-errors (bordeaux-threads:destroy-thread th)))
  (setf (cluster-threads m) nil)
  (ignore-errors (cluster-leave m))
  (when (cluster-conn m)
    (let ((redis:*connection* (cluster-conn m)))
      (ignore-errors (redis:disconnect)))
    (setf (cluster-conn m) nil))
  m)
