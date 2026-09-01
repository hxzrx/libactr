;;;; src/redis-store.lisp — Redis (AOF) durable event-log (Phase 5)
;;;; Specializes the Phase 4 event-log protocol at the seam. One Redis LIST per
;;;; log (key provided by caller, e.g. mtt:student:<id>:events); seq is
;;;; STORE-ASSIGNED atomically by RPUSH's returned length (race-free under any
;;;; writer topology). cl-redis uses a global redis:*connection*; under
;;;; thread-per-request each call dynamically rebinds *connection* to THIS log's
;;;; own connection. No global mutable state in this file.
(in-package :mtt)

(defclass redis-event-log ()
  ((key  :reader redis-event-log-key :initarg :key)
   (host :reader redis-event-log-host :initarg :host :initform "127.0.0.1")
   (port :reader redis-event-log-port :initarg :port :initform 6379)
   (conn :reader redis-event-log-connection :initform nil))
  (:documentation "Append-only event log backed by a Redis LIST with AOF persistence."))

(defun redis-event-log-p (x)
  "Type predicate for redis-event-log (defclass does not auto-generate -p)."
  (typep x 'redis-event-log))

(defun make-redis-event-log (&key key (host "127.0.0.1") (port 6379))
  "Create a redis-event-log. Opens one cl-redis connection (lazily on first use)."
  (make-instance 'redis-event-log :key key :host host :port port))

(defmacro with-redis ((log) &body body)
  "Ensure a connection on LOG and dynamically bind redis:*connection* to it for BODY.
cl-redis's connect refuses if *connection* is already set globally; we dynamically
rebind it to nil so each log opens its own independent connection."
  (let ((l (gensym)))
    `(let* ((,l ,log)
            (conn (or (slot-value ,l 'conn)
                      (setf (slot-value ,l 'conn)
                            (let ((redis:*connection* nil))
                              (redis:connect :host (redis-event-log-host ,l)
                                             :port (redis-event-log-port ,l)))))))
       (let ((redis:*connection* conn))
         ,@body))))

;; --- log-event <-> JSON (yason) ----------------------------------------------
;; NOTE: yason's default *symbol-key-encoder* is ENCODE-SYMBOL-KEY-ERROR, so
;; barred keywords like :|seq| signal an error. We use plain STRING keys which
;; yason:encode-plist accepts directly and produces exact-case JSON keys.
;; HOWEVER, the VALUE positions of "intent" / "result" carry live symbols on
;; every real traced step — intent-summary is step-intent-assignments like
;; ((goal sum five) ...), and result-summary is (status production feedback
;; alt-count) where status is a keyword (:on-path / :off-path / ...). yason's
;; default *symbol-encoder* is ENCODE-SYMBOL-ERROR, which crashes on any
;; symbol VALUE — so we bind BOTH *symbol-key-encoder* and *symbol-encoder*
;; to a lowercase-name converter (mirrors src/http-api.lisp's json-encode).
;; Without this, the first real (non-nil-summary) event crashes encoding with
;; "No policy for symbols as keys defined".
;; --- Phase 13: symbol-tagging codec (shared with mtt/cluster checkpoints) ---
;; Wire format upgrade (spec §7): summaries' symbols used to encode as
;; downcased strings (package lost). Now every symbol in an intent/result
;; summary encodes as a tagged object {"sym": NAME, "pkg": PACKAGE} with
;; EXACT case; decode interns it back (package missing -> degrade to the name
;; string, never an error). Legacy rows (plain strings) pass through decoded
;; as strings — backward compatible. nil/t are NOT tagged (JSON null/true).

(defun tag-symbols (tree)
  "Recursively convert every SYMBOL in TREE to a yason-encodable tagged
hash-table {\"sym\": NAME (exact case), \"pkg\": PACKAGE-NAME}. nil and t pass
through untagged; other atoms pass through; lists map recursively. Inverse:
untag-symbols. Shared with the phase-13 cluster checkpoint store."
  (cond
    ((or (null tree) (eq tree t)) tree)
    ((symbolp tree)
     (let ((h (make-hash-table :test 'equal)))
       (setf (gethash "sym" h) (symbol-name tree)
             (gethash "pkg" h) (and (symbol-package tree)
                                    (package-name (symbol-package tree))))
       h))
    ((consp tree) (mapcar #'tag-symbols tree))
    (t tree)))

(defun %sym-tag-p (x)
  "True when X is a yason-parsed object (alist form) carrying exactly the
symbol-tag keys — the decode image of tag-symbols' hash-tables. Phase 14 C6
tightening: the VALUES must carry the tag's types as well — sym is a string
(the symbol NAME tag-symbols always writes), pkg is a string or null
(uninterned symbols write pkg as JSON null). WIRE CONTRACT (phase-14 spec
§6): business summaries are POSITIONAL lists (JSON arrays) and never produce
a 2-key sym/pkg object — a decoded object of exactly this shape IS a symbol
tag."
  (and (consp x)
       (consp (first x)) (stringp (caar x))
       (= 2 (length x))
       (let ((sym (cdr (assoc "sym" x :test #'string=)))
             (pkg-cell (assoc "pkg" x :test #'string=)))
         (and (stringp sym)
              pkg-cell
              (or (null (cdr pkg-cell)) (stringp (cdr pkg-cell)))
              t))))

(defun untag-symbols (tree)
  "Inverse of tag-symbols over a yason-parsed tree (objects parsed as alists):
tagged alists intern back to symbols in their package; a missing package
degrades that entry to the symbol-NAME STRING (never an error). Vectors map
recursively to lists; every other atom (strings included) passes through —
legacy rows decode exactly as before. NOTE: unlike the old %coerce-to-list,
STRINGS pass through as strings (a string IS a vector; mapping over it
produced the phase-10 char-list tree)."
  (cond
    ((and (consp tree) (%sym-tag-p tree))
     (let* ((sym (cdr (assoc "sym" tree :test #'string=)))
            (pkg (find-package (cdr (assoc "pkg" tree :test #'string=)))))
       (if (and pkg sym) (intern sym pkg) sym)))
    ((stringp tree) tree)                       ; strings pass through (string IS a vector)
    ((vectorp tree) (map 'list #'untag-symbols tree))
    ((consp tree)
     (if (%sym-tag-p tree)
         (let* ((sym (cdr (assoc "sym" tree :test #'string=)))
                (pkg (find-package (cdr (assoc "pkg" tree :test #'string=)))))
           (if (and pkg sym) (intern sym pkg) sym))
         ;; C6 (phase 14): dotted-safe structural walk — a non-tag alist
         ;; (e.g. a 2-key sym/pkg object with non-string values) passes
         ;; through with its shape intact; mapcar on a dotted pair would
         ;; TYPE-ERROR.
         (let ((vals nil) (tail tree))
           (loop :while (consp tail)
                 :do (push (untag-symbols (car tail)) vals)
                     (setf tail (cdr tail)))
           (let ((head (nreverse vals)))
             (if tail (nconc head (untag-symbols tail)) head)))))
    (t tree)))

(defun log-event-to-json (e)
  (let ((yason:*symbol-key-encoder*
          (lambda (k) (string-downcase (symbol-name k))))
        (yason:*symbol-encoder*
          (lambda (s) (string-downcase (symbol-name s)))))
    (let* ((ke (log-event-kc-event e))
           (kc (and ke (kc-event-kc ke))))
      (with-output-to-string (s)
        (yason:encode-plist
         (list "student_id" (princ-to-string (log-event-student-id e))
               "session_id" (princ-to-string (log-event-session-id e))
               "problem_id" (princ-to-string (log-event-problem-id e))
               "kc" (and kc (princ-to-string kc))
               "kc_package" (and kc (symbol-package kc) (package-name (symbol-package kc)))
               "correct" (and ke (kc-event-correct-p ke))
               "intent" (tag-symbols (log-event-intent-summary e))
               "result" (tag-symbols (log-event-result-summary e)))
         s)))))

(defun json-to-log-event (json-string)
  (let* ((a (let ((yason:*parse-object-as* :alist)) (yason:parse json-string)))
         (kc (cdr (assoc "kc" a :test #'string=)))
         (kcpkg (cdr (assoc "kc_package" a :test #'string=)))
         (pkg (or (and kcpkg (find-package kcpkg)) (find-package :mtt))))
    (make-log-event
     :seq (or (cdr (assoc "seq" a :test #'string=)) 0)
     :student-id (cdr (assoc "student_id" a :test #'string=))
     :session-id (cdr (assoc "session_id" a :test #'string=))
     :problem-id (cdr (assoc "problem_id" a :test #'string=))
     :kc-event (when kc (make-kc-event :kc (intern kc pkg)
                                       :correct-p (cdr (assoc "correct" a :test #'string=))))
     :intent-summary (untag-symbols (cdr (assoc "intent" a :test #'string=)))
     :result-summary (untag-symbols (cdr (assoc "result" a :test #'string=))))))

;; --- protocol specializations ------------------------------------------------
(defmethod log-append ((log redis-event-log) (event log-event))
  (with-redis (log)
    (let ((n (redis:red-rpush (redis-event-log-key log) (log-event-to-json event))))
      (setf (log-event-seq event) n)))   ; seq store-assigned atomically by RPUSH length
  log)

(defmethod log-all-events ((log redis-event-log))
  ;; seq is the 1-indexed LIST position (RPUSH guarantees monotonic assignment).
  ;; The stored JSON's seq field is informational; the authoritative seq comes
  ;; from the index, ensuring consistency even if the JSON was written before
  ;; the store assigned the final seq.
  (with-redis (log)
    (loop :for json :in (redis:red-lrange (redis-event-log-key log) 0 -1)
          :for idx :from 1
          :for e = (json-to-log-event json)
          :do (setf (log-event-seq e) idx)
          :collect e)))

(defmethod log-events-since ((log redis-event-log) (seq integer))
  ;; event with seq=k is at index k-1; seq > S starts at index S
  (with-redis (log)
    (loop :for json :in (redis:red-lrange (redis-event-log-key log) seq -1)
          :for idx :from (1+ seq)
          :for e = (json-to-log-event json)
          :do (setf (log-event-seq e) idx)
          :collect e)))

(defmethod log-last-seq ((log redis-event-log))
  (with-redis (log)
    (redis:red-llen (redis-event-log-key log))))

(defmethod disconnect-log ((log redis-event-log))
  "Close the cl-redis connection if open; idempotent. Does NOT create a connection."
  (let ((conn (slot-value log 'conn)))
    (when conn
      (let ((redis:*connection* conn))
        (ignore-errors (redis:disconnect)))
      (setf (slot-value log 'conn) nil)))
  log)

(defmethod serialize-event-log ((log redis-event-log))
  ;; portable export (Redis is already durable; this is a snapshot)
  (mapcar #'serialize-log-event (log-all-events log)))
