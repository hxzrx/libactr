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
  ;; No trailing slash (final review): callers append "/redis.log" etc. and the
  ;; delete-directory-tree call site coerces via ensure-directory-pathname (a
  ;; slashless STRING alone still fails UIOP's pathnamep gate — see fixture).
  (format nil "/tmp/~a-~a-~a" prefix (get-universal-time) (gensym)))

(defmacro with-test-redis ((conn-var port-var) &body body)
  "Disposable redis-server on a free port + fresh connection; FLUSHDB; cleanup
  after (mirror of tests/test-redis-store.lisp's fixture — test packages stay
  decoupled, no cross-package import)."
  (let ((dir (gensym)) (port (gensym)))
    `(if (null (%redis-server-binary))
         (5am:skip "no redis-server binary found")
         (let ((,port (%find-free-port))
               (,dir (%unique-dir "mtt-cluster")))
           ;; ensure-directory-pathname: a slashless namestring's last component
           ;; parses as a NAME, and ensure-directories-exist would not create it.
           (ensure-directories-exist (uiop:ensure-directory-pathname ,dir))
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
               ;; ensure-directory-pathname (final review): delete-directory-tree
               ;; takes a physical non-wildcard directory PATHNAME — a namestring
               ;; (slash or not) fails its pathnamep gate and the ignore-errors
               ;; silently skipped cleanup, leaking /tmp/mtt-cluster-* dirs.
               (ignore-errors (uiop:delete-directory-tree
                               (uiop:ensure-directory-pathname ,dir) :validate t)))))))))

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

(test cluster.claim-crash-residue-reclaimed
  "REGRESSION (final review, crash gap): a taker that died between SETNX and
EXPIRE leaves a claim with NO TTL. Pre-fix, SETNX fails for every future taker
and this sid's takeover is blocked forever; post-fix the losing path reclaims a
TTL-less (red-ttl = -1) residue once, retries the claim, and adopts. A residue
WITH a TTL still blocks (the mutex semantics claim-mutex tests above)."
  (with-test-redis (conn port)
    (multiple-value-bind (s1 m1 s2 m2 sid) (%dead-worker-scenario port "t-cr:")
      (unwind-protect
           (progn
             ;; crash residue: plain SET, NO expire (red-ttl reads -1)
             (redis:red-set (uiop:strcat "t-cr:claim:" sid) "crashed-taker")
             (multiple-value-bind (taken dead) (cluster-takeover-tick m2)
               (is (= 1 taken))
               (is (equal '("w1") dead)))
             ;; adopted: handle local, route flipped, claim consumed
             (is (gethash sid (server-sessions s2)))
             (is (string= "w2" (first (multiple-value-list
                                      (cluster-route-get
                                       (uiop:strcat "t-cr:sess:" sid))))))
             (is (null (redis:red-exists (uiop:strcat "t-cr:claim:" sid)))))
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

;;; --- Phase 14 A1: zombie self-check -----------------------------------------
;; [brief defect, reader-evidenced (COMPILE-FILE "unmatched close parenthesis",
;; line 429 col 34) + task-4 review round 1: each test's extra paren sits on
;; the LAST-ASSERTION line, not the tail — its 5th close would close the
;; unwind-protect itself, pushing stop-cluster-manager/stop-tutor-server out
;; of the cleanup clauses into the let* body (an error in the protected body
;; would then skip teardown and leak the acceptor/redis against a with-test-
;; redis about to shut down). One close moved from each last-assert line to
;; the brief's own 5-paren tail — cleanup sits INSIDE unwind-protect at depth
;; 4, the same shape as cluster.heartbeat-refreshes-lease (lines 112-113).
;; Assertions unchanged.]

(test cluster.zombie-self-check-quiesces-adopted
  "A1: w1 is falsely declared dead (lease DELed) and its session adopted
(route flipped to w2). On w1's NEXT heartbeat the lease is gone (ttl -2) and
beats>=1, so the sweep drops the stale local handle; the route and the
refreshed lease are untouched by the sweep itself."
  (with-test-redis (conn port)
    (let* ((s1 (%worker-server port))
           (m1 (make-cluster-manager :server s1 :worker-id "w1"
                                     :redis-host "127.0.0.1" :redis-port port
                                     :prefix "t-zb:")))
      (unwind-protect
           (let ((sid (progn (cluster-join m1)        ; first beat: beats=1, no sweep
                             (server-start-session s1 "zb" "52-18" "sub"))))
             (redis:red-hset (uiop:strcat "t-zb:sess:" sid) "worker" "w1")
             ;; false death + adoption by another worker
             (redis:red-del "t-zb:worker:w1")
             (redis:red-hset (uiop:strcat "t-zb:sess:" sid) "worker" "w2")
             ;; recovery heartbeat: sweep fires (lease gone, beats>=1)
             (cluster-heartbeat-tick m1)
             (is (null (gethash sid (server-sessions s1))))          ; handle dropped
             (is (string= "w2" (first (multiple-value-list
                                       (cluster-route-get (uiop:strcat "t-zb:sess:" sid))))))
             (is (redis:red-exists "t-zb:worker:w1"))                 ; lease refreshed
             (is (= 2 (mtt/cluster::cluster-beats m1))))
        (stop-cluster-manager m1)
        (stop-tutor-server s1)))))

(test cluster.zombie-sweep-skips-own-sessions
  "A1 negative control: the same recovery shape but the route still names
THIS worker — nothing is dropped."
  (with-test-redis (conn port)
    (let* ((s1 (%worker-server port))
           (m1 (make-cluster-manager :server s1 :worker-id "w1"
                                     :redis-host "127.0.0.1" :redis-port port
                                     :prefix "t-zn:")))
      (unwind-protect
           (let ((sid (progn (cluster-join m1)
                             (server-start-session s1 "zn" "52-18" "sub"))))
             (redis:red-hset (uiop:strcat "t-zn:sess:" sid) "worker" "w1")
             (redis:red-del "t-zn:worker:w1")          ; lease lapsed
             (cluster-heartbeat-tick m1)               ; recovery sweep: route=me
             (is (gethash sid (server-sessions s1)))) ; untouched
        (stop-cluster-manager m1)
        (stop-tutor-server s1)))))

;;; --- Task 10: thin front proxy -------------------------------------------------

;; [brief defect, run-evidenced: dexador SIGNALS dex:http-request-failed on
;; 4xx/5xx (the proxy's own %forward-post in the brief knows this — it
;; unwraps the condition with dex:response-status/response-body — but the
;; brief's tests call dex:post/dex:get raw and read the RETURNED status, so
;; every non-2xx assertion aborted with "Unexpected Error: HTTP-REQUEST-...
;; returned 404/503" instead of asserting. Mirrors %forward-post's unwrap in
;; a test helper; assertions unchanged.]
(defun %post (url content)
  (handler-case (dex:post url :content content)
    (dex:http-request-failed (c)
      (values (typecase (dex:response-body c)
                (string (dex:response-body c))
                (vector (babel:octets-to-string (dex:response-body c) :encoding :utf-8))
                (t nil))
              (dex:response-status c)))))

(defun %get (url)
  (handler-case (dex:get url)
    (dex:http-request-failed (c)
      (values nil (dex:response-status c)))))

;; [brief defect, probe-evidenced ((getf '("w1" 1) 0) => NIL in a fresh REPL
;; probe — the exact defect class Task 9's route assertions evidenced): the
;; brief's two route assertions use (getf (multiple-value-list
;; (cluster-route-get ...)) 0), but getf is a PROPERTY-LIST accessor while
;; multiple-value-list returns a POSITIONAL list — the lookup always reads
;; NIL and (string= "w1" nil) signals. first on the positional list here;
;; the proxy skeleton carries the same defect in its route resolution (fixed
;; with nth-value 0 there).]

(test proxy.smoke-start-step-end-through-proxy
  "One worker behind an in-process proxy: start routes to the worker and
writes sess/student/worker-sess keys; step and end flow through verbatim."
  (with-test-redis (conn port)
    (let* ((s (%worker-server port))
           (m (make-cluster-manager :server s :worker-id "w1"
                                    :redis-host "127.0.0.1" :redis-port port
                                    :prefix "t-px:"))
           (p (make-tutor-proxy :port (%find-free-port)
                                :redis-host "127.0.0.1" :redis-port port
                                :prefix "t-px:")))
      (unwind-protect
           (progn
             (cluster-join m)
             (multiple-value-bind (body status)
                 (%post (format nil "http://127.0.0.1:~a/session/start" (proxy-port p))
                        "{\"student_id\":\"px\",\"problem_id\":\"52-18\",\"model_id\":\"sub\"}")
               (is (= 200 status))
               (let* ((alist (yason:parse body :object-as :alist))
                      (sid (cdr (assoc "session_id" alist :test #'string=))))
                 (is (and sid t))
                 ;; the proxy wrote the three route keys
                 (is (string= "w1" (first (multiple-value-list
                                          (cluster-route-get (uiop:strcat "t-px:sess:" sid))))))
                 (is (string= "w1" (first (multiple-value-list
                                          (cluster-route-get (uiop:strcat "t-px:student:px"))))))
                 (is (find sid (redis:red-smembers "t-px:worker-sess:w1") :test #'string=))
                 ;; step through the proxy
                 (multiple-value-bind (b2 s2)
                     (%post (format nil "http://127.0.0.1:~a/session/step" (proxy-port p))
                            (format nil
                                    "{\"session_id\":\"~a\",\"action\":{\"type\":\"digit\",\"value\":\"4\"}}"
                                    sid))
                   (is (= 200 s2))
                   (is (string= "on-path"
                                (cdr (assoc "status" (yason:parse b2 :object-as :alist)
                                            :test #'string=)))))
                 ;; end through the proxy
                 (multiple-value-bind (b3 s3)
                     (%post (format nil "http://127.0.0.1:~a/session/end" (proxy-port p))
                            (format nil "{\"session_id\":\"~a\"}" sid))
                   (declare (ignore b3))
                   (is (= 200 s3))))))
        (stop-tutor-proxy p)
        (stop-cluster-manager m)
        (stop-tutor-server s)))))

(test proxy.unknown-session-404
  (with-test-redis (conn port)
    (let ((p (make-tutor-proxy :port (%find-free-port)
                               :redis-host "127.0.0.1" :redis-port port
                               :prefix "t-404:")))
      (unwind-protect
           (multiple-value-bind (body status)
               (%post (format nil "http://127.0.0.1:~a/session/step" (proxy-port p))
                      "{\"session_id\":\"nope\",\"action\":{\"type\":\"digit\",\"value\":\"1\"}}")
             (declare (ignore body))
             (is (= 404 status)))
        (stop-tutor-proxy p)))))

(test proxy.dead-route-retry-and-503
  "A route pointing at a dead port: transport failure -> one re-resolve ->
route unchanged -> 503. Then move the route to a live worker -> the retry
succeeds (the takeover-transparent continuation shape).

[brief defect, probe-evidenced (RED probe: retry branch disabled -> suite
STILL 65/65 GREEN): the brief's two segments cannot discriminate the retry —
the route is healed BEFORE the second request, so its first try succeeds and
the re-resolve branch never runs. Third leg added (minimal, assertions of the
original two unchanged): a connection-killer listener that flips the route
MID-REQUEST — the only deterministic single-threaded shape where 200 is
reachable ONLY through transport-failure -> re-resolve -> changed route ->
retry. This is the leg that goes red under the brief's Step-5 probe.]"
  (with-test-redis (conn port)
    (let* ((s1 (%worker-server port))
           (m1 (make-cluster-manager :server s1 :worker-id "w1"
                                     :redis-host "127.0.0.1" :redis-port port
                                     :prefix "t-rt:"))
           (sid (progn (cluster-join m1)
                       (let ((sid (server-start-session s1 "rt" "52-18" "sub")))
                         (redis:red-hset (uiop:strcat "t-rt:sess:" sid) "worker" "w1")
                         sid)))
           (dead-port (%find-free-port))          ; bound then released: nothing listens
           (p (make-tutor-proxy :port (%find-free-port)
                                :redis-host "127.0.0.1" :redis-port port
                                :prefix "t-rt:"))
           ;; the "doomed worker": accepts the forwarded step, flips the route
           ;; to the live worker (the takeover), then kills the connection —
           ;; dexador surfaces the reset/EOF as a transport error. Own redis
           ;; connection: cl-redis connections are single-socket, never shared
           ;; across threads.
           (doom-port (%find-free-port))
           (doom-sock (usocket:socket-listen "127.0.0.1" doom-port :reuse-address t))
           (doom-conn (let ((redis:*connection* nil))
                        (redis:connect :host "127.0.0.1" :port port)))
           (doom-th (bordeaux-threads:make-thread
                     (lambda ()
                       (ignore-errors
                         (let ((c (usocket:socket-accept doom-sock)))
                           (let ((redis:*connection* doom-conn))
                             (redis:red-hset (uiop:strcat "t-rt:sess:" sid)
                                             "worker" "w1"))
                           (usocket:socket-close c)))))))
      (unwind-protect
           (progn
             ;; [brief simplification applied (the brief's own implementation
             ;; note): the minimal ghost shape = route -> ghost-id + the ghost's
             ;; worker:<id> metadata pointing at a dead port. The brief's
             ;; intermediate hash-shaped hset on the same key was dead weight
             ;; (immediately overwritten by the SET) and is dropped; assertions
             ;; unchanged.]
             (let* ((ghost (format nil "ghost-~a" dead-port))
                    (h (make-hash-table :test 'equal)))
               (setf (gethash "host" h) "127.0.0.1" (gethash "port" h) dead-port)
               (redis:red-hset (uiop:strcat "t-rt:sess:" sid) "worker" ghost)
               (redis:red-set (uiop:strcat "t-rt:worker:" ghost)
                              (with-output-to-string (out) (yason:encode h out))))
             ;; point the route at a dead port: 503 after the failed retry
             (multiple-value-bind (body status)
                 (%post (format nil "http://127.0.0.1:~a/session/step" (proxy-port p))
                        (format nil
                                "{\"session_id\":\"~a\",\"action\":{\"type\":\"digit\",\"value\":\"4\"}}"
                                sid))
               (declare (ignore body))
               (is (= 503 status)))
             ;; move the route to the live worker -> same call succeeds
             (redis:red-hset (uiop:strcat "t-rt:sess:" sid) "worker" "w1")
             (multiple-value-bind (b2 s2)
                 (%post (format nil "http://127.0.0.1:~a/session/step" (proxy-port p))
                        (format nil
                                "{\"session_id\":\"~a\",\"action\":{\"type\":\"digit\",\"value\":\"4\"}}"
                                sid))
               (is (= 200 s2))
               (is (string= "on-path"
                            (cdr (assoc "status" (yason:parse b2 :object-as :alist)
                                        :test #'string=)))))
             ;; takeover-transparent: route -> doomed worker; its listener flips
             ;; the route to w1 WHILE the request is in flight, then kills the
             ;; connection -> the 200 below is reachable ONLY via the
             ;; re-resolve+retry. (Action "3": the tens digit — the leg above
             ;; consumed the ones digit "4".)
             (let* ((h2 (make-hash-table :test 'equal)))
               (setf (gethash "host" h2) "127.0.0.1" (gethash "port" h2) doom-port)
               (redis:red-hset (uiop:strcat "t-rt:sess:" sid) "worker" "doom")
               (redis:red-set (uiop:strcat "t-rt:worker:doom")
                              (with-output-to-string (out) (yason:encode h2 out))))
             (multiple-value-bind (b3 s3)
                 (%post (format nil "http://127.0.0.1:~a/session/step" (proxy-port p))
                        (format nil
                                "{\"session_id\":\"~a\",\"action\":{\"type\":\"digit\",\"value\":\"3\"}}"
                                sid))
               (is (= 200 s3))
               (is (string= "on-path"
                            (cdr (assoc "status" (yason:parse b3 :object-as :alist)
                                        :test #'string=))))))
        (ignore-errors (usocket:socket-close doom-sock))   ; unblocks a pending accept
        (ignore-errors (bordeaux-threads:join-thread doom-th))
        (let ((redis:*connection* doom-conn))
          (ignore-errors (redis:disconnect)))
        (stop-tutor-proxy p)
        (stop-cluster-manager m1)
        (stop-tutor-server s1)))))

(test proxy.mastery-location-free
  "/student/mastery is served from redis directly: works even though no
worker ever registered locally in this process for that student; unknown
student -> 404."
  (with-test-redis (conn port)
    (let* ((s (%worker-server port))
           (sid (server-start-session s "mp" "52-18" "sub")))
      (server-step-session s sid '(("type" . "digit") ("value" . "4")))
      (let ((p (make-tutor-proxy :port (%find-free-port)
                                 :redis-host "127.0.0.1" :redis-port port
                                 :prefix "t-my:")))
        (unwind-protect
             (progn
               (multiple-value-bind (body status)
                   (%get (format nil "http://127.0.0.1:~a/student/mastery?student_id=mp"
                                 (proxy-port p)))
                 (is (= 200 status))
                 (let ((kc (cdr (assoc "kc" (yason:parse body :object-as :alist)
                                       :test #'string=))))
                   (is (and kc (> (length kc) 0) t))))
               (multiple-value-bind (body status)
                   (%get (format nil "http://127.0.0.1:~a/student/mastery?student_id=ghost"
                                 (proxy-port p)))
                 (declare (ignore body))
                 (is (= 404 status))))
          (stop-tutor-proxy p)
          (stop-tutor-server s))))))

;;; --- Phase 14 C1: tick error visibility ---------------------------------------

;; [brief defect, run-evidenced (RED: UNDEFINED-FUNCTION (SETF
;; CLUSTER-RUNNING) — the test package :use does not inherit internal
;; symbols): cluster-running is an INTERNAL accessor (unlike cluster-threads,
;; which is exported), so the brief's bare (setf (cluster-running m) …) reads
;; as mtt/cluster-test::cluster-running. Qualified with the same double-colon
;; prefix the brief itself uses for %tick-loop; assertions unchanged.]
(test cluster.tick-loop-survives-and-logs-errors
  "C1: a throwing tick is reported (tick name + condition, one line on
*error-output*) and the loop keeps running until the running flag clears
(the old ignore-errors swallowed everything silently)."
  (let* ((n 0)
         (m (make-cluster-manager
             :server (start-tutor-server :port 0 :start-acceptor-p nil)
             :worker-id "w-err")))
    (setf (mtt/cluster::cluster-running m) t)
    (flet ((bad-tick (mm)
             (declare (ignore mm))
             (incf n)
             (if (>= n 2)
                 (setf (mtt/cluster::cluster-running m) nil)  ; clean exit on 2nd call
                 (error "boom-~a" n))))
      (let ((out (with-output-to-string (*error-output*)
                   (mtt/cluster::%tick-loop m "test" #'bad-tick 0))))
        (is (= 2 n))
        (is (and (search "test tick failed" out)
                 (search "boom-1" out)
                 t))))))

;;; --- Phase 14 C2: stop-cluster-manager poll-join --------------------------------

;; [brief defect, run-evidenced (same class as C1 above: UNDEFINED-FUNCTION
;; (SETF CLUSTER-RUNNING) — cluster-running is an internal accessor, invisible
;; to this package's :use): qualified with the same double-colon prefix the
;; brief uses for %stop-tick-threads; assertions unchanged.]
(test cluster.stop-poll-joins-without-destroy
  "C2: well-behaved tick threads are given the deadline to observe the flag
and exit on their own — the destroy count is 0 (the old always-destroy
shape returns 3 and could kill a thread holding the redis lock mid-command,
hanging the leave below)."
  (let ((m (make-cluster-manager
            :server (start-tutor-server :port 0 :start-acceptor-p nil)
            :worker-id "w-pj"
            :heartbeat-interval 0.1 :scan-interval 0.1 :takeover-interval 0.1)))
    (setf (mtt/cluster::cluster-running m) t
          (cluster-threads m)
          (loop :repeat 3 :collect
                (bordeaux-threads:make-thread
                 (lambda () (loop :while (mtt/cluster::cluster-running m)
                                  :do (sleep 0.05))))))
    (setf (mtt/cluster::cluster-running m) nil)
    (is (= 0 (mtt/cluster::%stop-tick-threads m)))
    (is (every (lambda (th) (not (bordeaux-threads:thread-alive-p th)))
               (cluster-threads m)))))

(test cluster.stop-deadline-fallback-destroys
  "C2: a thread that never observes the flag is destroyed at the deadline
(fallback = the old behavior, bounded by it). Intervals 0.1 -> deadline ~2.1s."
  (let* ((m (make-cluster-manager
             :server (start-tutor-server :port 0 :start-acceptor-p nil)
             :worker-id "w-df"
             :heartbeat-interval 0.1 :scan-interval 0.1 :takeover-interval 0.1))
         (th (bordeaux-threads:make-thread (lambda () (sleep 100)))))
    (setf (mtt/cluster::cluster-running m) nil
          (cluster-threads m) (list th))
    (let ((start (get-universal-time)))
      (is (= 1 (mtt/cluster::%stop-tick-threads m)))
      (is (>= (get-universal-time) (+ start 2)))     ; waited the deadline
      (is (< (get-universal-time) (+ start 10))))))  ; but bounded by it

;;; --- Phase 14 C8: start-cluster-manager idempotent -------------------------------

(test cluster.start-idempotent-no-orphans
  "C8: a second start-cluster-manager returns the manager with the SAME
thread list — the old call overwrote the slot, orphaning the previous three
threads (they kept ticking on a manager the operator believed restarted)."
  (with-test-redis (conn port)
    (let* ((s (%worker-server port))
           (m (make-cluster-manager :server s :worker-id "w-id"
                                    :redis-host "127.0.0.1" :redis-port port
                                    :prefix "t-id:" :heartbeat-interval 0.2
                                    :scan-interval 0.2 :takeover-interval 0.2)))
      (unwind-protect
           (progn
             (start-cluster-manager m)
             (let ((before (cluster-threads m)))
               (sleep 0.3)
               (start-cluster-manager m)
               (is (= 3 (length (cluster-threads m))))
               (is (eq before (cluster-threads m))))
             (is (find "w-id" (redis:red-smembers "t-id:workers") :test #'string=)))
        (stop-cluster-manager m)
        (stop-tutor-server s)))))
