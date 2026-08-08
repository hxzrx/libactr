;;;; src/compiler.lisp — model compiler (Task 4)
;;;
;;;; Turns a model-definition produced by the reader (Task 3) into a compiled
;;;; model-definition: each production's RAW LHS/RHS patterns become typed
;;;; buffer-pattern / action structs, and each chunk-type-def's slot list is
;;;; expanded with its ancestors' slots (parent-first, deduped).
;;;
;;;; RAW format produced by the reader (src/reader.lisp):
;;;;   * Regular buffer pattern:  (buffer modifier raw-slot-tests)
;;;;       - buffer    : symbol (goal, retrieval, ...)
;;;;       - modifier  : one of := :+ :- :?  (= match, + request, - clear,
;;;;                                          ? state query)
;;;;       - raw-slot-tests : list of (slot kind value) triples where kind is
;;;;                          :raw (positive) or :raw-neg (negated).  The ISA
;;;;                          test is stored as the triple (isa :raw type).
;;;;   * Special RHS action:     (action-name :! raw-args)
;;;;       - action-name : interned name with the bangs stripped (output, eval,
;;;;                       bind, ...)
;;;;       - raw-args    : the flat tail after the marker (e.g. ((=answer)))
;;;
;;;; Variable convention (matches the reader/matcher): a symbol whose name
;;;; starts with #\= is a variable.
;;;;
;;;; compile-model MUTATES its argument (overwriting production lhs/rhs and
;;;; rewriting chunk-type-def slots) but takes no global state — it is a pure
;;;; transform of its argument and returns that same argument.
(in-package :mtt)

;; ------------------------------------------------------------------ helpers

(defun variable-p (x)
  "True when X is a symbol whose name starts with #\= (a pattern variable)."
  (and (symbolp x)
       (plusp (length (symbol-name x)))
       (char= (char (symbol-name x) 0) #\=)))

(defun classify (raw-kind value)
  "Classify a raw slot test into a slot-test kind.
   RAW-KIND is :raw (positive) or :raw-neg (negated) — the reader's tag.
   Returns :literal, :variable, or :negation."
  (ecase raw-kind
    (:raw     (if (variable-p value) :variable :literal))
    (:raw-neg :negation)))

(defun build-slot-test (raw)
  "Build a typed slot-test from a reader (slot kind value) triple.
   - :raw variable  -> kind :variable,  operand = variable name
   - :raw literal   -> kind :literal,   operand = literal value
   - :raw-neg       -> kind :negation,  operand = (inner-kind . value) where
                       inner-kind is :variable or :literal (per types.lisp)."
  (destructuring-bind (slot kind value) raw
    (let ((classified (classify kind value)))
      (make-slot-test
       slot classified
       (case classified
         (:variable value)
         (:negation (if (variable-p value)
                        (cons :variable value)
                        (cons :literal value)))
         (otherwise value))))))

;; ----------------------------------------------- chunk-type inheritance merge

(defun merge-chunk-type-slots (ct-table)
  "Expand every chunk-type-def's slots to include inherited slots.
   Parent slots come first, then own slots, de-duplicated
   (remove-duplicates keeps the first occurrence by default, so a slot
   declared by both parent and child stays in the parent position).  Cycles
   are guarded by a SEEN set.  Mutates ct-table in place; returns it."
  (labels ((all-slots (name seen)
             "Ancestors' slots (depth-first) followed by NAME's own slots."
             (let ((ct (gethash name ct-table)))
               (if (or (null ct) (member name seen :test #'eq))
                   nil
                   (append (all-slots (chunk-type-def-parent ct)
                                      (cons name seen))
                           (chunk-type-def-slots ct))))))
    (maphash (lambda (name ct)
               (declare (ignore name))
               (setf (chunk-type-def-slots ct)
                     (remove-duplicates
                      (all-slots (chunk-type-def-name ct) nil))))
             ct-table)
    ct-table))

;; --------------------------------------------------------- pattern / action

(defun isa-triple-p (triple)
  "True when TRIPLE is the reader's ISA test (isa :raw type).
   Compared by NAME, not EQ: the reader interns the model file's symbols in the
   caller's package, so the slot symbol may live in any package."
  (and (consp triple)
       (symbolp (first triple))
       (string= (symbol-name (first triple)) "ISA")))

(defun compile-pattern (raw)
  "Compile a raw LHS buffer pattern into a buffer-pattern struct.
   The ISA triple (isa :raw type) is lifted into buffer-pattern-type-name and
   removed from slot-tests; every remaining triple becomes a typed slot-test.
   Returns NIL for a special action (action-name :! ...) — those are RHS-only,
   never valid on the LHS; compile-model drops NILs."
  (destructuring-bind (buffer modifier raw-tests) raw
    (declare (type symbol buffer))
    (when (eq modifier :!)
      (return-from compile-pattern nil))
    (let ((isa-test (find-if #'isa-triple-p raw-tests)))
      (make-buffer-pattern
       buffer
       modifier                                    ; := or :? per reader
       (when isa-test (third isa-test))           ; the ISA type value
       (mapcar #'build-slot-test
               (remove-if #'isa-triple-p raw-tests))))))

(defun compile-action (raw)
  "Compile a raw RHS element into an action struct.
   Two shapes (both three-element lists, dispatched on the modifier):
     (buffer modifier raw-tests)  -> buffer action; spec is a (slot . value)
                                     alist of the positive (:raw) triples (ISA
                                     included, since +retrieval> needs it).
     (name     :!      raw-args)  -> special action; spec is raw-args verbatim."
  (destructuring-bind (buffer modifier raw-tests) raw
    (declare (type symbol buffer))
    (if (eq modifier :!)
        (make-action :! buffer raw-tests)
        (make-action
         modifier buffer
         (loop :for (slot kind value) :in raw-tests
               :when (eq kind :raw)
                 :collect (cons slot value))))))

;; ------------------------------------------------------------- entry point

(defun compile-model (md)
  "Compile a model-definition in place: merge chunk-type inheritance, then
   rewrite every production's lhs (buffer-pattern) and rhs (action).  Returns
   MD.  No global state — pure transform of the argument."
  (merge-chunk-type-slots (model-definition-chunk-types md))
  (dolist (prod (model-definition-productions md))
    (setf (production-lhs prod)
          (remove nil (mapcar #'compile-pattern (production-lhs prod))))
    (setf (production-rhs prod)
          (mapcar #'compile-action (production-rhs prod))))
  md)
