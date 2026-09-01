;;;; tests/test-cluster-e2e.lisp — kill-a-real-worker end-to-end (Phase 13).
;;;; Joins :mtt/cluster. Self-starts redis + TWO SBCL worker subprocesses
;;;; (examples/cluster-worker.lisp); the proxy runs IN this test process.
;;;; SKIP when redis-server is missing (sbcl is the running image's own —
;;;; required).
(in-package :mtt/cluster-test)

;; [brief defect, run-evidenced: the brief's skeleton never joins the suite.
;; fiveam's def-test registers under the LOAD-TIME value of the special
;; *suite* (probe: (macroexpand-1 '(5am:def-test foo nil ...)) registers with
;; it.bese.fiveam::*suite* evaluated at load); without this in-suite — and
;; with mtt/cluster-test's two file components lacking :serial t, so sibling
;; load order is not guaranteed — the test registers in the anonymous NIL
;; suite and (5am:run! :mtt/cluster) reports the old 67 checks without it.
;; Same in-suite every other suite file carries.]
(in-suite :mtt/cluster)

;; [brief defect, signature-vs-call-evidenced: %worker-command's lambda list
;; took a 5th parameter (LOG) that the body never used, while BOTH call sites
;; pass 4 arguments — at runtime the first spawn would signal PROGRAM-ERROR
;; (wrong number of arguments). The log wiring lives in the launch-program
;; :output/:error-output kwarg; the dead parameter is dropped, calls verbatim.]
(defun %worker-command (worker-file port redis-port worker-id)
  (list "sbcl" "--non-interactive"
        "--eval" "(ql:quickload :mtt/cluster)"
        "--eval" "(ql:quickload :mtt/subtraction-adapter)"
        "--load" worker-file
        "--eval" (format nil "(mtt/cluster-worker:main :port ~a :redis-port ~a :worker-id ~s)"
                         port redis-port worker-id)))

(defun %poll-until (thunk timeout &key (sleep 0.5))
  "Repeat THUNK until it returns non-nil or TIMEOUT (seconds) elapses; last value."
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop :for v := (funcall thunk)
          :when v :return v
          :do (when (> (get-universal-time) deadline) (return nil))
              (sleep sleep))))

