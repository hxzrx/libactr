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

(test covers-p-subset-allows-extra-slots
  "Student expresses a subset of the production's effect → covered. The rule
   may change extra internal slots the student didn't express."
  (let ((effect (goal-state 'sum 'seven 'count 'two 'arg1 'five 'arg2 'two)))
    (is (covers-p (make-step-intent :assignments '((goal sum seven))) effect))
    (is (covers-p (make-step-intent :assignments '((goal sum seven) (goal count two)))
                  effect))))

(test covers-p-rejects-contradiction
  "An expressed slot that contradicts the effect → not covered."
  (let ((effect (goal-state 'sum 'seven 'count 'two)))
    (is (not (covers-p (make-step-intent :assignments '((goal sum six))) effect)))
    (is (not (covers-p (make-step-intent :assignments '((goal sum seven) (goal count three)))
                       effect)))))

(test covers-p-empty-intent-is-vacuously-true
  "An empty intent covers any effect (callers only pass real student intents)."
  (is (covers-p (make-step-intent) (goal-state 'sum 'seven))))

(test path-continuity-strategy-picks-first-deterministically
  "Default strategy returns the first covering production (definition order);
   path/intent reserved for future richer strategies."
  (let ((p1 (make-production 'first nil nil nil :correct))
        (p2 (make-production 'second nil nil nil :correct))
        (intent (make-step-intent :assignments '((goal sum seven)))))
    (let ((choice (funcall #'path-continuity-strategy
                           (list (cons p1 '((=num1 . five)))
                                 (cons p2 '((=num1 . six))))
                           intent nil)))
      (is (eq 'first (production-name (car choice))))
      (is (equal '((=num1 . five)) (cdr choice))))))

(test trace-step-on-path-initialize-addition
  "A student 'start' intent (sum=arg1, count=zero) on the fresh goal is on-path
   via initialize-addition: status :on-path, production initialize-addition,
   advanced state has sum=five/count=zero, correct KC event emitted."
  (let* ((md (addition-compiled-model))
         (state (goal-state 'arg1 'five 'arg2 'two 'sum nil))
         (intent (make-step-intent :assignments '((goal sum five) (goal count zero))))
         (r (trace-step md state nil intent)))
    (is (eq :on-path (trace-result-status r)))
    (is (eq 'initialize-addition (production-name (trace-result-production r))))
    (is (equal 'five (chunk-slot (buffer-chunk (trace-result-next-state r) 'goal) 'sum)))
    (is (equal 'zero (chunk-slot (buffer-chunk (trace-result-next-state r) 'goal) 'count)))
    (is (equal '(initialize-addition) (trace-result-next-path r)))
    (let ((ev (first (trace-result-events r))))
      (is (eq 'initialize-addition (kc-event-kc ev)))
      (is (eq t (kc-event-correct-p ev)))
      (is (eq :correct (kc-event-kind ev))))))

(test trace-step-input-state-unchanged-on-path
  "trace-step is pure: input state is not mutated even on on-path advance."
  (let* ((md (addition-compiled-model))
         (state (goal-state 'arg1 'five 'arg2 'two 'sum nil))
         (intent (make-step-intent :assignments '((goal count zero)))))
    (trace-step md state nil intent)
    (is (null (chunk-slot (buffer-chunk state 'goal) 'count)))))

(test trace-step-off-path-unclassified-when-no-cover
  "A student intent no correct production covers → off-path unclassified; state
   unchanged. (Buggy matching arrives in Task 6.)"
  (let* ((md (addition-compiled-model))
         (state (goal-state 'arg1 'five 'arg2 'two 'sum nil))
         (intent (make-step-intent :assignments '((goal sum banana)))) ; nonsense
         (r (trace-step md state nil intent)))
    (is (eq :off-path (trace-result-status r)))
    (is (null (trace-result-production r)))
    (is (eq :unclassified (kc-event-kind (first (trace-result-events r)))))
    (is (eq state (trace-result-next-state r)))))
