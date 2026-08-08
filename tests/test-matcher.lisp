;;;; tests/test-matcher.lisp — matcher tests (Task 5)
;;;
;;;; Binding contract: the brief's three tests (match-initialize-addition,
;;;; non-match-when-sum-not-nil, cross-pattern-unification) are the binding
;;;; contract, adapted to the actual compiled structures produced by Tasks 2-4:
;;;;   - slot-test kinds :literal/:variable/:negation with operand shapes
;;;;     literal->value, variable->var-symbol, negation->(inner-kind . inner-val)
;;;;   - buffer-pattern with buffer/modifier/type-name/slot-tests
;;;;   - chunk with isa + slots (alist)
;;;;   - buffer-state hash (eq) of buffer-name -> chunk
;;;; Accessors for slot-test / buffer-pattern are not exported from :mtt, so the
;;;; tests reach them via the double-colon internal reader (as test-types /
;;;; test-compiler already do).
;;;;
;;;; Additional tests lock in spec intent for ISA subtyping (with a hand-built
;;;; inheritance table), matching-productions returning multiple winners, and
;;;; model-matching-productions convenience.
(in-package :mtt/test)
(in-suite :mtt)

;;; *addition-model* is defined in test-reader.lisp (loaded earlier by the asd
;;; serial order); we reuse it here.

(defun load-compiled-addition ()
  (mtt:compile-model (mtt:read-model-file *addition-model*)))