(test cluster-e2e.kill-worker-takeover-continues
  "THE orchestration proof: start a subtraction session through the proxy on
worker A, step into the borrow column, let the scanner checkpoint, KILL A's
process, keep stepping through the proxy until B's takeover tick rebuilds the
session from the checkpoint, finish the problem, end it, and read mastery —
all with the SAME session_id (transparent continuation)."
  :skipped-if (lambda () (null (%redis-server-binary)))
  (with-test-redis (conn port)
    (let* ((dir (%unique-dir "mtt-cluster-e2e"))
           ;; [brief defect, run-evidenced: the worker logs are redirected into
           ;; DIR (launch-program :output log1) but the brief never created it —
           ;; every spawn would fail opening /tmp/.../w1.log in a nonexistent
           ;; directory and the readiness poll would burn its full 90s.]
           (worker-file (namestring
                         (asdf:system-relative-pathname "mtt"
                                                        "examples/cluster-worker.lisp")))
           ;; [brief defect, namespace-evidenced: the brief gave the proxy
           ;; :prefix "e2e:" while the workers (whose normative main signature
           ;; takes NO prefix) default to "mtt:cluster:" — the proxy would read
           ;; e2e:workers (empty) and 503 every /session/start, and the direct
           ;; e2e:sess:/e2e:ckpt: reads would look in a namespace nobody writes
           ;; (checkpoint keys come from the MANAGER's default store at
           ;; mtt:cluster:ckpt:). The proxy uses the DEFAULT prefix (the
           ;; controller-mandated Task-10-review normalization) and the direct
           ;; reads use its literals.]
           (p1 (%find-free-port)) (p2 (%find-free-port))
           (log1 (format nil "~a/w1.log" dir)) (log2 (format nil "~a/w2.log" dir))
           ;; [deviation from brief, log-evidenced (flake): the brief launches
           ;; both workers CONCURRENTLY — two fresh SBCL subprocesses quickloading
           ;; the same systems can clobber each other's ASDF FASL cache (observed:
           ;; "compilation unit aborted; caught 1 fatal ERROR condition" in BOTH
           ;; worker logs in one run, and in another a worker that came up, joined,
           ;; then died of a LATE fatal compile error — its fresh lease + dead port
           ;; = the proxy's start 503 "worker unreachable"). Boots are SERIALIZED:
           ;; w1 launches and is polled up BEFORE w2 launches, so at most one
           ;; subprocess compiles at a time; the second boot overlaps no
           ;; compilation (cache warm) and costs nothing.]
           (w1 nil)
           (w2 nil)
           (proxy (make-tutor-proxy :port (%find-free-port)
                                    :redis-host "127.0.0.1" :redis-port port)))
      (flet ((worker-up-p (p)
               (multiple-value-bind (b s) (ignore-errors
                                            (dex:get (format nil "http://127.0.0.1:~a/health" p)))
                 (declare (ignore b)) (and (numberp s) (= 200 s)))))
        (unwind-protect
             (progn
               ;; cosmetic#6: launch INSIDE the protect — the old let*-binding
               ;; launch leaked w1 if anything signaled between launch and
               ;; protect entry (poll failure burned 90s then leaked).
               (ensure-directories-exist (uiop:ensure-directory-pathname dir))
               (setf w1 (uiop:launch-program (%worker-command worker-file p1 port "w1")
                                             :output log1 :error-output log1))
               ;; worker 1 up (FASL-cold worst case ~60s; warm ~5-15s)
               (is (%poll-until (lambda () (worker-up-p p1)) 90))
               ;; then worker 2 — serialized (see the let* note above)
               (setf w2 (uiop:launch-program (%worker-command worker-file p2 port "w2")
                                             :output log2 :error-output log2))
               (is (%poll-until (lambda () (worker-up-p p2)) 90))
               ;; start through the proxy
               (multiple-value-bind (body status)
                   (dex:post (format nil "http://127.0.0.1:~a/session/start" (proxy-port proxy))
                             :content "{\"student_id\":\"e2e\",\"problem_id\":\"52-18\",\"model_id\":\"sub\"}")
                 (is (= 200 status))
                 (let* ((alist (yason:parse body :object-as :alist))
                        (sid (cdr (assoc "session_id" alist :test #'string=))))
                   (is (and sid t))
                   ;; which worker holds it? read the route
                   ;; [brief defect, probe-evidenced in Tasks 9/10 ((getf
                   ;; '("w1" 1) 0) => NIL — getf is a property-list accessor,
                   ;; multiple-value-list returns a POSITIONAL list): as
                   ;; written owner is always nil, (is (and owner t)) is red
                   ;; and (string= owner "w1") signals. first, the same fix
                   ;; test-cluster.lisp's route assertions carry.]
                   (let ((owner (first (multiple-value-list
                                        (with-proxy-redis (proxy)
                                          (cluster-route-get (uiop:strcat "mtt:cluster:sess:" sid)))))))
                     (is (and owner t))
                     ;; step the borrow ones column (4 = 12-8)
                     (multiple-value-bind (b2 s2)
                         (dex:post (format nil "http://127.0.0.1:~a/session/step"
                                           (proxy-port proxy))
                                   :content (format nil
                                                    "{\"session_id\":\"~a\",\"action\":{\"type\":\"digit\",\"value\":\"4\"}}"
                                                    sid))
                       (is (= 200 s2))
                       (is (string= "on-path"
                                    (cdr (assoc "status" (yason:parse b2 :object-as :alist)
                                                :test #'string=)))))
                     ;; let the dead-to-be worker checkpoint the state
                     (is (%poll-until (lambda ()
                                        (with-proxy-redis (proxy)
                                          (redis:red-exists (uiop:strcat "mtt:cluster:ckpt:" sid))))
                                      10))
                     ;; KILL the owner
                     (let ((victim (if (string= owner "w1") w1 w2)))
                       (uiop:terminate-process victim)
                       (uiop:wait-process victim))
                     ;; keep stepping the tens column until takeover completes
                     ;; (black-box: only the proxy's behavior is observed)
                     (let ((done-p nil))
                       (is (%poll-until
                            (lambda ()
                              (multiple-value-bind (b3 s3)
                                  (ignore-errors
                                   (dex:post (format nil "http://127.0.0.1:~a/session/step"
                                                     (proxy-port proxy))
                                             :content (format nil
                                                              "{\"session_id\":\"~a\",\"action\":{\"type\":\"digit\",\"value\":\"3\"}}"
                                                              sid)))
                                (when (and (numberp s3) (= 200 s3))
                                  (let* ((a3 (yason:parse b3 :object-as :alist)))
                                    (setf done-p (cdr (assoc "done" a3 :test #'string=)))
                                    t))))
                            30))
                       (is (eq t done-p))
                       ;; end through the proxy
                       (multiple-value-bind (b4 s4)
                           (dex:post (format nil "http://127.0.0.1:~a/session/end"
                                             (proxy-port proxy))
                                     :content (format nil "{\"session_id\":\"~a\"}" sid))
                         (declare (ignore b4))
                         (is (= 200 s4)))
                       ;; mastery: served from redis, both workers' events
                       (multiple-value-bind (b5 s5)
                           (dex:get (format nil
                                            "http://127.0.0.1:~a/student/mastery?student_id=e2e"
                                            (proxy-port proxy)))
                         (is (= 200 s5))
                         (let ((kcs (mapcar (lambda (x) (cdr (assoc "kc" x :test #'string=)))
                                            (cdr (assoc "kc" (yason:parse b5 :object-as :alist)
                                                        :test #'string=)))))
                           ;; kc strings are princ-to-string of keywords: UPPERCASE no colon
                           ;; [brief defect: the brief (and its fact-check note)
                           ;; wrote #'string-e — no such CL function (UNDEFINED-
                           ;; FUNCTION at runtime, observed). The standard
                           ;; case-insensitive comparison is string-equal.]
                           (is (member "borrow" kcs :test #'string-equal))
                           (is (member "column-subtract" kcs :test #'string-equal))))
                       ;; the event log is one contiguous sequence
                       (let ((log (mtt:make-redis-event-log
                                   :key "mtt:student:e2e:events"
                                   :host "127.0.0.1" :port port)))
                         (unwind-protect
                              (let ((events (mtt:log-all-events log)))
                                (is (>= (length events) 3))
                                (is (equal (loop :for i :from 1 :to (length events) :collect i)
                                           (mapcar #'mtt:log-event-seq events))))
                           ;; B3 seam (final review): the direct event-log conn
                           ;; opened for this assertion was dangling — close it.
                           (mtt:disconnect-log log))))))))
          ;; teardown
          (ignore-errors (uiop:terminate-process w1))
          (ignore-errors (uiop:terminate-process w2))
          (ignore-errors (uiop:wait-process w1))
          (ignore-errors (uiop:wait-process w2))
          (ignore-errors (stop-tutor-proxy proxy))
          (ignore-errors (uiop:delete-directory-tree
                          (uiop:ensure-directory-pathname dir) :validate t)))))))
