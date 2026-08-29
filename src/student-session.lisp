;;;; src/student-session.lisp — cross-problem student-session (Phase 5, pure)
;;;; The upper session layer (spec §5.1): a student-session owns ONE event log
;;;; shared across all of that student's cognitive-sessions (via Phase 4's
;;;; start-session :event-log injection point) so cross-problem mastery is one
;;;; read. Pure: no HTTP, no Redis, no locks, no global variables.
(in-package :mtt)

(defclass student-session ()
  ((student-id :reader student-session-student-id :initarg :student-id)
   (event-log  :reader student-session-log       :initarg :event-log)
   (sessions   :accessor student-session-sessions :initform nil)   ; list of cognitive-session ids (bookkeeping)
   (status     :accessor student-session-status   :initform :active))  ; :active | :ended
  (:documentation "Cross-problem student entity (the upper session layer):
owns ONE event-log shared by all of that student's cognitive-sessions (via
start-session :event-log injection) so cross-problem mastery is one read.
Pure bookkeeping — no HTTP, no Redis connections, no locks in this layer;
durability comes from whichever event-log backend was injected."))

(defun student-session-p (x)
  "Type predicate for student-session (defclass does not auto-generate -p)."
  (typep x 'student-session))

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

(defun compute-mastery (events &key (kt-params (make-kt-params)))
  "EVENTS: a list of log-event. Returns a list of plists
  (:kc <kc> :correct <n> :total <n> :accuracy <float> :p-l <float>), one per kc,
sorted by kc. Events with no kc-event or nil kc (unclassified off-path) are
skipped. :p-l is the Bayesian Knowledge Tracing posterior (Corbett & Anderson
4-parameter) over each kc's correct/incorrect sequence, folded from L0; it is a
deterministic derivation of the event log (recomputed every call — backend
agnostic, since EVENTS comes from log-all-events of either backend). KT-PARAMS
defaults to (make-kt-params); pass a custom set to tune L0/T/G/S."
  (let ((buckets (make-hash-table :test #'equal)))   ; kc -> (correct total rev-observations)
    (dolist (e events)
      (let* ((ke (log-event-kc-event e))
             (kc (and ke (kc-event-kc ke))))
        (when kc
          (let* ((correct-p (kc-event-correct-p ke))
                 (cell (or (gethash kc buckets) (list 0 0 nil))))
            (incf (first cell) (if correct-p 1 0))
            (incf (second cell) 1)
            (push correct-p (third cell))
            (setf (gethash kc buckets) cell)))))
    (let (result)
      (maphash (lambda (kc cell)
                 (destructuring-bind (correct total rev-obs) cell
                   (push (list :kc kc
                               :correct correct
                               :total total
                               :accuracy (if (zerop total)
                                             0.0d0
                                             (coerce (/ correct total) 'double-float))
                               :p-l (kt-posterior (nreverse rev-obs)
                                                  (kt-params-for kc kt-params)))
                         result)))
               buckets)
      (sort result #'string< :key (lambda (p) (princ-to-string (getf p :kc)))))))
