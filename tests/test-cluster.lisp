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

(test cluster.checkpoint-store-round-trips-symbols
  "The redis checkpoint store round-trips a real checkpoint-session plist with
SYMBOL fidelity (buffer names, chunk isa/slot names in the model package, path
production names) — the Task-1 codec reused (spec §7)."
  (with-test-redis (conn port)
    (let* ((s (%worker-server port))
           (store (make-redis-checkpoint-store :prefix "t-ck:" :host "127.0.0.1" :port port)))
      (unwind-protect
           (let* ((sid (server-start-session s "cs" "52-18" "sub"))
                  (session (handle-session (gethash sid (server-sessions s))))
                  (cp (checkpoint-session session)))
             ;; drive one correct borrow step so state/path are non-trivial
             (server-step-session s sid '(("type" . "digit") ("value" . "4")))
             (setf cp (checkpoint-session session))
             (save-checkpoint store sid cp)
             (let ((back (load-checkpoint store sid)))
               (is (string= sid (getf back :session-id)))
               (is (string= "52-18" (getf back :problem-id)))
               (is (string= "sub" (getf back :model-id)))
               (is (eq :active (getf back :status)))
               ;; state: buffer name is the model-package GOAL symbol
               (let ((goal-entry (find "GOAL" (getf back :state)
                                       :key (lambda (e) (symbol-name (car e)))
                                       :test #'string=)))
                 (is (and goal-entry t))
                 (is (eq (find-symbol "GOAL" :mtt/subtraction-tutor) (car goal-entry)))
                 ;; chunk isa is the model-package SUB2 symbol
                 (is (eq (find-symbol "SUB2" :mtt/subtraction-tutor)
                         (car (cdr goal-entry)))))
               ;; path: production-name symbols in the model package
               ;; [brief defect, run-evidenced: the brief compared a keyword
               ;; SYMBOL to the PACKAGE object ((eq :mtt/subtraction-tutor
               ;; (symbol-package p)) — never true); resolve the designator
               ;; with find-package, mirroring the find-symbol form above.]
               (is (every (lambda (p) (eq (find-package :mtt/subtraction-tutor)
                                          (symbol-package p)))
                          (getf back :path)))))
        (stop-tutor-server s)))))

(test cluster.scan-tick-checkpoints-active-sessions
  "One scan pass: the local active session gains a ckpt:<sid> entry under the
manager's prefix; a second pass after end (handle gone) reconciles
worker-sess (SREM) and drops sess:<sid>."
  (with-test-redis (conn port)
    (let* ((s (%worker-server port))
           (m (make-cluster-manager :server s :worker-id "w1"
                                    :redis-host "127.0.0.1" :redis-port port
                                    :prefix "t-scan:")))
      (unwind-protect
           (let ((sid (server-start-session s "cs2" "52-18" "sub")))
             (server-step-session s sid '(("type" . "digit") ("value" . "4")))
             ;; simulate what the proxy writes at start (Task 10 owns the real
             ;; writer; scan reconciles the reverse index either way)
             (redis:red-sadd "t-scan:worker-sess:w1" sid)
             (redis:red-hset (uiop:strcat "t-scan:sess:" sid) "worker" "w1")
             (multiple-value-bind (checked dropped) (cluster-scan-tick m)
               (declare (ignore dropped))
               (is (= 1 checked))
               (is (redis:red-exists (uiop:strcat "t-scan:ckpt:" sid))))
             ;; end the session -> handle removed -> next pass reconciles
             (server-end-session s sid)
             (multiple-value-bind (checked2 dropped2) (cluster-scan-tick m)
               (is (= 0 checked2))
               (is (= 1 dropped2))
               (is (null (redis:red-smembers "t-scan:worker-sess:w1")))
               (is (null (redis:red-exists (uiop:strcat "t-scan:sess:" sid))))))
        (stop-cluster-manager m)
        (stop-tutor-server s)))))

(test cluster.memory-checkpoint-store
  "The in-memory store (same protocol) saves/loads/overwrites without redis."
  (let ((store (make-memory-checkpoint-store))
        (cp (list :session-id "s1" :student-id "st" :problem-id "p" :model-id "m"
                  :step-count 2 :status :active :last-seq 4 :state nil
                  :path (list 'a 'b))))
    (is (null (load-checkpoint store "s1")))
    (save-checkpoint store "s1" cp)
    (is (equalp cp (load-checkpoint store "s1")))
    (save-checkpoint store "s1" (list :session-id "s1" :step-count 3))
    (is (= 3 (getf (load-checkpoint store "s1") :step-count)))))

;;; --- Task 9: takeover tick + adopt ------------------------------------------

;; [brief defect, run-evidenced: the fixture opened its OWN with-test-redis,
;; but every caller already sits inside one — cl-redis's connect refuses an
;; open *connection* ("A connection to Redis server is already established"),
;; and even if it didn't, the nested fixture would start a SECOND redis-server
;; putting its data where the caller's bare red-* assertions never look. The
;; fixture reuses the CALLER's redis (port passed in) — one server, exactly
;; the single-server semantics the tests assert.]
(defun %dead-worker-scenario (port prefix)
  "Shared shape (run inside the caller's with-test-redis): server+manager w1
with one mid-problem session (ones borrow step done, checkpoint saved), then
w1's lease is deleted (simulated death). Returns (values s1 m1 s2 m2 sid)."
  (let* ((s1 (%worker-server port))
         (m1 (make-cluster-manager :server s1 :worker-id "w1"
                                   :redis-host "127.0.0.1" :redis-port port
                                   :prefix prefix))
         (sid (progn (cluster-join m1)
                     (let ((sid (server-start-session s1 "tk" "52-18" "sub")))
                       (server-step-session s1 sid '(("type" . "digit") ("value" . "4")))
                       (cluster-scan-tick m1)          ; checkpoint saved
                       (redis:red-hset (uiop:strcat prefix "sess:" sid) "worker" "w1")
                       (redis:red-sadd (uiop:strcat prefix "worker-sess:w1") sid)
                       sid)))
         (s2 (%worker-server port))
         (m2 (make-cluster-manager :server s2 :worker-id "w2"
                                   :redis-host "127.0.0.1" :redis-port port
                                   :prefix prefix)))
    (redis:red-del (uiop:strcat prefix "worker:w1"))   ; simulated death
    (values s1 m1 s2 m2 sid)))

(test cluster.takeover-rebuilds-and-continues
  "w1 dies mid-problem (borrow ones done, checkpointed). w2's takeover tick
claims, rebuilds from the checkpoint (same sid), flips both routes, and the
session CONTINUES on w2 to completion; mastery replays from the shared redis
log losslessly."
  (with-test-redis (conn port)
    (multiple-value-bind (s1 m1 s2 m2 sid) (%dead-worker-scenario port "t-tk:")
      (unwind-protect
           (progn
             (multiple-value-bind (taken dead) (cluster-takeover-tick m2)
               (is (= 1 taken))
               (is (equal '("w1") dead)))
             ;; routes flipped to w2 with epoch >= 1
             (multiple-value-bind (w epoch) (cluster-route-get (uiop:strcat "t-tk:sess:" sid))
               (is (string= "w2" w)) (is (>= epoch 1)))
             ;; [brief defect, probe-evidenced: getf is a PROPERTY-LIST
             ;; accessor — (getf '("w2" 1) 0) is NIL, so the brief's four
             ;; route assertions were permanently red even under a correct
             ;; implementation. first on the multiple-value list instead.]
             (is (string= "w2" (first (multiple-value-list
                                      (cluster-route-get
                                       (uiop:strcat "t-tk:student:tk"))))))
             ;; handle registered locally on w2, same sid
             (is (gethash sid (server-sessions s2)))
             ;; continue: tens digit -> done
             (let ((r (nth-value 0 (server-step-session
                                    s2 sid '(("type" . "digit") ("value" . "3"))))))
               (is (eq :on-path (mtt:trace-result-status r)))
               (is (string= "SUBTRACT-TENS-DIRECT"
                            (symbol-name (mtt:production-name
                                          (mtt:trace-result-production r))))))
             ;; mastery replay: the redis log holds both workers' events
             (let ((mastery (mtt:compute-mastery
                             (mtt:log-all-events
                              (mtt:make-redis-event-log
                               :key "mtt:student:tk:events"
                               :host "127.0.0.1" :port port)))))
               (is (member :borrow (mapcar (lambda (x) (getf x :kc)) mastery)))))
        (stop-cluster-manager m1)
        (stop-cluster-manager m2)
        (stop-tutor-server s1)
        (stop-tutor-server s2)))))

(test cluster.claim-mutex-blocks-second-taker
  "A pre-set claim key (another taker won the SETNX) -> takeover skips the
sid entirely: no local handle, routes untouched."
  (with-test-redis (conn port)
    (multiple-value-bind (s1 m1 s2 m2 sid) (%dead-worker-scenario port "t-cl:")
      (unwind-protect
           (progn
             (redis:red-set (uiop:strcat "t-cl:claim:" sid) "someone-else")
             (redis:red-expire (uiop:strcat "t-cl:claim:" sid) 30)
             (multiple-value-bind (taken dead) (cluster-takeover-tick m2)
               (is (= 0 taken))
               (is (equal '("w1") dead)))
             (is (null (gethash sid (server-sessions s2))))
             (is (string= "w1" (first (multiple-value-list
                                      (cluster-route-get
                                       (uiop:strcat "t-cl:sess:" sid)))))))
        (stop-cluster-manager m1)
        (stop-cluster-manager m2)
        (stop-tutor-server s1)
        (stop-tutor-server s2)))))

(test cluster.no-checkpoint-leaves-route-alone
  "A dead worker's sid with NO checkpoint (died before the first scan) is not
adopted: no claim residue, routes untouched (the proxy will 503 and the
client restarts — spec §5.2 protocol 4)."
  (with-test-redis (conn port)
    (multiple-value-bind (s1 m1 s2 m2 sid) (%dead-worker-scenario port "t-nc:")
      (unwind-protect
           (progn
             (redis:red-del (uiop:strcat "t-nc:ckpt:" sid))   ; no checkpoint
             (multiple-value-bind (taken dead) (cluster-takeover-tick m2)
               (is (= 0 taken))
               (is (equal '("w1") dead)))
             (is (null (gethash sid (server-sessions s2))))
             (is (string= "w1" (first (multiple-value-list
                                      (cluster-route-get
                                       (uiop:strcat "t-nc:sess:" sid))))))
             (is (null (redis:red-exists (uiop:strcat "t-nc:claim:" sid)))))
        (stop-cluster-manager m1)
        (stop-cluster-manager m2)
        (stop-tutor-server s1)
        (stop-tutor-server s2)))))

(test cluster.local-sid-collision-skips
  "If the taker already holds a DIFFERENT live session under the same sid
(the cross-process gensym-collision guard, spec §13.1), adoption is skipped
with a warning; the local session is untouched."
  (with-test-redis (conn port)
    (multiple-value-bind (s1 m1 s2 m2 sid) (%dead-worker-scenario port "t-co:")
      (unwind-protect
           (progn
             ;; plant a fake local session under the same sid on w2
             (setf (gethash sid (server-sessions s2))
                   (make-instance 'session-handle
                                  :session (server-start-session s2 "local" "47-25" "sub")
                                  :lock (bordeaux-threads:make-lock "fake")
                                  :adapter (cdr (gethash "sub" (server-models s2)))))
             (multiple-value-bind (taken dead) (cluster-takeover-tick m2)
               (is (= 0 taken))
               (is (equal '("w1") dead)))
             ;; routes untouched
             (is (string= "w1" (first (multiple-value-list
                                      (cluster-route-get
                                       (uiop:strcat "t-co:sess:" sid)))))))
        (stop-cluster-manager m1)
        (stop-cluster-manager m2)
        (stop-tutor-server s1)
        (stop-tutor-server s2)))))
