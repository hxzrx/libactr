;;;; src/redis-store.lisp — Redis (AOF) durable event-log (Phase 5)
;;;; Specializes the Phase 4 event-log protocol at the seam. One Redis LIST per
;;;; log (key provided by caller, e.g. mtt:student:<id>:events); seq is
;;;; STORE-ASSIGNED atomically by RPUSH's returned length (race-free under any
;;;; writer topology). cl-redis uses a global redis:*connection*; under
;;;; thread-per-request each call dynamically rebinds *connection* to THIS log's
;;;; own connection. No global mutable state in this file.
(in-package :mtt)
(ql:quickload :cl-redis :silent t)
(ql:quickload :yason :silent t)

(defclass redis-event-log ()
  ((key  :reader redis-event-log-key :initarg :key)
   (host :reader redis-event-log-host :initarg :host :initform "127.0.0.1")
   (port :reader redis-event-log-port :initarg :port :initform 6379)
   (conn :reader redis-event-log-connection :initform nil))
  (:documentation "Append-only event log backed by a Redis LIST with AOF persistence."))

(defun redis-event-log-p (x) (typep x 'redis-event-log))

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
(defun log-event-to-json (e)
  (with-output-to-string (s)
    (yason:encode-plist
     (list "seq" (log-event-seq e)
           "student_id" (princ-to-string (log-event-student-id e))
           "session_id" (princ-to-string (log-event-session-id e))
           "problem_id" (princ-to-string (log-event-problem-id e))
           "kc" (let ((ke (log-event-kc-event e)))
                  (and ke (kc-event-kc ke) (princ-to-string (kc-event-kc ke))))
           "correct" (let ((ke (log-event-kc-event e))) (and ke (kc-event-correct-p ke)))
           "intent" (log-event-intent-summary e)
           "result" (log-event-result-summary e))
     s)))

(defun json-to-log-event (json-string)
  (let* ((a (let ((yason:*parse-object-as* :alist)) (yason:parse json-string)))
         (kc (cdr (assoc "kc" a :test #'string=))))
    (make-log-event
     :seq (or (cdr (assoc "seq" a :test #'string=)) 0)
     :student-id (cdr (assoc "student_id" a :test #'string=))
     :session-id (cdr (assoc "session_id" a :test #'string=))
     :problem-id (cdr (assoc "problem_id" a :test #'string=))
     :kc-event (when kc (make-kc-event :kc (intern kc :mtt)
                                       :correct-p (cdr (assoc "correct" a :test #'string=)))))))

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

(defmethod serialize-event-log ((log redis-event-log))
  ;; portable export (Redis is already durable; this is a snapshot)
  (mapcar #'serialize-log-event (log-all-events log)))
