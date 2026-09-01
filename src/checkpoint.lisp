;;;; src/checkpoint.lisp — session-state snapshot serialize/restore + recovery (Phase 4)
;;;; Pure-data serialization of a cognitive-session's solving state (spec §5.5).
;;;; Recovery: solving state rebuilds from checkpoint (post-checkpoint window is
;;;; lost by design — student redoes); the retained event log has ALL events so
;;;; mastery recomputation (Phase 6) is lossless.
(in-package :mtt)

;; --- chunk / buffer-state pure-data serialization ----------------------------
(defun serialize-chunk (chunk)
  "chunk -> (isa . ((slot . val) ...)); nil buffer -> nil."
  (when chunk
    (cons (chunk-isa chunk)
          (mapcar (lambda (cell) (cons (car cell) (cdr cell)))
                  (chunk-slots chunk)))))

(defun deserialize-chunk (data)
  "(isa . ((slot . val) ...)) -> fresh chunk; nil -> nil."
  (when data
    (make-chunk :isa (car data)
                :slots (mapcar (lambda (cell) (cons (car cell) (cdr cell)))
                               (cdr data)))))

(defun serialize-buffer-state (state)
  "buffer-state hash -> alist ((buffer-name . serialized-chunk-or-nil) ...)."
  (let (acc)
    (maphash (lambda (buffer chunk) (push (cons buffer (serialize-chunk chunk)) acc)) state)
    acc))

(defun deserialize-buffer-state (data)
  "alist -> fresh buffer-state hash."
  (let ((state (make-buffer-state)))
    (dolist (entry data state)
      (setf (buffer-chunk state (car entry)) (deserialize-chunk (cdr entry))))))

;; --- checkpoint-session method (generic declared in session.lisp) ------------
;; Replaces the temporary default method from Task 2.
(defmethod checkpoint-session ((session cognitive-session))
  "Snapshot the session's solving state to pure data. Excludes the read-only
model (shared; worker reloads it) and the event log (retained separately)."
  (list :session-id (session-id session)
        :student-id (session-student-id session)
        :problem-id (session-problem-id session)
        :model-id (session-model-id session)
        :step-count (session-step-count session)
        :status (session-status session)
        :last-seq (log-last-seq (session-log session))   ; redo_window boundary: events with seq > this are the dropped window (Phase 6 mastery replay)
        :state (serialize-buffer-state (session-state session))
        :path (session-path session)))

(defun restore-from-checkpoint (checkpoint model &optional event-log)
  "Rebuild a cognitive-session at checkpoint-time solving state. Post-checkpoint
steps are dropped from solving state (student redoes them). Pass the retained
EVENT-LOG (holding ALL events) so mastery recomputation stays lossless. Status
resets to :active so the session can continue stepping."
  (let ((s (make-instance 'cognitive-session
                          :model model
                          :state (deserialize-buffer-state (getf checkpoint :state))
                          :event-log (or event-log (make-event-log))
                          :student-id (getf checkpoint :student-id)
                          :problem-id (getf checkpoint :problem-id)
                          :model-id (getf checkpoint :model-id)
                          :session-id (getf checkpoint :session-id))))
    ;; cosmetic#4 (phase 14): the integer default lives HERE (the consumer),
    ;; not in the codec — getf's default only fires on an ABSENT key, while a
    ;; checkpoint restored via the redis codec can carry an explicit nil.
    (setf (session-path s) (getf checkpoint :path)
          (session-step-count s) (or (getf checkpoint :step-count) 0))
    s))  ; status defaults to :active (initform)
