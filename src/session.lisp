;;;; src/session.lisp — cognitive-session (CLOS) + lifecycle (Phase 4)
;;;; A thin wrapper over the pure trace-step: holds per-instance PRIVATE mutable
;;;; state (buffer-state, path) and an authoritative event-log. step-session
;;;; threads trace-step's returns back into the session and appends an event.
;;;; NEVER global mutable state — all mutability lives in this CLOS instance.
(in-package :mtt)

(defclass cognitive-session ()
  ((model       :reader  session-model       :initarg :model)
   (state       :accessor session-state      :initarg :state)
   (path        :accessor session-path       :initarg :path :initform nil)
   (event-log   :accessor session-log        :initarg :event-log)
   (student-id  :reader  session-student-id  :initarg :student-id)
   (problem-id  :reader  session-problem-id  :initarg :problem-id)
   (model-id    :reader  session-model-id    :initarg :model-id :initform nil)
   (session-id  :reader  session-id          :initarg :session-id :initform (gensym "session"))
   (step-count  :accessor session-step-count :initform 0)
   (status      :accessor session-status     :initform :active)))

;; Declared here (method in checkpoint.lisp) so step/end can call it without a
;; forward-reference compile warning. checkpoint.lisp adds the specializing method.
(defgeneric checkpoint-session (session)
  (:documentation "Snapshot SESSION's solving state to pure data (see checkpoint.lisp)."))

;; Temporary default method returning nil — keeps Task 2 independently green.
;; Task 3 Step 4 replaces this with a specializing method on cognitive-session.
(defmethod checkpoint-session ((session t)) nil)

(defun start-session (model student-id problem-id
                      &key model-id event-log session-id)
  "Create a cognitive-session for one student x one problem. State initializes
from a deep copy of the model's initial-goal (isolation: each session owns its
chunks). A fresh event-log is made unless one is passed (a caller may share a
student-level log across sessions).

The goal buffer's symbol is interned in the MODEL's symbol-package (read-model-file
interns all model symbols in *PACKAGE* of its caller, so the goal buffer name must
match that same package — buffer-state uses eq hash). We derive it from the
initial-goal's isa, which is a model-package symbol."
  (let* ((log (or event-log (make-event-log)))
         (state (make-buffer-state))
         (init-goal (model-definition-initial-goal model)))
    (when init-goal
      (let ((goal-buf (intern "GOAL" (symbol-package (chunk-isa init-goal)))))
        (setf (buffer-chunk state goal-buf)
              (copy-chunk-deep init-goal))))
    (make-instance 'cognitive-session
                   :model model
                   :state state
                   :event-log log
                   :student-id student-id
                   :problem-id problem-id
                   :model-id model-id
                   :session-id (or session-id (gensym "session")))))

(defun step-session (session intent &key checkpoint-every)
  "Trace one student step. Thin wrapper over pure trace-step: on on-path adopt
the advanced state/path; ALWAYS append a log-event; return the trace-result
(unchanged semantics). When CHECKPOINT-EVERY is a positive integer and the new
step-count is a multiple of it, also take a checkpoint (diagnostic only)."
  (let ((r (trace-step (session-model session)
                       (session-state session)
                       (session-path session)
                       intent)))
    (when (eq (trace-result-status r) :on-path)
      (setf (session-state session) (trace-result-next-state r))
      (setf (session-path session) (trace-result-next-path r)))
    (incf (session-step-count session))
    (let ((log (session-log session)))
      (log-append log
                  (make-log-event
                   :seq (1+ (log-last-seq log))
                   :timestamp (get-universal-time)
                   :student-id (session-student-id session)
                   :session-id (session-id session)
                   :problem-id (session-problem-id session)
                   :kc-event (first (trace-result-events r))
                   :intent-summary (step-intent-assignments intent)
                   :result-summary (summarize-trace-result r))))
    (when (and checkpoint-every
               (plusp checkpoint-every)
               (zerop (mod (session-step-count session) checkpoint-every)))
      (checkpoint-session session))
    r))

(defun end-session (session)
  "Mark session ended, take a final checkpoint, return a summary plist."
  (setf (session-status session) :ended)
  (let ((cp (checkpoint-session session)))
    (list :session-id (session-id session)
          :step-count (session-step-count session)
          :event-count (length (log-all-events (session-log session)))
          :status (session-status session)
          :path (session-path session)
          :final-checkpoint cp)))
