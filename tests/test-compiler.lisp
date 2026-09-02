;;;; tests/test-compiler.lisp — compiler tests (Task 4)
;;;
;;;; Binding contract: the brief's classify / lhs-classification / inheritance
;;;; tests come from the task brief, adapted to (a) the &key constructors and
;;;; (b) the internal-double-colon accessor convention already established in
;;;; test-types.lisp (slot-test / buffer-pattern / action accessors are not
;;;; exported from :libactr).  Additional tests lock in spec intent verified against
;;;; tutorial/unit1/addition.lisp: ISA extraction to type-name, literal slot
;;;; classification, negation (split "- arg2 =count"), RHS buffer actions,
;;;; +retrieval> requests, and !output! special actions.
(in-package :libactr/test)
(in-suite :libactr)

;;; *addition-model* is defined in test-reader.lisp (loaded earlier by the
;;; asd serial order); we reuse it here.

;;; ---------- Binding tests (brief Steps 1 & 6) ----------

(test classify-slot-test
  ;; :raw =NUM1 -> :variable ; :raw NIL -> :literal ; :raw-neg =C -> :negation
  (is (eq (libactr::classify :raw '=num1) :variable))
  (is (eq (libactr::classify :raw 'nil) :literal))
  (is (eq (libactr::classify :raw 'add) :literal))
  (is (eq (libactr::classify :raw-neg '=c) :negation)))

(test compile-production-classifies-lhs
  (let* ((md (libactr:read-model-file *addition-model*))
         (md (libactr:compile-model md))
         (prod (find 'initialize-addition (libactr:model-definition-productions md)
                     :key #'libactr:production-name)))
    (let ((bp (find 'goal (libactr:production-lhs prod) :key #'libactr::buffer-pattern-buffer)))
      (is-true bp)
      (let ((st (find 'arg1 (libactr::buffer-pattern-slot-tests bp)
                      :key #'libactr::slot-test-slot)))
        (is-true st)
        (is (eq (libactr::slot-test-kind st) :variable))
        (is (eq (libactr::slot-test-operand st) '=num1))))))

(test chunk-type-inheritance-merge
  ;; Parent slots first, then own, deduped.  Constructs an in-memory model
  ;; because addition.lisp has no inheritance.
  (let ((ct (make-hash-table :test 'eq)))
    (setf (gethash 'animal ct)
          (libactr:make-chunk-type-def :name 'animal :slots '(legs) :parent nil))
    (setf (gethash 'dog ct)
          (libactr:make-chunk-type-def :name 'dog :slots '(breed) :parent 'animal))
    (let ((md (libactr:make-model-definition
               :chunk-types ct :chunks (make-hash-table)
               :productions nil :initial-goal nil :params nil)))
      (libactr:compile-model md)
      (is (equal (libactr:chunk-type-def-slots (gethash 'dog ct)) '(legs breed)))
      ;; Parent itself is unchanged (its own slots, no further parent).
      (is (equal (libactr:chunk-type-def-slots (gethash 'animal ct)) '(legs))))))

;;; ---------- Additional tests: spec intent & verified edge cases ----------

(defun find-compiled-production (md name)
  (find name (libactr:model-definition-productions md) :key #'libactr:production-name))

(defun find-lhs-pattern (prod buffer)
  (find buffer (libactr:production-lhs prod) :key #'libactr::buffer-pattern-buffer))

(defun find-rhs-action (prod buffer)
  (find buffer (libactr:production-rhs prod) :key #'libactr::action-buffer))

(defun find-slot-test (bp slot)
  (find slot (libactr::buffer-pattern-slot-tests bp) :key #'libactr::slot-test-slot))

(test compile-extracts-isa-to-type-name
  ;; ISA moves out of slot-tests into buffer-pattern-type-name.
  (let* ((md (libactr:compile-model (libactr:read-model-file *addition-model*)))
         (bp (find-lhs-pattern (find-compiled-production md 'initialize-addition)
                               'goal)))
    (is (eq (libactr::buffer-pattern-type-name bp) 'add))
    (is (null (find-slot-test bp 'isa)))))

(test compile-classifies-literal-slot
  ;; initialize-addition: sum nil -> :literal, operand nil.
  (let* ((md (libactr:compile-model (libactr:read-model-file *addition-model*)))
         (bp (find-lhs-pattern (find-compiled-production md 'initialize-addition)
                               'goal))
         (st (find-slot-test bp 'sum)))
    (is (eq (libactr::slot-test-kind st) :literal))
    (is (eq (libactr::slot-test-operand st) nil))))

(test compile-classifies-negation
  ;; increment-sum: "- arg2 =count" (split negation) -> :negation,
  ;; operand (:variable . =count).  Also confirms surrounding positive tests
  ;; remain positive.
  (let* ((md (libactr:compile-model (libactr:read-model-file *addition-model*)))
         (bp (find-lhs-pattern (find-compiled-production md 'increment-sum) 'goal))
         (arg2 (find-slot-test bp 'arg2))
         (count (find-slot-test bp 'count)))
    (is (eq (libactr::slot-test-kind arg2) :negation))
    (is (equal (libactr::slot-test-operand arg2) '(:variable . =count)))
    (is (eq (libactr::slot-test-kind count) :variable))))

(test compile-preserves-second-lhs-buffer
  ;; terminate-addition has TWO LHS buffer patterns (=goal> and =retrieval>);
  ;; both must be compiled, not just the first.
  (let* ((md (libactr:compile-model (libactr:read-model-file *addition-model*)))
         (prod (find-compiled-production md 'terminate-addition))
         (goal (find-lhs-pattern prod 'goal))
         (ret  (find-lhs-pattern prod 'retrieval)))
    (is-true goal)
    (is-true ret)
    (is (eq (libactr::buffer-pattern-type-name ret) 'number))
    (is (eq (libactr::slot-test-kind (find-slot-test ret 'number)) :variable))))

(test compile-rhs-buffer-action
  ;; initialize-addition RHS =goal> -> action modifier :=, buffer goal,
  ;; spec is a (slot . value) alist including the isa pair.
  (let* ((md (libactr:compile-model (libactr:read-model-file *addition-model*)))
         (act (find-rhs-action (find-compiled-production md 'initialize-addition)
                               'goal)))
    (is-true act)
    (is (eq (libactr::action-modifier act) :=))
    (is (eq (libactr::action-buffer act) 'goal))
    (is (eq (cdr (assoc 'sum   (libactr::action-spec act))) '=num1))
    (is (eq (cdr (assoc 'count (libactr::action-spec act))) 'zero))))

(test compile-rhs-retrieval-request
  ;; initialize-addition RHS +retrieval> -> action modifier :+, spec carries
  ;; isa and the bound slot.
  (let* ((md (libactr:compile-model (libactr:read-model-file *addition-model*)))
         (act (find-rhs-action (find-compiled-production md 'initialize-addition)
                               'retrieval)))
    (is-true act)
    (is (eq (libactr::action-modifier act) :+))
    (is (eq (cdr (assoc 'isa    (libactr::action-spec act))) 'number))
    (is (eq (cdr (assoc 'number (libactr::action-spec act))) '=num1))))

(test compile-rhs-special-action
  ;; terminate-addition RHS !output! (=answer) -> action modifier :!,
  ;; buffer output, spec is the raw argument list.
  (let* ((md (libactr:compile-model (libactr:read-model-file *addition-model*)))
         (prod (find-compiled-production md 'terminate-addition))
         (act (find-rhs-action prod 'output))
         (goal (find-rhs-action prod 'goal)))
    (is-true act)
    (is (eq (libactr::action-modifier act) :!))
    (is (eq (libactr::action-buffer act) 'output))
    (is (equal (libactr::action-spec act) '((=answer))))
    ;; The preceding =goal> action must stay clean (no swallowed output slot).
    (is-true goal)
    (is (null (assoc 'output (libactr::action-spec goal))))))

(test compile-model-returns-same-model
  ;; compile-model mutates and returns its argument (pure transform, no global
  ;; state).
  (let ((md (libactr:read-model-file *addition-model*)))
    (is (eq (libactr:compile-model md) md))))
