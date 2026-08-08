;;;; tests/test-tracer.lisp — Phase 3 tracer unit tests (hand-derived).
(in-package :mtt/test)
(in-suite :mtt)

(defun addition-compiled-model ()
  "Read+compile addition.lisp once; cached structurally per call is fine for tests."
  (compile-model (read-model-file
                   (asdf:system-relative-pathname "act-r" "tutorial/unit1/addition.lisp"))))

(defun find-production (md name)
  (find name (model-definition-productions md) :key #'production-name))

(defun goal-state (&rest slot-vals)
  "Build a buffer-state with a goal chunk of type ADD and given (slot value) pairs."
  (let ((st (make-buffer-state)))
    (setf (buffer-chunk st 'goal)
          (make-chunk :isa 'add :slots (loop for (s v) on slot-vals by #'cddr
                                              when s collect (cons s v))))
    st))

(test apply-rhs-initialize-addition-substitutes-bindings
  "apply-rhs on initialize-addition: RHS sum==num1 count=zero, with =num1 bound
   to five, yields goal sum=five count=zero. Addition's RHS values are all
   LHS-bindable/literal (verified), so resolution always succeeds."
  (let* ((md (addition-compiled-model))
         (prod (find-production md 'initialize-addition))
         (state (goal-state 'arg1 'five 'arg2 'two 'sum nil))
         (bindings (match-production prod state (model-definition-chunk-types md))))
    (is (not (null bindings)) "initialize-addition must match the fresh goal")
    (let ((next (apply-rhs (production-rhs prod) state bindings)))
      (is (equal 'five (chunk-slot (buffer-chunk next 'goal) 'sum)))
      (is (equal 'zero (chunk-slot (buffer-chunk next 'goal) 'count))))))

(test apply-rhs-does-not-mutate-input-state
  "apply-rhs is pure: the input state's goal chunk is unchanged after the call."
  (let* ((md (addition-compiled-model))
         (prod (find-production md 'initialize-addition))
         (state (goal-state 'arg1 'five 'arg2 'two 'sum nil))
         (bindings (match-production prod state (model-definition-chunk-types md)))
         (orig-sum (chunk-slot (buffer-chunk state 'goal) 'sum)))
    (apply-rhs (production-rhs prod) state bindings)
    (is (equal orig-sum (chunk-slot (buffer-chunk state 'goal) 'sum)))))

(test apply-rhs-terminate-clears-count-via-literal-nil
  "terminate-addition RHS sets count=nil (literal). apply-rhs reflects it."
  (let* ((md (addition-compiled-model))
         (prod (find-production md 'terminate-addition))
         (state (goal-state 'count 'two 'arg2 'two 'sum 'seven))
         (ct (model-definition-chunk-types md)))
    ;; terminate-addition also needs retrieval(number seven); build it
    (setf (buffer-chunk state 'retrieval)
          (make-chunk :isa 'number :slots '((number . seven))))
    (let ((bindings (match-production prod state ct)))
      (is (not (null bindings)))
      (let ((next (apply-rhs (production-rhs prod) state bindings)))
        (is (null (chunk-slot (buffer-chunk next 'goal) 'count)))))))