(defun find-compiled-production (md name)
  (find name (mtt:model-definition-productions md) :key #'mtt:production-name))

;;; ---------- Binding tests (brief Steps 1 & 6) ----------

(test match-initialize-addition
  ;; initialize-addition LHS: =goal> ISA add, arg1 =num1, arg2 =num2, sum nil.
  ;; With a fresh goal (arg1 five, arg2 two, sum nil) the matcher must bind
  ;; =num1->five and =num2->two.
  (let* ((md (load-compiled-addition))
         (goal (mtt:make-chunk :isa 'add
                               :slots '((arg1 . five) (arg2 . two) (sum . nil))))
         (state (mtt:make-buffer-state)))
    (setf (mtt:buffer-chunk state 'goal) goal)
    (let ((prod (find-compiled-production md 'initialize-addition)))
      (let ((b (mtt:match-production prod state (mtt:model-definition-chunk-types md))))
        (is-true b)
        (is (eq (cdr (assoc '=num1 b)) 'five))
        (is (eq (cdr (assoc '=num2 b)) 'two))))))

(test non-match-when-sum-not-nil
  ;; Same production, but sum is non-nil -> the :literal test (sum nil) fails.
  (let* ((md (load-compiled-addition))
         (goal (mtt:make-chunk :isa 'add
                               :slots '((arg1 . five) (arg2 . two) (sum . seven))))
         (state (mtt:make-buffer-state)))
    (setf (mtt:buffer-chunk state 'goal) goal)
    (let ((prod (find-compiled-production md 'initialize-addition)))
      (is (null (mtt:match-production prod state
                                      (mtt:model-definition-chunk-types md)))))))

(test cross-pattern-unification
  ;; increment-count LHS:
  ;;   =goal>      ISA add, sum =sum, count =count
  ;;   =retrieval> ISA number, number =count, next =newcount
  ;; =count is shared across goal.count and retrieval.number -> must unify.
  (let* ((md (load-compiled-addition))
         (ct  (mtt:model-definition-chunk-types md))
         (state (mtt:make-buffer-state))
         (prod (find-compiled-production md 'increment-count)))
    (setf (mtt:buffer-chunk state 'goal)
          (mtt:make-chunk :isa 'add :slots '((sum . five) (count . zero))))
    (setf (mtt:buffer-chunk state 'retrieval)
          (mtt:make-chunk :isa 'number :slots '((number . zero) (next . one))))
    (let ((b (mtt:match-production prod state ct)))
      (is-true b)
      (is (eq (cdr (assoc '=count b)) 'zero))
      (is (eq (cdr (assoc '=newcount b)) 'one))
      ;; =sum is also bound (to goal.sum = five); lock that in.
      (is (eq (cdr (assoc '=sum b)) 'five)))
    ;; Inconsistent: retrieval.number=one but goal.count=zero -> =count conflict.
    (setf (mtt:buffer-chunk state 'retrieval)
          (mtt:make-chunk :isa 'number :slots '((number . one) (next . two))))
    (is (null (mtt:match-production prod state ct)))))

;;; ---------- Additional tests: spec intent & verified edge cases ----------

(test match-returns-fresh-bindings-each-call
  ;; Pure function: two successive matches against the same state must not bleed
  ;; bindings into each other (no global mutable state).  Use a production that
  ;; binds variables, run it twice, and confirm the second result is independent.
  (let* ((md (load-compiled-addition))
         (ct  (mtt:model-definition-chunk-types md))
         (goal (mtt:make-chunk :isa 'add
                               :slots '((arg1 . five) (arg2 . two) (sum . nil))))
         (state (mtt:make-buffer-state))
         (prod (find-compiled-production md 'initialize-addition)))
    (setf (mtt:buffer-chunk state 'goal) goal)
    (let ((b1 (mtt:match-production prod state ct))
          (b2 (mtt:match-production prod state ct)))
      (is-true b1)
      (is-true b2)
      ;; Same value but distinct alist objects (not shared state).
      (is (not (eq b1 b2)))
      (is (equal b1 b2)))))

(test match-fails-when-buffer-empty
  ;; No goal chunk in state -> the goal pattern cannot match.
  (let* ((md (load-compiled-addition))
         (state (mtt:make-buffer-state))
         (prod (find-compiled-production md 'initialize-addition)))
    (is (null (mtt:match-production prod state
                                    (mtt:model-definition-chunk-types md))))))

(test match-fails-on-isa-mismatch
  ;; Chunk of type number in goal, but pattern requires ISA add -> no match.
  (let* ((md (load-compiled-addition))
         (state (mtt:make-buffer-state))
         (prod (find-compiled-production md 'initialize-addition)))
    (setf (mtt:buffer-chunk state 'goal)
          (mtt:make-chunk :isa 'number :slots '((number . one))))
    (is (null (mtt:match-production prod state
                                    (mtt:model-definition-chunk-types md))))))

(test isa-subtype-matches-via-parent-chain
  ;; Build a tiny ct-table: animal -> dog.  A pattern requiring ISA animal must
  ;; match a chunk whose isa is dog (a subtype).  The pattern also binds a
  ;; variable (=breed) so the match is observable under the public contract
  ;; (match-production returns non-nil bindings on success).
  (let ((ct (make-hash-table :test 'eq)))
    (setf (gethash 'animal ct)
          (mtt:make-chunk-type-def :name 'animal :slots '(legs) :parent nil))
    (setf (gethash 'dog ct)
          (mtt:make-chunk-type-def :name 'dog :slots '(breed) :parent 'animal))
    (let* ((bp (mtt::make-buffer-pattern 'goal := 'animal
              (list (mtt::make-slot-test 'legs :literal 4)
                    (mtt::make-slot-test 'breed :variable '=breed))))
           (prod (mtt::make-production 'bark (list bp) nil nil :correct))
           (state (mtt:make-buffer-state)))
      (setf (mtt:buffer-chunk state 'goal)
            (mtt:make-chunk :isa 'dog :slots '((legs . 4) (breed . lab))))
      (let ((b (mtt:match-production prod state ct)))
        (is-true b)
        (is (eq (cdr (assoc '=breed b)) 'lab))))))

(test negation-with-bound-variable
  ;; increment-sum LHS goal pattern has "- arg2 =count" (a :negation whose inner
  ;; is :variable).  When =count is already bound (by the positive count =count
  ;; test that precedes it), the negation must compare against the bound value.
  ;; goal: arg2 = count value -> negation "arg2 != count-value" FAILS.
  (let* ((md (load-compiled-addition))
         (ct  (mtt:model-definition-chunk-types md))
         (state (mtt:make-buffer-state))
         (prod (find-compiled-production md 'increment-sum)))
    (setf (mtt:buffer-chunk state 'goal)
          ;; count = three, arg2 = three -> "- arg2 =count" means arg2 != three
          ;; -> FALSE, so the production must NOT match (goal side alone fails).
          (mtt:make-chunk :isa 'add
                          :slots '((sum . five) (count . three) (arg2 . three))))
    (setf (mtt:buffer-chunk state 'retrieval)
          (mtt:make-chunk :isa 'number
                          :slots '((number . five) (next . six))))
    (is (null (mtt:match-production prod state ct))))
  ;; And the positive case: arg2 differs from count -> negation passes.
  (let* ((md (load-compiled-addition))
         (ct  (mtt:model-definition-chunk-types md))
         (state (mtt:make-buffer-state))
         (prod (find-compiled-production md 'increment-sum)))
    (setf (mtt:buffer-chunk state 'goal)
          (mtt:make-chunk :isa 'add
                          :slots '((sum . five) (count . three) (arg2 . two))))
    (setf (mtt:buffer-chunk state 'retrieval)
          (mtt:make-chunk :isa 'number
                          :slots '((number . five) (next . six))))
    (let ((b (mtt:match-production prod state ct)))
      (is-true b)
      (is (eq (cdr (assoc '=count b)) 'three))
      (is (eq (cdr (assoc '=newsum b)) 'six)))))

(test matching-productions-returns-all-matches
  ;; With the initial addition goal, exactly one production (initialize-addition)
  ;; should match.  matching-productions returns a list of (production . bindings)
  ;; pairs.
  (let* ((md (load-compiled-addition))
         (state (mtt:make-buffer-state)))
    (setf (mtt:buffer-chunk state 'goal)
          (mtt:make-chunk :isa 'add
                          :slots '((arg1 . five) (arg2 . two) (sum . nil))))
    (let ((results (mtt:matching-productions (mtt:model-definition-productions md)
                                             state
                                             (mtt:model-definition-chunk-types md))))
      (is (= 1 (length results)))
      (is (eq (mtt:production-name (caar results)) 'initialize-addition))
      (is (eq (cdr (assoc '=num1 (cdar results))) 'five)))))

(test model-matching-productions-convenience
  ;; model-matching-productions threads the model's productions + ct-table
  ;; automatically.
  (let* ((md (load-compiled-addition))
         (state (mtt:make-buffer-state)))
    (setf (mtt:buffer-chunk state 'goal)
          (mtt:make-chunk :isa 'add
                          :slots '((arg1 . five) (arg2 . two) (sum . nil))))
    (let ((results (mtt:model-matching-productions md state)))
      (is (= 1 (length results)))
      (is (eq (mtt:production-name (caar results)) 'initialize-addition)))))

(test matcher-does-not-mutate-state
  ;; Pure-function guarantee: the buffer-state and its chunks are unchanged
  ;; after matching.  Confirm identity and slot values are preserved.
  (let* ((md (load-compiled-addition))
         (ct  (mtt:model-definition-chunk-types md))
         (goal (mtt:make-chunk :isa 'add
                               :slots '((arg1 . five) (arg2 . two) (sum . nil))))
         (state (mtt:make-buffer-state)))
    (setf (mtt:buffer-chunk state 'goal) goal)
    (mtt:match-production (find-compiled-production md 'initialize-addition)
                          state ct)
    (is (eq (mtt:buffer-chunk state 'goal) goal))
    (is (eq (cdr (assoc 'arg1 (mtt:chunk-slots goal))) 'five))
    (is (eq (cdr (assoc 'sum  (mtt:chunk-slots goal))) 'nil))))
