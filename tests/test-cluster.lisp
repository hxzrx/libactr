;;;; tests/test-cluster.lisp — mtt/cluster in-process semantics (Phase 13).
;;;; Suite :mtt/cluster (also joined by test-cluster-e2e.lisp). Self-starts a
;;;; redis-server (SKIP if the binary is missing); ticks are driven DIRECTLY
;;;; for determinism — the timer threads are only smoke-tested once.
(defpackage :mtt/cluster-test
  (:use :cl :5am :mtt :mtt/cluster :mtt/server))
(in-package :mtt/cluster-test)

(def-suite :mtt/cluster :description "multi-worker orchestration")
(in-suite :mtt/cluster)

(defparameter *redis-server-candidates*
  '("/usr/sbin/redis-server" "/usr/local/sbin/redis-server" "/usr/bin/redis-server"))

(defun %find-free-port ()
  (let ((sock (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (unwind-protect (usocket:get-local-port sock) (usocket:socket-close sock))))

(defun %redis-server-binary ()
  (find-if #'probe-file *redis-server-candidates*))

(defun %unique-dir (prefix)
  (format nil "/tmp/~a-~a-~a/" prefix (get-universal-time) (gensym)))

(defmacro with-test-redis ((conn-var port-var) &body body)
  "Disposable redis-server on a free port + fresh connection; FLUSHDB; cleanup
  after (mirror of tests/test-redis-store.lisp's fixture — test packages stay
  decoupled, no cross-package import)."
  (let ((dir (gensym)) (port (gensym)))
    `(if (null (%redis-server-binary))
         (5am:skip "no redis-server binary found")
         (let ((,port (%find-free-port))
               (,dir (%unique-dir "mtt-cluster")))
           (ensure-directories-exist ,dir)
           (uiop:run-program (list (%redis-server-binary)
                                   "--port" (princ-to-string ,port)
                                   "--daemonize" "yes" "--appendonly" "yes"
                                   "--dir" ,dir "--save" ""
                                   "--logfile" (format nil "~a/redis.log" ,dir))
                             :output :string :error-output :string)
           (sleep 1)
           (let ((,conn-var (redis:connect :host "127.0.0.1" :port ,port))
                 (,port-var ,port))
             ;; NOTE: unlike test-redis-store.lisp's fixture (which binds
             ;; *connection* only for the FLUSHDB), we bind it for the WHOLE
             ;; body — the cluster tests make bare redis:red-* assertions.
             (let ((redis:*connection* ,conn-var))
               (redis:red-flushdb)
               (unwind-protect (progn ,@body)
                 (ignore-errors (redis:disconnect))
               (ignore-errors
                 (uiop:run-program (list "redis-cli" "-p" (princ-to-string ,port)
                                         "shutdown" "nosave")
                                   :output :string :error-output :string))
               (sleep 1)
               ;; [deviation from brief: brief's tail has 8 close parens — one
               ;; short (defmacro would run to EOF; COMPILE-FILE-ERROR "end of
               ;; file"). The whole-body *connection* let adds a nesting level
               ;; over the redis-store fixture; tail needs 9.]
               (ignore-errors (uiop:delete-directory-tree ,dir :validate t)))))))))

(defun %worker-server (redis-port)
  "A subtraction-registered tutor-server with a live acceptor + redis event
logs (the cluster deployment shape, spec §5.4)."
  (let ((s (start-tutor-server :port (%find-free-port) :start-acceptor-p t
                               :redis-config (list :host "127.0.0.1"
                                                   :port redis-port))))
    (register-model s "sub"
                    (mtt/subtraction-adapter:build-subtraction-model)
                    (mtt/subtraction-adapter:make-subtraction-adapter))
    s))

(test cluster.heartbeat-refreshes-lease
  (with-test-redis (conn port)
    (let* ((s (%worker-server port))
           (m (make-cluster-manager :server s :worker-id "w1"
                                    :redis-host "127.0.0.1" :redis-port port
                                    :prefix "t-hb:")))
      (unwind-protect
           (progn
             (cluster-join m)
             (is (redis:red-exists "t-hb:worker:w1"))
             (is (find "w1" (redis:red-smembers "t-hb:workers") :test #'string=))
             ;; [deviation from brief: the seed SETEX is ADDED (assertion below
             ;; kept verbatim). As written, the brief's Step-5 probe (setex→set
             ;; in the tick) leaves the >= assertion GREEN vacuously: join uses
             ;; the same tick, so `before` is also -1 (-1 >= -1); same blind
             ;; spot under a no-op stub (-2 >= -2, both observed). Seeding the
             ;; lease from the TEST makes before a positive ttl independent of
             ;; the tick fn, so a no-ttl refresh reads -1 and -1 >= 15 is RED —
             ;; the brief's own predicted mechanism.]
             (let ((before (progn (redis:red-setex "t-hb:worker:w1" 15 "seed") ; 15 = default heartbeat-ttl
                                  (redis:red-ttl "t-hb:worker:w1"))))
               (sleep 1.2)
               (cluster-heartbeat-tick m)
               (is (>= (redis:red-ttl "t-hb:worker:w1") before)))   ; lease refreshed
             ;; live-workers sees (id host port)
             (let ((live (cluster-live-workers m)))
               (is (= 1 (length live)))
               (is (string= "w1" (first (first live))))
               (is (integerp (third (first live))))))
        (stop-cluster-manager m)
        (stop-tutor-server s)))))

(test cluster.lease-expiry-removes-liveness
  "Simulated death: DEL the lease key (what TTL expiry does); live-workers
drops the worker even though it is still in the registry set."
  (with-test-redis (conn port)
    (let* ((s (%worker-server port))
           (m (make-cluster-manager :server s :worker-id "w1"
                                    :redis-host "127.0.0.1" :redis-port port
                                    :prefix "t-exp:")))
      (unwind-protect
           (progn
             (cluster-join m)
             (is (= 1 (length (cluster-live-workers m))))
             (redis:red-del "t-exp:worker:w1")          ; simulated TTL expiry
             (is (null (cluster-live-workers m)))
             (is (find "w1" (redis:red-smembers "t-exp:workers") :test #'string=)))
        (stop-cluster-manager m)
        (stop-tutor-server s)))))

(test cluster.thread-smoke-and-stop
  "start-cluster-manager spawns the three tick threads and joins; after ~2
heartbeats the lease exists; stop-cluster-manager leaves (registry empty)."
  :skipped-if (lambda () (null (%redis-server-binary)))
  (with-test-redis (conn port)
    (let* ((s (%worker-server port))
           (m (make-cluster-manager :server s :worker-id "w9"
                                    :redis-host "127.0.0.1" :redis-port port
                                    :prefix "t-thr:" :heartbeat-interval 0.2)))
      (unwind-protect
           (progn
             (start-cluster-manager m)
             (is (= 3 (length (cluster-threads m))))
             (sleep 0.7)
             (is (redis:red-exists "t-thr:worker:w9")))
        (stop-cluster-manager m)
        (stop-tutor-server s))
      (is (null (find "w9" (redis:red-smembers "t-thr:workers") :test #'string=))))))
