;;;; src/student-session.lisp — cross-problem student-session (Phase 5, pure)
;;;; The upper session layer (spec §5.1): a student-session owns ONE event log
;;;; shared across all of that student's cognitive-sessions (via Phase 4's
;;;; start-session :event-log injection point) so cross-problem mastery is one
;;;; read. Pure: no HTTP, no Redis, no locks, no defvar.
(in-package :mtt)

(defclass student-session ()
  ((student-id :reader student-session-student-id :initarg :student-id)
   (event-log  :reader student-session-log       :initarg :event-log)
   (sessions   :accessor student-session-sessions :initform nil)   ; list of cognitive-session ids (bookkeeping)
   (status     :accessor student-session-status   :initform :active))) ; :active | :ended

(defun student-session-p (x) (typep x 'student-session))

(defun start-student-session (student-id &key event-log)
  "Create a student-session. A fresh in-memory event-log is made unless one is
passed (the service layer passes a redis-event-log for durable storage)."
  (make-instance 'student-session
                 :student-id student-id
                 :event-log (or event-log (make-event-log))))

(defun register-cognitive-session (student-session cognitive-session)
  "Record a cognitive-session id under this student (bookkeeping for mastery/lifecycle)."
  (pushnew (session-id cognitive-session)
           (student-session-sessions student-session)))

(defun end-student-session (student-session)
  "Mark ended and return a summary plist."
  (setf (student-session-status student-session) :ended)
  (list :student-id (student-session-student-id student-session)
        :sessions (student-session-sessions student-session)
        :event-count (length (log-all-events (student-session-log student-session)))
        :status :ended))

(defun compute-mastery (events)
  "EVENTS: a list of log-event. Returns a list of plists
  (:kc <kc> :correct <n> :total <n> :accuracy <float>), one per kc, sorted by kc.
  Events with no kc-event or nil kc (unclassified off-path) are skipped."
  (let ((buckets (make-hash-table :test #'equal)))   ; kc -> (correct . total)
    (dolist (e events)
      (let* ((ke (log-event-kc-event e))
             (kc (and ke (kc-event-kc ke))))
        (when kc
          (let* ((correct-p (kc-event-correct-p ke))
                 (cell (or (gethash kc buckets) (cons 0 0))))
            (incf (cdr cell))                ; total
            (when correct-p (incf (car cell))) ; correct
            (setf (gethash kc buckets) cell)))))
    (let (result)
      (maphash (lambda (kc cell)
                 (push (list :kc kc
                             :correct (car cell)
                             :total (cdr cell)
                             :accuracy (if (zerop (cdr cell))
                                           0.0d0
                                           (coerce (/ (car cell) (cdr cell)) 'double-float)))
                       result))
               buckets)
      (sort result #'string< :key (lambda (p) (princ-to-string (getf p :kc)))))))
