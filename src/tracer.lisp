;;;; src/tracer.lisp — model-tracing diagnosis layer (Phase 3)
;;;; Pure functions atop the matcher: apply a production's RHS to a buffer-state,
;;;; judge whether a student step-intent is covered (on-path), and emit KC events.
;;;; No global mutable state — trace-step threads state explicitly (Approach A).
(in-package :mtt)

;; ------------------------------------------------------------------ copy helpers

(defun copy-buffer-state (state)
  "Shallow-copy a buffer-state hash-table (chunks shared until apply-rhs copies
   the one it modifies). Never mutates STATE."
  (let ((copy (make-buffer-state)))
    (maphash (lambda (k v) (setf (gethash k copy) v)) state)
    copy))

(defun copy-chunk (chunk)
  "Copy a chunk (new slots alist) so slot writes don't mutate the original."
  (make-chunk :isa (chunk-isa chunk)
              :slots (copy-alist (chunk-slots chunk))))

(defun resolve-rhs-value (value bindings)
  "Resolve an RHS value: a variable (=x) → its binding; a literal → itself.
   An unbound variable is returned as-is (addition's RHS values are all
   LHS-bound or literal, so this branch is not exercised by the corpus)."
  (if (and (symbolp value)
           (plusp (length (symbol-name value)))
           (char= (char (symbol-name value) 0) #\=))
      (let ((b (assoc value bindings)))
        (if b (cdr b) value))
      value))

(defun apply-rhs (actions state bindings)
  "Apply ACTIONS (a production's RHS) to a COPIED buffer-state, resolving
   variables via BINDINGS. Returns a fresh buffer-state; never mutates STATE.
   - :=  set each (slot . value) in spec (value resolved; chunk copied first).
   - :-  clear the buffer (chunk → nil).
   - :+ / :!  no buffer-state change (retrieval requests / output / bind are
              mechanism, not goal/imaginal state for tracing) — skipped."
  (let ((next (copy-buffer-state state)))
    (dolist (act actions next)
      (ecase (action-modifier act)
        (:= (let* ((buffer (action-buffer act))
                   (chunk (buffer-chunk next buffer)))
              (when chunk
                (let ((new-chunk (copy-chunk chunk)))
                  (dolist (pair (action-spec act))
                    (let ((slot (car pair))
                          (val (resolve-rhs-value (cdr pair) bindings))
                          (entry (assoc (car pair) (chunk-slots new-chunk))))
                      (if entry
                          (setf (cdr entry) val)
                          (setf (chunk-slots new-chunk)
                                (acons slot val (chunk-slots new-chunk))))))
                  (setf (buffer-chunk next buffer) new-chunk)))))
        (:- (setf (buffer-chunk next (action-buffer act)) nil))
        ((:+ :!) nil)))))
