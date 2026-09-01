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
  ;; No trailing slash (final review): callers append "/redis.log" etc. and the
  ;; delete-directory-tree call sites coerce via ensure-directory-pathname (a
  ;; slashless STRING alone still fails UIOP's pathnamep gate — see fixture).
  (format nil "/tmp/~a-~a-~a" prefix (get-universal-time) (gensym)))

(defmacro with-test-redis ((conn-var port-var) &body body)
  "Start a disposable redis-server (--appendonly yes) on a free high port, bind
CONN-VAR to a fresh cl-redis connection and PORT-VAR to the port; FLUSHDB to
ensure a clean slate; shutdown + cleanup after. SKIP if no redis-server binary."
  (let ((binary (gensym)) (dir (gensym)) (port (gensym)))
    `(if (null (%redis-server-binary))
         (5am:skip "no redis-server binary found")
         (let ((,port (%find-free-port))
               (,dir (%unique-dir "mtt-redis")))
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
               ;; ensure-directory-pathname (final review): delete-directory-tree
               ;; takes a physical non-wildcard directory PATHNAME — a namestring
               ;; (slash or not) fails its pathnamep gate and the ignore-errors
               ;; silently skipped cleanup, leaking /tmp/mtt-redis-* dirs.
               (ignore-errors (uiop:delete-directory-tree
                               (uiop:ensure-directory-pathname ,dir) :validate t))))))))

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
    (ensure-directories-exist (uiop:ensure-directory-pathname dir))
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
      (ignore-errors (uiop:delete-directory-tree
                      (uiop:ensure-directory-pathname dir) :validate t)))))

(test redis-event-log.non-nil-summaries-round-trip
  "REGRESSION (C1): a log-event with NON-NIL intent-summary and result-summary
— the shape produced on EVERY real traced step (see src/session.lisp:83-84,
intent-summary = step-intent-assignments like ((goal sum five)), result-summary
= (status production feedback alt-count) like (:on-path initialize-addition
nil 0)) — must round-trip through log-event-to-json + log-all-events WITHOUT
crashing yason. Pre-fix, yason's default *symbol-encoder* (ENCODE-SYMBOL-ERROR)
crashed with \"No policy for symbols as keys defined\" on the symbol values.
The fix binds *symbol-encoder* / *symbol-key-encoder* to a lowercase-name
converter (mirrors src/http-api.lisp's json-encode). The existing 9 tests
passed only because their fixtures used make-log-event with default nil
summaries — this test closes that gap."
  (with-test-redis (conn port)
    (let* ((rlog (make-redis-event-log :key "mtt:test:ni" :host "127.0.0.1" :port port))
           ;; the exact non-nil summary shapes produced by step-session
           (ev (make-log-event
                :student-id "s1" :session-id "sess-x" :problem-id "5+2"
                :kc-event (make-kc-event :kc 'add :correct-p t)
                :intent-summary '((goal sum five) (goal count zero))
                :result-summary (list :on-path 'initialize-addition nil 0))))
      ;; MUST NOT crash — pre-fix this signalled
      ;; "No policy for symbols as keys defined" inside yason:encode-plist.
      (is (eql rlog (log-append rlog ev)))
      (is (= 1 (log-last-seq rlog)))
      ;; round-trip: log-all-events decodes the stored JSON back; assert we
      ;; got 1 event back with the kc/correct-p preserved (JSON loses the
      ;; symbol summaries on decode — json-to-log-event only reconstructs kc
      ;; — but the round-trip must complete without error).
      (let ((all (log-all-events rlog)))
        (is (= 1 (length all)))
        (is (eql 1 (log-event-seq (first all))))
        (is (eql t (kc-event-correct-p (log-event-kc-event (first all)))))))))

(test redis-event-log.kc-package-identity-preserved
  "B4: a kc symbol round-trips with its package. kc 'add in THIS test package
re-emerges as the SAME symbol (eq), not MTT:ADD."
  (with-test-redis (conn port)
    (let* ((rlog (make-redis-event-log :key "mtt:test:kcid" :host "127.0.0.1" :port port))
           (original-kc 'add))                       ; interned in :mtt/redis-store-test
      (log-append rlog (make-log-event :student-id "s1"
                                       :kc-event (make-kc-event :kc original-kc :correct-p t)))
      (let* ((all (log-all-events rlog))
             (roundtripped (kc-event-kc (log-event-kc-event (first all)))))
        (is (symbolp roundtripped))
        (is (eq roundtripped original-kc))
        (is (eq (symbol-package roundtripped) (symbol-package original-kc)))))))

(test redis-event-log.summaries-decoded
  "B2: intent/result summaries are populated on decode (not dropped to nil)."
  (with-test-redis (conn port)
    (let* ((rlog (make-redis-event-log :key "mtt:test:summ" :host "127.0.0.1" :port port))
           (ev (make-log-event :student-id "s1"
                               :kc-event (make-kc-event :kc 'add :correct-p t)
                               :intent-summary '((goal sum five))
                               :result-summary (list :on-path 'initialize-addition nil 0))))
      (log-append rlog ev)
      (let ((e (first (log-all-events rlog))))
        (is (not (null (log-event-intent-summary e))))
        (is (not (null (log-event-result-summary e))))))))

(test redis-event-log.stored-json-has-no-seq-field
  "B1: the raw stored JSON does NOT carry a (stale, always-0) seq field; seq is
derived from list position on read."
  (with-test-redis (conn port)
    (let* ((rlog (make-redis-event-log :key "mtt:test:noseq" :host "127.0.0.1" :port port))
           (key (redis-event-log-key rlog)))
      (log-append rlog (make-log-event :student-id "s1"
                                       :kc-event (make-kc-event :kc 'add :correct-p t)))
      (let ((raw (let ((redis:*connection* conn)) (redis:red-lrange key 0 -1))))
        (is (= 1 (length raw)))
        ;; no \"seq\" key in the stored JSON document
        (is (null (search "\"seq\"" (first raw)))))
      ;; and read-back seq is still 1 (derived from position)
      (is (equal '(1) (mapcar #'log-event-seq (log-all-events rlog)))))))

(test redis-event-log.disconnect-closes-connection
  "B3: disconnect-log closes the cl-redis connection and clears the conn slot;
idempotent."
  (with-test-redis (conn port)
    (let ((rlog (make-redis-event-log :key "mtt:test:disc" :host "127.0.0.1" :port port)))
      (log-append rlog (make-log-event :student-id "s1"
                                       :kc-event (make-kc-event :kc 'add :correct-p t)))
      (is (not (null (redis-event-log-connection rlog))))
      (disconnect-log rlog)
      (is (null (redis-event-log-connection rlog)))
      (disconnect-log rlog))))                         ; idempotent: no error

(test redis-event-log.kt-replay-equals-in-memory
  "KT replay: mastery recomputed from the redis log equals mastery from an
in-memory log with identical events (the spec §5.4 'log present → lossless
recompute' guarantee). Also validates B4 (kc identity must match for bucketing)."
  (with-test-redis (conn port)
    (let* ((rlog (make-redis-event-log :key "mtt:test:replay" :host "127.0.0.1" :port port))
           (mem (make-event-log)))
      (dolist (correct '(t t nil t))
        (let ((ev (make-log-event :student-id "s1" :problem-id "p1"
                                  :kc-event (make-kc-event :kc 'add :correct-p correct))))
          (log-append rlog ev)
          (log-append mem (copy-log-event ev))))
      (let ((m-redis (compute-mastery (log-all-events rlog)))
            (m-mem   (compute-mastery (log-all-events mem))))
        (is (= (length m-redis) (length m-mem)))
        ;; same kc symbol (B4) and same P(L) (replay fidelity)
        (is (eq (getf (first m-redis) :kc) (getf (first m-mem) :kc)))
        (is (< (abs (- (getf (first m-redis) :p-l)
                       (getf (first m-mem) :p-l)))
               1e-9))))))

(test redis-event-log.past-tense-symbol-summaries-round-trip
  "Phase 10 symbol specialization: log-events whose intent-summary carries
MODEL-PACKAGE symbol slot values from student answers — e.g. ((goal past
GOED) (goal verb GO)) with GOED interned in :mtt/past-tense-tutor, arbitrary
student strings rather than a fixed number-word vocabulary — round-trip
through the redis JSON backend, and mastery recomputed from the redis log
equals the in-memory fold (KT replay fidelity on symbol-bearing summaries)."
  :skipped-if (lambda () (null (%redis-server-binary)))
  (with-test-redis (conn port)
    (let* ((kc :irregular-retrieval)
           (mk (lambda (seq correct)
                 (make-log-event
                  :seq seq :student-id "pts" :problem-id "go"
                  :kc-event (make-kc-event :kc kc :correct-p correct)
                  :intent-summary `((goal past ,(intern "GOED" :mtt/past-tense-tutor))
                                    (goal verb ,(intern "GO" :mtt/past-tense-tutor)))
                  :result-summary (list (if correct :on-path :off-path-buggy)
                                        (intern (if correct "RETRIEVE-IRREGULAR"
                                                    "BUGGY-OVER-REGULARIZE")
                                                :mtt/past-tense-tutor)
                                        "feedback" 0))))
           (events (list (funcall mk 1 t) (funcall mk 2 nil) (funcall mk 3 t))))
      ;; memory fold
      (let* ((mem (make-event-log))
             (_ (dolist (e events) (log-append mem e)))
             (mem-mastery (mtt:compute-mastery (log-all-events mem))))
        (let ((rlog (make-redis-event-log :key "mtt:test:pt-symbols"
                                          :host "127.0.0.1" :port port)))
          (unwind-protect
               (progn
                 (dolist (e events) (log-append rlog e))
                 (is (= 3 (log-last-seq rlog)))
                 ;; JSON wire: the model-package symbols encode as tagged
                 ;; objects {"sym": NAME, "pkg": PACKAGE} with EXACT case.
                 (let* ((raw (let ((redis:*connection* conn))
                               (redis:red-lrange (redis-event-log-key rlog) 0 -1)))
                        (raw2 (second raw)))
                   (is (= 3 (length raw)))
                   (is (and (search "\"GOED\"" raw2) t))
                   (is (and (search "\"MTT/PAST-TENSE-TUTOR\"" raw2) t)))
                 ;; kc round-trips with package identity (B4). Summaries come
                 ;; back as THE SAME symbols (eq, name+package) — the phase-13
                 ;; tagged codec closed the deferred symbol-fidelity gap.
                 (let ((e2 (second (log-all-events rlog))))
                   (is (eq :irregular-retrieval
                           (kc-event-kc (log-event-kc-event e2))))
                   (is (eq (intern "GOED" :mtt/past-tense-tutor)
                           (third (first (log-event-intent-summary e2)))))
                   (is (eq :off-path-buggy
                           (first (log-event-result-summary e2)))))
                 ;; KT replay equals in-memory fold (spec §9.6: recompute
                 ;; mastery losslessly) — bit-identical because kc carries its
                 ;; package through kc_package and P(L) folds the same doubles.
                 (is (equal mem-mastery
                            (mtt:compute-mastery (log-all-events rlog)))))
            (disconnect-log rlog)))))))

