;;;; src/tracer.lisp — model-tracing diagnosis layer (Phase 3)
;;;; Pure functions atop the matcher: apply a production's RHS to a buffer-state,
;;;; judge whether a student step-intent is covered (on-path), and emit KC events.
;;;; No global mutable state — trace-step threads state explicitly (Approach A).
(in-package :libactr)

;; ------------------------------------------------------------------ copy helpers

(defun copy-buffer-state (state)
  "Shallow-copy a buffer-state hash-table (chunks shared until apply-rhs copies
   the one it modifies). Never mutates STATE."
  (let ((copy (make-buffer-state)))
    (maphash (lambda (k v) (setf (gethash k copy) v)) state)
    copy))

(defun copy-chunk-deep (chunk)
  "Copy a chunk with a fresh slots alist so slot writes don't mutate the original.
   The DEEP copy (copy-alist) is REQUIRED: apply-rhs mutates alist cells in place
   via (setf (cdr entry) val), so the defstruct auto-copier's shallow copy would
   alias the slots alist and silently break purity."
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
                (let ((new-chunk (copy-chunk-deep chunk)))
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

(defun covers-p (intent effect-state)
  "Subset-consistent coverage: every (buffer slot value) in INTENT.assignments
   must EQUAL EFFECT-STATE's value at (buffer slot). Extra slots the production
   changed (that the student didn't express) are ignored. Any expressed slot
   that contradicts the effect → not covered."
  (every (lambda (assign)
           (destructuring-bind (buffer slot value) assign
             (let ((chunk (buffer-chunk effect-state buffer)))
               (and chunk (equal (chunk-slot chunk slot) value)))))
         (step-intent-assignments intent)))

;; Disambiguation strategy protocol.
;; A strategy is a function (covering intent path) -> (production . bindings),
;; where COVERING is a list of (production . bindings) that all cover the intent.
;; path-continuity-strategy is the Phase 3 default: deterministic definition
;; order (first). Addition/tutorial models rarely present multiple correct
;; coverings at one state, so this is reproducible and sufficient; PATH and
;; INTENT are accepted so action-type anchoring / confidence ranking can be
;; dropped in later without changing trace-step.
(defun path-continuity-strategy (covering intent path)
  "Default disambiguation strategy: the FIRST covering production in model
definition order (deterministic and reproducible). INTENT and PATH are
accepted (ignored here) so richer strategies can be dropped into trace-step
without changing its signature. Pure."
  (declare (ignore intent path))
  (first covering))

;; ------------------------------------------------------------------ trace-step

(defun production-kc-or-name (production)
  "KC id for an event: production-kc if set, else the production name
   (one-rule-one-KC default)."
  (or (production-kc production) (production-name production)))

(defun covering-productions-of-kind (model state intent kind)
  "Return list of (production . bindings) among productions whose KIND matches
   the given keyword (:correct or :buggy), that match STATE and whose RHS effect
   COVERS intent."
  (let ((ct (model-definition-chunk-types model))
        (prods (remove-if-not (lambda (p) (eq (production-kind p) kind))
                              (model-definition-productions model))))
    (loop :for (prod . bindings) :in (matching-productions prods state ct)
          :for effect = (apply-rhs (production-rhs prod) state bindings)
          :when (covers-p intent effect)
            :collect (cons prod bindings))))

(defun off-path-diagnosis (model state intent)
  "Off-path diagnosis: query the buggy library. If a buggy production covers
   the intent, diagnose that misconception (feedback + buggy KC, deterministic
   first match). Otherwise unclassified. STATE is never advanced off-path."
  (let ((buggy (covering-productions-of-kind model state intent :buggy)))
    (if buggy
        (let* ((choice (first buggy))            ; deterministic: first buggy match
               (prod (car choice)))
          (make-trace-result
           :status :off-path-buggy
           :production prod
           :bindings (cdr choice)
           :feedback (production-feedback prod)
           :next-state state
           :events (list (make-kc-event :kc (production-kc-or-name prod)
                                        :correct-p nil
                                        :production (production-name prod)
                                        :kind :buggy))))
        (make-trace-result
         :status :off-path
         :next-state state
         :events (list (make-kc-event :correct-p nil :kind :unclassified))))))

(defun trace-step (model state path intent &key (strategy #'path-continuity-strategy))
  "Diagnose one student step. Pure: returns a trace-result; never mutates MODEL,
   STATE, PATH, or any global. On-path → advance state/path, emit correct KC,
   record alternatives when >1 covered. Off-path → off-path-diagnosis."
  (let ((covering (covering-productions-of-kind model state intent :correct)))
    (if covering
        (let* ((choice (funcall strategy covering intent path))
               (prod (car choice))
               (bindings (cdr choice))
               (next-state (apply-rhs (production-rhs prod) state bindings))
               (alternatives (remove prod (mapcar #'car covering))))
          (make-trace-result
           :status :on-path
           :production prod
           :bindings bindings
           :next-state next-state
           :next-path (append path (list (production-name prod)))
           :events (list (make-kc-event :kc (production-kc-or-name prod)
                                        :correct-p t
                                        :production (production-name prod)
                                        :kind :correct))
           :alternatives alternatives))
        (off-path-diagnosis model state intent))))
