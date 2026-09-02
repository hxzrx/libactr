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
;;;; Accessors for slot-test / buffer-pattern are not exported from :libactr, so the
;;;; tests reach them via the double-colon internal reader (as test-types /
;;;; test-compiler already do).
;;;;
;;;; Additional tests lock in spec intent for ISA subtyping (with a hand-built
;;;; inheritance table), matching-productions returning multiple winners, and
;;;; model-matching-productions convenience.
(in-package :libactr/test)
(in-suite :libactr)

;;; *addition-model* is defined in test-reader.lisp (loaded earlier by the asd
;;; serial order); we reuse it here.

(defun load-compiled-addition ()
  (libactr:compile-model (libactr:read-model-file *addition-model*)))

(defun find-compiled-production (md name)
  (find name (libactr:model-definition-productions md) :key #'libactr:production-name))

;;; ---------- Binding tests (brief Steps 1 & 6) ----------

(test match-initialize-addition
  ;; initialize-addition LHS: =goal> ISA add, arg1 =num1, arg2 =num2, sum nil.
  ;; With a fresh goal (arg1 five, arg2 two, sum nil) the matcher must bind
  ;; =num1->five and =num2->two.
  (let* ((md (load-compiled-addition))
         (goal (libactr:make-chunk :isa 'add
                               :slots '((arg1 . five) (arg2 . two) (sum . nil))))
         (state (libactr:make-buffer-state)))
    (setf (libactr:buffer-chunk state 'goal) goal)
    (let ((prod (find-compiled-production md 'initialize-addition)))
      (let ((b (libactr:match-production prod state (libactr:model-definition-chunk-types md))))
        (is-true b)
        (is (eq (cdr (assoc '=num1 b)) 'five))
        (is (eq (cdr (assoc '=num2 b)) 'two))))))

(test non-match-when-sum-not-nil
  ;; Same production, but sum is non-nil -> the :literal test (sum nil) fails.
  (let* ((md (load-compiled-addition))
         (goal (libactr:make-chunk :isa 'add
                               :slots '((arg1 . five) (arg2 . two) (sum . seven))))
         (state (libactr:make-buffer-state)))
    (setf (libactr:buffer-chunk state 'goal) goal)
    (let ((prod (find-compiled-production md 'initialize-addition)))
      (is (null (libactr:match-production prod state
                                      (libactr:model-definition-chunk-types md)))))))

(test cross-pattern-unification
  ;; increment-count LHS:
  ;;   =goal>      ISA add, sum =sum, count =count
  ;;   =retrieval> ISA number, number =count, next =newcount
  ;; =count is shared across goal.count and retrieval.number -> must unify.
  (let* ((md (load-compiled-addition))
         (ct  (libactr:model-definition-chunk-types md))
         (state (libactr:make-buffer-state))
         (prod (find-compiled-production md 'increment-count)))
    (setf (libactr:buffer-chunk state 'goal)
          (libactr:make-chunk :isa 'add :slots '((sum . five) (count . zero))))
    (setf (libactr:buffer-chunk state 'retrieval)
          (libactr:make-chunk :isa 'number :slots '((number . zero) (next . one))))
    (let ((b (libactr:match-production prod state ct)))
      (is-true b)
      (is (eq (cdr (assoc '=count b)) 'zero))
      (is (eq (cdr (assoc '=newcount b)) 'one))
      ;; =sum is also bound (to goal.sum = five); lock that in.
      (is (eq (cdr (assoc '=sum b)) 'five)))
    ;; Inconsistent: retrieval.number=one but goal.count=zero -> =count conflict.
    (setf (libactr:buffer-chunk state 'retrieval)
          (libactr:make-chunk :isa 'number :slots '((number . one) (next . two))))
    (is (null (libactr:match-production prod state ct)))))

;;; ---------- Additional tests: spec intent & verified edge cases ----------

(test match-returns-fresh-bindings-each-call
  ;; Pure function: two successive matches against the same state must not bleed
  ;; bindings into each other (no global mutable state).  Use a production that
  ;; binds variables, run it twice, and confirm the second result is independent.
  (let* ((md (load-compiled-addition))
         (ct  (libactr:model-definition-chunk-types md))
         (goal (libactr:make-chunk :isa 'add
                               :slots '((arg1 . five) (arg2 . two) (sum . nil))))
         (state (libactr:make-buffer-state))
         (prod (find-compiled-production md 'initialize-addition)))
    (setf (libactr:buffer-chunk state 'goal) goal)
    (let ((b1 (libactr:match-production prod state ct))
          (b2 (libactr:match-production prod state ct)))
      (is-true b1)
      (is-true b2)
      ;; Same value but distinct alist objects (not shared state).
      (is (not (eq b1 b2)))
      (is (equal b1 b2)))))

(test match-fails-when-buffer-empty
  ;; No goal chunk in state -> the goal pattern cannot match.
  (let* ((md (load-compiled-addition))
         (state (libactr:make-buffer-state))
         (prod (find-compiled-production md 'initialize-addition)))
    (is (null (libactr:match-production prod state
                                    (libactr:model-definition-chunk-types md))))))

(test match-fails-on-isa-mismatch
  ;; Chunk of type number in goal, but pattern requires ISA add -> no match.
  (let* ((md (load-compiled-addition))
         (state (libactr:make-buffer-state))
         (prod (find-compiled-production md 'initialize-addition)))
    (setf (libactr:buffer-chunk state 'goal)
          (libactr:make-chunk :isa 'number :slots '((number . one))))
    (is (null (libactr:match-production prod state
                                    (libactr:model-definition-chunk-types md))))))

(test isa-subtype-matches-via-parent-chain
  ;; Build a tiny ct-table: animal -> dog.  A pattern requiring ISA animal must
  ;; match a chunk whose isa is dog (a subtype).  The pattern also binds a
  ;; variable (=breed) so the match is observable under the public contract
  ;; (match-production returns non-nil bindings on success).
  (let ((ct (make-hash-table :test 'eq)))
    (setf (gethash 'animal ct)
          (libactr:make-chunk-type-def :name 'animal :slots '(legs) :parent nil))
    (setf (gethash 'dog ct)
          (libactr:make-chunk-type-def :name 'dog :slots '(breed) :parent 'animal))
    (let* ((bp (libactr::make-buffer-pattern 'goal := 'animal
              (list (libactr::make-slot-test 'legs :literal 4)
                    (libactr::make-slot-test 'breed :variable '=breed))))
           (prod (libactr::make-production 'bark (list bp) nil nil :correct))
           (state (libactr:make-buffer-state)))
      (setf (libactr:buffer-chunk state 'goal)
            (libactr:make-chunk :isa 'dog :slots '((legs . 4) (breed . lab))))
      (let ((b (libactr:match-production prod state ct)))
        (is-true b)
        (is (eq (cdr (assoc '=breed b)) 'lab))))))

(test negation-with-bound-variable
  ;; increment-sum LHS goal pattern has "- arg2 =count" (a :negation whose inner
  ;; is :variable).  When =count is already bound (by the positive count =count
  ;; test that precedes it), the negation must compare against the bound value.
  ;; goal: arg2 = count value -> negation "arg2 != count-value" FAILS.
  (let* ((md (load-compiled-addition))
         (ct  (libactr:model-definition-chunk-types md))
         (state (libactr:make-buffer-state))
         (prod (find-compiled-production md 'increment-sum)))
    (setf (libactr:buffer-chunk state 'goal)
          ;; count = three, arg2 = three -> "- arg2 =count" means arg2 != three
          ;; -> FALSE, so the production must NOT match (goal side alone fails).
          (libactr:make-chunk :isa 'add
                          :slots '((sum . five) (count . three) (arg2 . three))))
    (setf (libactr:buffer-chunk state 'retrieval)
          (libactr:make-chunk :isa 'number
                          :slots '((number . five) (next . six))))
    (is (null (libactr:match-production prod state ct))))
  ;; And the positive case: arg2 differs from count -> negation passes.
  (let* ((md (load-compiled-addition))
         (ct  (libactr:model-definition-chunk-types md))
         (state (libactr:make-buffer-state))
         (prod (find-compiled-production md 'increment-sum)))
    (setf (libactr:buffer-chunk state 'goal)
          (libactr:make-chunk :isa 'add
                          :slots '((sum . five) (count . three) (arg2 . two))))
    (setf (libactr:buffer-chunk state 'retrieval)
          (libactr:make-chunk :isa 'number
                          :slots '((number . five) (next . six))))
    (let ((b (libactr:match-production prod state ct)))
      (is-true b)
      (is (eq (cdr (assoc '=count b)) 'three))
      (is (eq (cdr (assoc '=newsum b)) 'six)))))

(test matching-productions-returns-all-matches
  ;; With the initial addition goal, exactly one production (initialize-addition)
  ;; should match.  matching-productions returns a list of (production . bindings)
  ;; pairs.
  (let* ((md (load-compiled-addition))
         (state (libactr:make-buffer-state)))
    (setf (libactr:buffer-chunk state 'goal)
          (libactr:make-chunk :isa 'add
                          :slots '((arg1 . five) (arg2 . two) (sum . nil))))
    (let ((results (libactr:matching-productions (libactr:model-definition-productions md)
                                             state
                                             (libactr:model-definition-chunk-types md))))
      (is (= 1 (length results)))
      (is (eq (libactr:production-name (caar results)) 'initialize-addition))
      (is (eq (cdr (assoc '=num1 (cdar results))) 'five)))))

(test model-matching-productions-convenience
  ;; model-matching-productions threads the model's productions + ct-table
  ;; automatically.
  (let* ((md (load-compiled-addition))
         (state (libactr:make-buffer-state)))
    (setf (libactr:buffer-chunk state 'goal)
          (libactr:make-chunk :isa 'add
                          :slots '((arg1 . five) (arg2 . two) (sum . nil))))
    (let ((results (libactr:model-matching-productions md state)))
      (is (= 1 (length results)))
      (is (eq (libactr:production-name (caar results)) 'initialize-addition)))))

(test matcher-does-not-mutate-state
  ;; Pure-function guarantee: the buffer-state and its chunks are unchanged
  ;; after matching.  Confirm identity and slot values are preserved.
  (let* ((md (load-compiled-addition))
         (ct  (libactr:model-definition-chunk-types md))
         (goal (libactr:make-chunk :isa 'add
                               :slots '((arg1 . five) (arg2 . two) (sum . nil))))
         (state (libactr:make-buffer-state)))
    (setf (libactr:buffer-chunk state 'goal) goal)
    (libactr:match-production (find-compiled-production md 'initialize-addition)
                          state ct)
    (is (eq (libactr:buffer-chunk state 'goal) goal))
    (is (eq (cdr (assoc 'arg1 (libactr:chunk-slots goal))) 'five))
    (is (eq (cdr (assoc 'sum  (libactr:chunk-slots goal))) 'nil))))

;;; ---------- Regression: zero-variable matching productions are kept ----------
;;;
;;; A production whose LHS matches but binds ZERO variables (only :literal /
;;; ISA / :negation slot-tests, no :variable tests) must still appear in
;;; matching-productions' output with empty bindings.  Previously
;;; match-production collapsed a successful empty-bindings result to nil
;;; (indistinguishable from failure) and matching-productions' truthiness
;;; filter then dropped it.  T7's dual-track validation depends on this.

(defun make-zero-variable-add-production ()
  "A production whose LHS is =goal> ISA add sum five — a single :literal slot
   test, NO variables.  Matches any add chunk whose sum slot is five."
  (libactr::make-production
   'sum-is-five
   (list (libactr::make-buffer-pattern
          'goal := 'add
          (list (libactr::make-slot-test 'sum :literal 'five))))
   nil nil :correct))

(test matching-productions-keeps-zero-variable-match
  ;; The literal-only production matches a goal chunk with sum=five but binds
  ;; nothing.  matching-productions MUST include it (with empty bindings),
  ;; not silently drop it.  This is the regression for the collapsed-nil bug.
  (let* ((ct  (make-hash-table :test 'eq))
         (state (libactr:make-buffer-state))
         (prod (make-zero-variable-add-production)))
    (setf (gethash 'add ct)
          (libactr:make-chunk-type-def :name 'add :slots '(sum) :parent nil))
    (setf (libactr:buffer-chunk state 'goal)
          (libactr:make-chunk :isa 'add :slots '((sum . five))))
    ;; Sanity: match-production returns nil here (empty bindings collapse to
    ;; nil by the public contract) — this is the documented trap.
    (is (null (libactr:match-production prod state ct)))
    ;; The fix: matching-productions keeps it anyway, with EMPTY bindings.
    (let ((results (libactr:matching-productions (list prod) state ct)))
      (is (= 1 (length results)))
      (is (eq (libactr:production-name (caar results)) 'sum-is-five))
      (is (null (cdar results))))   ; bindings alist is empty (nil), not absent

    ;; Negative control: a non-matching state (sum=six) must still be EXCLUDED.
    (setf (libactr:buffer-chunk state 'goal)
          (libactr:make-chunk :isa 'add :slots '((sum . six))))
    (is (null (libactr:matching-productions (list prod) state ct)))))

(test model-matching-productions-keeps-zero-variable-match
  ;; model-matching-productions delegates to matching-productions and so also
  ;; keeps zero-variable matches.  Hand-build a model-definition whose only
  ;; production is the literal-only one above.
  (let* ((ct  (make-hash-table :test 'eq))
         (state (libactr:make-buffer-state))
         (prod (make-zero-variable-add-production))
         (md  (libactr:make-model-definition
               :chunk-types ct
               :chunks (make-hash-table :test 'eq)
               :productions (list prod)
               :initial-goal nil
               :params nil)))
    (setf (gethash 'add ct)
          (libactr:make-chunk-type-def :name 'add :slots '(sum) :parent nil))
    (setf (libactr:buffer-chunk state 'goal)
          (libactr:make-chunk :isa 'add :slots '((sum . five))))
    (let ((results (libactr:model-matching-productions md state)))
      (is (= 1 (length results)))
      (is (eq (libactr:production-name (caar results)) 'sum-is-five))
      (is (null (cdar results))))))

;;; ---------- :? buffer-state-query semantics (Task 7 fix) ----------
;;;
;;; ACT-R's ?buf> queries test buffer MODULE STATE, not chunk content:
;;;   buffer empty  -> buffer has no chunk
;;;   buffer full   -> buffer has a chunk
;;;   buffer failure-> last request failed (never set in a static snapshot)
;;;   state free    -> module idle (always true in a static snapshot)
;;;   state busy    -> module processing (never true in a static snapshot)
;;;   state error   -> module error (never true in a static snapshot)
;;; Previously the matcher treated :? as "buffer is occupied" — exactly
;;; INVERTED for `buffer empty`, the most common query.  These tests lock in
;;; the corrected semantics.

(defun make-state-query-production (buffer slot-tests)
  "Build a production whose LHS is a single ?buf> state query."
  (libactr::make-production
   'query-prod
   (list (libactr::make-buffer-pattern buffer :? nil slot-tests))
   nil nil :correct))

;;; Helper: does PROD match STATE?  Uses matching-productions (not
;;; match-production) because :? state queries bind zero variables — a
;;; successful match collapses to nil through the match-production entry point,
;;; and matching-productions is the API dual-track-check consumes.
(defun query-matches-p (prod state)
  (not (null (libactr:matching-productions (list prod) state))))

(test buffer-empty-query-matches-when-buffer-empty
  ;; ?retrieval> buffer empty  -> must match when retrieval is EMPTY.
  (let* ((prod (make-state-query-production
                'retrieval
                (list (libactr::make-slot-test 'buffer :literal 'empty))))
         (state (libactr:make-buffer-state)))  ; no retrieval chunk -> empty
    (is-true (query-matches-p prod state))))

(test buffer-empty-query-fails-when-buffer-occupied
  ;; ?retrieval> buffer empty  -> must NOT match when retrieval has a chunk.
  (let* ((prod (make-state-query-production
                'retrieval
                (list (libactr::make-slot-test 'buffer :literal 'empty))))
         (state (libactr:make-buffer-state)))
    (setf (libactr:buffer-chunk state 'retrieval)
          (libactr:make-chunk :isa 'number :slots '((number . one))))
    (is-false (query-matches-p prod state))))

(test buffer-full-query-matches-when-occupied
  ;; ?goal> buffer full  -> must match when goal has a chunk.
  (let* ((prod (make-state-query-production
                'goal
                (list (libactr::make-slot-test 'buffer :literal 'full))))
         (state (libactr:make-buffer-state)))
    (setf (libactr:buffer-chunk state 'goal)
          (libactr:make-chunk :isa 'add :slots '((sum . five))))
    (is-true (query-matches-p prod state))))

(test buffer-full-query-fails-when-empty
  ;; ?goal> buffer full  -> must NOT match when goal is empty.
  (let* ((prod (make-state-query-production
                'goal
                (list (libactr::make-slot-test 'buffer :literal 'full))))
         (state (libactr:make-buffer-state)))   ; no goal chunk -> empty
    (is-false (query-matches-p prod state))))

(test state-free-query-always-matches
  ;; ?imaginal> state free  -> always true in a static snapshot (occupied or not).
  (let* ((prod (make-state-query-production
                'imaginal
                (list (libactr::make-slot-test 'state :literal 'free))))
         (state-empty (libactr:make-buffer-state))
         (state-full  (libactr:make-buffer-state)))
    (setf (libactr:buffer-chunk state-full 'imaginal)
          (libactr:make-chunk :isa 'array :slots '((letter . a))))
    (is-true (query-matches-p prod state-empty))
    (is-true (query-matches-p prod state-full))))

(test state-busy-query-never-matches
  ;; ?manual> state busy  -> never true in a static snapshot.
  (let* ((prod (make-state-query-production
                'manual
                (list (libactr::make-slot-test 'state :literal 'busy))))
         (state (libactr:make-buffer-state)))
    (setf (libactr:buffer-chunk state 'manual)
          (libactr:make-chunk :isa 'command :slots '((cmd . press-key))))
    (is-false (query-matches-p prod state))))

(test buffer-failure-query-never-matches-in-snapshot
  ;; ?retrieval> buffer failure -> failure is a post-request state; never set
  ;; in a static snapshot (no retrieval has been issued).  Both libactr and the
  ;; oracle start from the same snapshot, so both say FALSE — they agree.
  (let* ((prod (make-state-query-production
                'retrieval
                (list (libactr::make-slot-test 'buffer :literal 'failure))))
         (state-empty (libactr:make-buffer-state))
         (state-full  (libactr:make-buffer-state)))
    (setf (libactr:buffer-chunk state-full 'retrieval)
          (libactr:make-chunk :isa 'number :slots '((number . one))))
    (is-false (query-matches-p prod state-empty))
    (is-false (query-matches-p prod state-full))))