(test redis-event-log.symbol-summaries-round-trip-eq
  "Phase 13 tagged codec: intent/result summaries carrying model-package
symbols round-trip as THE SAME symbols (name+package, eq) — not strings, not
char lists. Status keyword :on-path comes back as the keyword itself."
  (with-test-redis (conn port)
    (let* ((rlog (make-redis-event-log :key "mtt:test:symrt" :host "127.0.0.1" :port port))
           (sym-goed (intern "GOED" :mtt/past-tense-tutor))
           (sym-verb (intern "GO" :mtt/past-tense-tutor))
           (sym-prod (intern "RETRIEVE-IRREGULAR" :mtt/past-tense-tutor))
           (ev (make-log-event :student-id "s1" :session-id "sess-1" :problem-id "go"
                               :kc-event (make-kc-event :kc :irregular-retrieval :correct-p t)
                               :intent-summary `((goal past ,sym-goed) (goal verb ,sym-verb))
                               :result-summary (list :on-path sym-prod "feedback text" 0))))
      (log-append rlog ev)
      (let* ((e (first (log-all-events rlog)))
             (int-sum (log-event-intent-summary e))
             (res-sum (log-event-result-summary e)))
        ;; symbol-level fidelity: eq on every symbol leaf
        (is (eq sym-goed (third (first int-sum))))
        (is (eq sym-verb (third (second int-sum))))
        (is (eq :on-path (first res-sum)))
        (is (eq sym-prod (second res-sum)))
        ;; strings stay strings (not char lists — the %coerce-to-list fix)
        (is (and (stringp (third res-sum)) (string= "feedback text" (third res-sum))))))))

(test redis-event-log.legacy-json-still-decodes
  "Backward compatibility: a row stored in the OLD wire format (symbols as
plain downcase strings) — e.g. by an older deployment sharing this redis —
decodes without error; summaries come back as plain strings, mastery replay
still works."
  (with-test-redis (conn port)
    (let ((key "mtt:test:legacy")
          (legacy-json (concatenate 'string
                        "{\"student_id\":\"s1\",\"session_id\":\"sess-1\","
                        "\"problem_id\":\"5+2\",\"kc\":\"ADD\","
                        "\"kc_package\":\"MTT/REDIS-STORE-TEST\",\"correct\":true,"
                        "\"intent\":[[\"goal\",\"sum\",\"five\"]],"
                        "\"result\":[\"on-path\",\"initialize-addition\",null,0]}")))
      (let ((redis:*connection* conn))
        (redis:red-rpush key legacy-json))
      (let* ((rlog (make-redis-event-log :key key :host "127.0.0.1" :port port))
             (all (log-all-events rlog))
             (e (first all)))
        (is (= 1 (length all)))
        (is (eq 'add (kc-event-kc (log-event-kc-event e))))
        ;; old rows: plain strings, preserved verbatim
        (is (equal '(("goal" "sum" "five")) (log-event-intent-summary e)))
        (is (equal '("on-path" "initialize-addition" nil 0) (log-event-result-summary e)))
        ;; KT replay over the legacy row works
        (is (= 1 (getf (first (compute-mastery all)) :total)))))))

(test redis-event-log.mixed-old-and-new-rows
  "A log holding BOTH an old-format row (RPUSHed raw) and a new-format row
(log-append) reads back as one sequence; each row decodes in its own format."
  (with-test-redis (conn port)
    (let ((key "mtt:test:mixed")
          (legacy "{\"student_id\":\"s1\",\"kc\":\"ADD\",\"kc_package\":\"MTT/REDIS-STORE-TEST\",\"correct\":false,\"intent\":[[\"goal\",\"sum\",\"five\"]],\"result\":[\"on-path\",\"initialize-addition\",null,0]}"))
      (let ((redis:*connection* conn)) (redis:red-rpush key legacy))
      (let ((rlog (make-redis-event-log :key key :host "127.0.0.1" :port port)))
        (log-append rlog (make-log-event
                          :student-id "s1"
                          :kc-event (make-kc-event :kc :add-fractions :correct-p t)
                          :intent-summary '((goal snum 5))
                          :result-summary (list :on-path 'add-fractions nil 0)))
        (let ((all (log-all-events rlog)))
          (is (= 2 (length all)))
          (is (equal '(1 2) (mapcar #'log-event-seq all)))
          (is (equal '(("goal" "sum" "five"))         ; legacy row: strings
                     (log-event-intent-summary (first all))))
          (is (eq 'add-fractions                        ; new row: tagged→symbol
                  (second (log-event-result-summary (second all))))))))))

(test redis-event-log.tagged-symbol-missing-package-degrades
  "A tagged symbol whose package is NOT loaded degrades to its name STRING."
  (with-test-redis (conn port)
    (let* ((pkg (make-package (gensym "MTT/MISSING-")))
           (sym (intern "WIDGET" pkg))
           (rlog (make-redis-event-log :key "mtt:test:misspkg" :host "127.0.0.1" :port port))
           (ev (make-log-event :student-id "s1"
                               :kc-event (make-kc-event :kc 'add :correct-p t)
                               :intent-summary `((goal widget ,sym))
                               :result-summary (list :on-path 'p nil 0))))
      (delete-package pkg)                              ; package gone before decode
      (log-append rlog ev)                              ; encode happens with sym still valid
      (let ((e (first (log-all-events rlog))))
        (is (string= "WIDGET" (third (first (log-event-intent-summary e)))))))))

(test redis.sym-tag-non-string-values-pass-through
  "C6: a 2-key sym/pkg object with non-string values is no longer misread as
a tag ((find-package 7) used to signal TYPE-ERROR); it passes through
unchanged, dotted pairs included."
  (let* ((json "{\"intent\":[{\"sym\":5,\"pkg\":7}]}")
         (a (let ((yason:*parse-object-as* :alist)) (yason:parse json)))
         (decoded (untag-symbols (cdr (assoc "intent" a :test #'string=)))))
    (is (equal '((("sym" . 5) ("pkg" . 7))) decoded))))
