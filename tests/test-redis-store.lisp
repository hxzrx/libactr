;;;; tests/test-redis-store.lisp — redis-event-log integration (Phase 5)
;;;; Own FiveAM suite :mtt/redis-store (does NOT join :mtt). Spins a per-run
;;;; redis-server on a free high port; SKIPS if redis-server is unavailable.
(defpackage :mtt/redis-store-test
  (:use :cl :5am :mtt))
(in-package :mtt/redis-store-test)

(def-suite :mtt/redis-store :description "redis-event-log integration")
(in-suite :mtt/redis-store)

;;; --- with-test-redis fixture ------------------------------------------------
(defparameter *redis-server-candidates*
  '("/usr/sbin/redis-server" "/usr/local/sbin/redis-server" "/usr/bin/redis-server"))

(defun %find-free-port ()
  ;; Bind socket 0, read assigned port, close. Portable via usocket (a cl-redis dep).
  (let ((sock (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (unwind-protect (usocket:get-local-port sock) (usocket:socket-close sock))))

(defun %redis-server-binary ()
  (find-if #'probe-file *redis-server-candidates*))

(defun %unique-dir (prefix)
  ;; Include get-universal-time so the directory is unique across fresh SBCL
  ;; processes (gensym alone resets per process, which would let AOF data from
  ;; a previous run leak into the current one).
  (format nil "/tmp/~a-~a-~a/" prefix (get-universal-time) (gensym)))

(defmacro with-test-redis ((conn-var port-var) &body body)
  "Start a disposable redis-server (--appendonly yes) on a free high port, bind
CONN-VAR to a fresh cl-redis connection and PORT-VAR to the port; FLUSHDB to
ensure a clean slate; shutdown + cleanup after. SKIP if no redis-server binary."
  (let ((binary (gensym)) (dir (gensym)) (port (gensym)))
    `(if (null (%redis-server-binary))
         (5am:skip "no redis-server binary found")
         (let ((,port (%find-free-port))
               (,dir (%unique-dir "mtt-redis")))
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
             ;; Ensure a clean database regardless of any persisted AOF.
             (let ((redis:*connection* ,conn-var))
               (redis:red-flushdb))
             (unwind-protect (progn ,@body)
               (ignore-errors (redis:disconnect))
               (ignore-errors
                 (uiop:run-program (list "redis-cli" "-p" (princ-to-string ,port)
                                         "shutdown" "nosave")
                                   :output :string :error-output :string))
               (sleep 1)
               (ignore-errors (uiop:delete-directory-tree ,dir :validate t))))))))

(test redis-event-log.round-trip-equivalence
  (with-test-redis (conn port)
    (let* ((rlog (make-redis-event-log :key "mtt:test:ev" :host "127.0.0.1" :port port))
           (mem (make-event-log)))
      ;; same events appended to both
      (dolist (kc '(t nil t))
        (let ((ev (make-log-event :student-id "s1" :problem-id "p1"
                                  :kc-event (make-kc-event :kc 'add :correct-p kc))))
          (log-append rlog ev)
          (log-append mem (copy-log-event ev))))
      (is (= 3 (log-last-seq rlog)))
      (is (= 3 (log-last-seq mem)))
      (is (equal (mapcar #'log-event-seq (log-all-events rlog)) '(1 2 3)))
      (is (= (length (log-all-events rlog)) (length (log-all-events mem))))
      ;; events-since(1) = seq 2,3
      (is (equal '(2 3) (mapcar #'log-event-seq (log-events-since rlog 1))))
      ;; content equivalence on kc/correct-p
      (is (equal (mapcar (lambda (e) (kc-event-correct-p (log-event-kc-event e)))
                         (log-all-events rlog))
                 '(t nil t))))))

(test redis-event-log.aof-persistence-across-restart
  "Append events, kill redis, relaunch on the same dir (AOF replays), assert all events survive."
  :skipped-if (lambda () (null (%redis-server-binary)))
  (let* ((dir (%unique-dir "mtt-redis-aof"))
         (port (%find-free-port))
         (key "mtt:test:aof"))
    (ensure-directories-exist dir)
    (unwind-protect
         (progn
           (uiop:run-program (list (%redis-server-binary) "--port" (princ-to-string port)
                                   "--daemonize" "yes" "--appendonly" "yes"
                                   "--dir" dir "--save" "" "--logfile" (format nil "~a/redis.log" dir))
                             :output :string :error-output :string)
           (sleep 1)
           (let ((log (make-redis-event-log :key key :host "127.0.0.1" :port port)))
             (log-append log (make-log-event :student-id "s1" :kc-event (make-kc-event :kc 'add :correct-p t)))
             (log-append log (make-log-event :student-id "s1" :kc-event (make-kc-event :kc 'add :correct-p nil)))
             (is (= 2 (log-last-seq log))))
           ;; kill
           (uiop:run-program (list "redis-cli" "-p" (princ-to-string port) "shutdown" "nosave")
                             :output :string :error-output :string)
           (sleep 1)
           ;; relaunch on same dir → AOF replay
           (uiop:run-program (list (%redis-server-binary) "--port" (princ-to-string port)
                                   "--daemonize" "yes" "--appendonly" "yes"
                                   "--dir" dir "--save" "" "--logfile" (format nil "~a/redis2.log" dir))
                             :output :string :error-output :string)
           (sleep 1)
           (let ((log (make-redis-event-log :key key :host "127.0.0.1" :port port)))
             (is (= 2 (log-last-seq log)))
             (is (= 2 (length (log-all-events log))))))
      (ignore-errors
        (uiop:run-program (list "redis-cli" "-p" (princ-to-string port) "shutdown" "nosave")
                          :output :string :error-output :string))
      (sleep 1)
      (ignore-errors (uiop:delete-directory-tree dir :validate t)))))
