;;;; tests/test-authoring.lisp — apply-kc-map (Phase 8, pure core utility).
(in-package :mtt/test)
(in-suite :mtt)

(test apply-kc-map.empty-map-leaves-kc-untouched
  "An empty kc-map changes no production's kc; returns the model-definition."
  (let ((md (make-model-definition
             :productions (list (make-production 'p1 nil nil nil :correct nil)
                                (make-production 'p2 nil nil nil :correct nil)))))
    (is (eq md (apply-kc-map md nil)))
    (is (null (production-kc (first (model-definition-productions md)))))
    (is (null (production-kc (second (model-definition-productions md)))))))

(test apply-kc-map.attributes-by-name-across-packages
  "kc-map keys (authored in this package) match production names interned in a
different package, by symbol-name."
  (let ((pkg (or (find-package :mtt/authoring-fixture)
                 (make-package :mtt/authoring-fixture)))
        (md (make-model-definition :productions nil)))
    (setf (model-definition-productions md)
          (list (make-production (intern "ADD-FRACTIONS" pkg) nil nil nil :correct nil)
                (make-production (intern "OTHER" pkg) nil nil nil :correct nil)))
    (apply-kc-map md '((add-fractions . :add-fractions)))
    (let ((prods (model-definition-productions md)))
      (is (eq :add-fractions (production-kc (first prods))))
      (is (null (production-kc (second prods)))))))

(test apply-kc-map.preserves-already-set-kc-for-unlisted
  "A production already carrying a kc and absent from the map keeps it (buggy
rules built with their kc are never overwritten when the map is applied before
they are appended)."
  (let ((md (make-model-definition
             :productions (list (make-production 'buggy-add nil nil :add-fractions :buggy "fb")
                                (make-production 'add-fractions nil nil nil :correct nil)))))
    (apply-kc-map md '((add-fractions . :add-fractions)))
    (let ((prods (model-definition-productions md)))
      (is (eq :add-fractions (production-kc (first prods))))    ; buggy kept
      (is (eq :add-fractions (production-kc (second prods))))))) ; correct set

;;; ---------------------------------------------------------------------------
;;; Phase 12: minimal bug-DSL — bug-spec / bug-answer-env / eval-bug-form.
;;; ---------------------------------------------------------------------------

(test bug-answer-env.pairs-as-names-with-answers
  "bug-answer-env pairs each answer entry's :as name (defaulting to the :slot
name) with the parsed student value, in spec-answers order."
  (let ((spec (make-bug-spec
               :name 'b1 :kind :bug1 :kc :k :feedback "f" :goal-type 'task
               :answers (list (list :action "value" :slot 'res :as 'digit)
                              (list :action "num" :slot 'snum)))))
    (is (equal `((digit . 4) (snum . 7))
               (bug-answer-env spec '(4 7))))))

(test eval-bug-form.atoms-and-arith-gold
  "Hand-computed gold: literals self-evaluate, symbols resolve from env, the
arithmetic/relational builtins compose (the subtraction formulas' shapes)."
  (let ((env '((top-ones . 2) (bot-ones . 8) (digit . 5))))
    (is (eql 7 (eval-bug-form '(+ 1 2 4) env)))
    (is (eql 6 (eval-bug-form '(- bot-ones top-ones) env)))
    (is (eql 16 (eval-bug-form '(* top-ones bot-ones) env)))
    (is (eql 4 (eval-bug-form '(- (+ 10 top-ones) bot-ones) env)))
    (is (eql 1 (eval-bug-form '(abs (- digit (- (+ 10 top-ones) bot-ones))) env)))
    (is (eq t (eval-bug-form '(= 1 (abs (- digit (- (+ 10 top-ones) bot-ones)))) env)))
    (is (eq t (eval-bug-form '(= digit 5) env)))
    (is (null (eval-bug-form '(= digit 4) env)))
    (is (eq t (eval-bug-form '(and (< top-ones bot-ones) (= digit 5)) env)))
    (is (null (eval-bug-form '(and (< top-ones bot-ones) (= digit 4)) env)))
    (is (null (eval-bug-form '(and (< bot-ones top-ones) (= digit 5)) env)))
    (is (eq t (eval-bug-form '(or (= digit 4) (= digit 5)) env)))
    (is (eq t (eval-bug-form '(not (= digit 4)) env)))
    (is (eq t (eval-bug-form '(and) env)))
    (is (null (eval-bug-form '(or) env)))
    (is (eq t (eval-bug-form '(<= top-ones top-ones) env)))
    (is (eq t (eval-bug-form '(>= bot-ones top-ones) env)))
    (is (eq t (eval-bug-form '(> bot-ones top-ones) env)))))

(test eval-bug-form.name-matching-is-package-agnostic
  "Env lookup is by symbol-name (apply-kc-map precedent): a key interned in
another package matches the form's name."
  (let ((env (list (cons (intern "TOP-ONES" (find-package :mtt/authoring-fixture)) 3))))
    (is (eql 3 (eval-bug-form 'top-ones env)))))

(test eval-bug-form.bound-nil-is-legal-unbound-errors
  "A name bound to nil is a legal value (assoc CELL, phase-10 lesson #4); an
unbound name errors (authoring typo, fail loud)."
  (is (null (eval-bug-form 'cdenom '((cdenom . nil)))))
  (is (eq t (eval-bug-form '(not cdenom) '((cdenom . nil)))))
  (signals error (eval-bug-form 'nope '((x . 1)))))

(test eval-bug-form.named-predicates
  "Non-builtin operators resolve from the caller-supplied :predicates alist by
symbol-name; arguments are EVALUATED first (forms, not raw names); an unknown
operator errors."
  (let ((preds (list (cons 'verb+ed-p (lambda (a v)
                                        (string= a (concatenate 'string v "ED")))))))
    (is (eq t (eval-bug-form '(verb+ed-p answer verb)
                             '((answer . "WALKED") (verb . "WALK"))
                             :predicates preds)))
    (is (null (eval-bug-form '(verb+ed-p answer verb)
                             '((answer . "WENT") (verb . "WALK"))
                             :predicates preds)))
    (is (eq t (eval-bug-form '(gather digit (* top 4))
                             '((digit . 5) (top . 2))
                             :predicates (list (cons 'gather
                                                     (lambda (&rest a) (equal a '(5 8)))))))
        "args are evaluated: (* top 4) -> 8")
    (signals error (eval-bug-form '(nope-p x) '((x . 1)) :predicates preds))))

;;; --- Phase 12 Task 2: bug-production generator + detect-bug driver ----------

(defun %defbug-fixture-package ()
  (or (find-package :mtt/defbug-fixture)
      (make-package :mtt/defbug-fixture)))

(test bug-production.gold-shape-single-answer
  "The generator reproduces the hand-written subtraction buggy production
field-for-field (equalp: structures are eq under equal): goal-guard literal
+ auto (slot nil) answer test, KIND keyword literal, variable =V1 numbered
from fact-slots order, RHS (slot . =V1), kc/:buggy/feedback. All GENERATED
symbols (GOAL/RETRIEVAL/BUG-FACT/KIND/=V1) intern in the spec-name's
package."
  (let* ((pkg (%defbug-fixture-package))
         (spec (make-bug-spec
                :name (intern "BUGGY-BORROW-IGNORE" pkg)
                :kind :borrow-ignore :kc :borrow :feedback "fb"
                :goal-type (intern "SUB2" pkg)
                :goal-guard (list (list (intern "STAGE" pkg) (intern "ONES" pkg)))
                :answers (list (list :action "value"
                                     :slot (intern "RES-ONES" pkg)
                                     :as (intern "DIGIT" pkg)))
                :fact-slots (list (list (intern "DIGIT" pkg) :from (list :answer 0)))
                :when '(= digit 1)))
         (p (bug-production spec)))
    (is (eq (intern "BUGGY-BORROW-IGNORE" pkg) (production-name p)))
    (is (eq :buggy (production-kind p)))
    (is (eq :borrow (production-kc p)))
    (is (equal "fb" (production-feedback p)))
    (is (equalp (make-buffer-pattern (intern "GOAL" pkg) := (intern "SUB2" pkg)
                  (list (make-slot-test (intern "STAGE" pkg) :literal
                                        (intern "ONES" pkg))
                        (make-slot-test (intern "RES-ONES" pkg) :literal nil)))
                (first (production-lhs p))))
    (is (equalp (make-buffer-pattern (intern "RETRIEVAL" pkg) := (intern "BUG-FACT" pkg)
                  (list (make-slot-test (intern "KIND" pkg) :literal :borrow-ignore)
                        (make-slot-test (intern "DIGIT" pkg) :variable
                                        (intern "=V1" pkg))))
                (second (production-lhs p))))
    (is (equalp (list (make-action ':= (intern "GOAL" pkg)
                                   (list (cons (intern "RES-ONES" pkg)
                                               (intern "=V1" pkg)))))
                (production-rhs p)))))

(test bug-production.gold-shape-goal-source-literal-two-slots
  "Variable numbering spans fact-slots order (VERB=V1 from :goal, PAST=V2
from :answer 0 — the past-tense shape); RHS uses the ANSWER's variable only;
a :literal fact slot becomes a literal test (use-product denom-0 shape);
no goal-guard -> only the auto answer-nil test."
  (let* ((pkg (%defbug-fixture-package))
         (pt (make-bug-spec
              :name (intern "BUGGY-OVER" pkg) :kind :over :kc :irr
              :feedback "f2" :goal-type (intern "TASK" pkg)
              :answers (list (list :action "value" :slot (intern "PAST" pkg)
                                   :as (intern "ANSWER" pkg)))
              :fact-slots (list (list (intern "VERB" pkg) :from
                                      (list :goal (intern "VERB" pkg)))
                                (list (intern "PAST" pkg) :from (list :answer 0)))
              :when '(answer)))
         (up (make-bug-spec
              :name (intern "BUGGY-USE" pkg) :kind :use :kc :cd
              :feedback "f3" :goal-type (intern "FRAC" pkg)
              :answers (list (list :action "value" :slot (intern "CD" pkg)))
              :fact-slots (list (list (intern "NUM" pkg) :from (list :answer 0))
                                (list (intern "DENOM" pkg) :literal 0))
              :when '(cd))))
    (let ((p (bug-production pt)))
      (is (equalp (list (make-slot-test (intern "KIND" pkg) :literal :over)
                        (make-slot-test (intern "VERB" pkg) :variable
                                        (intern "=V1" pkg))
                        (make-slot-test (intern "PAST" pkg) :variable
                                        (intern "=V2" pkg)))
                  (buffer-pattern-slot-tests (second (production-lhs p)))))
      (is (equalp (list (make-action ':= (intern "GOAL" pkg)
                                     (list (cons (intern "PAST" pkg)
                                                 (intern "=V2" pkg)))))
                  (production-rhs p))))
    (let ((p (bug-production up)))
      (is (equalp (list (make-slot-test (intern "KIND" pkg) :literal :use)
                        (make-slot-test (intern "NUM" pkg) :variable
                                        (intern "=V1" pkg))
                        (make-slot-test (intern "DENOM" pkg) :literal 0))
                  (buffer-pattern-slot-tests (second (production-lhs p)))))
      (is (equalp (list (make-slot-test (intern "CD" pkg) :literal nil))
                  (buffer-pattern-slot-tests (first (production-lhs p))))))))

(test bug-production.gold-shape-two-answers-auto-nil-tests
  "A 2-answer spec (the fraction-sum shape) generates an auto (slot nil) goal
test PER answer (snum AND sdenom), the num/denom =V1/=V2 retrieval pair, and
the two-slot RHS — the Task 8 review's deferred gold pin."
  (let* ((pkg (%defbug-fixture-package))
         (spec (make-bug-spec
                :name (intern "BUGGY-SUM-X" pkg) :kind :sum-x :kc :add-f
                :feedback "f" :goal-type (intern "FRAC-ADD" pkg)
                :answers (list (list :action "num" :slot (intern "SNUM" pkg) :as (intern "SNUM" pkg))
                               (list :action "denom" :slot (intern "SDENOM" pkg) :as (intern "SDENOM" pkg)))
                :fact-slots (list (list (intern "NUM" pkg) :from (list :answer 0))
                                   (list (intern "DENOM" pkg) :from (list :answer 1)))
                :when '(and (= snum 1) (= sdenom 2))))
         (p (bug-production spec)))
    (is (equalp (list (make-slot-test (intern "SNUM" pkg) :literal nil)
                      (make-slot-test (intern "SDENOM" pkg) :literal nil))
                (buffer-pattern-slot-tests (first (production-lhs p)))))
    (is (equalp (list (make-slot-test (intern "KIND" pkg) :literal :sum-x)
                      (make-slot-test (intern "NUM" pkg) :variable (intern "=V1" pkg))
                      (make-slot-test (intern "DENOM" pkg) :variable (intern "=V2" pkg)))
                (buffer-pattern-slot-tests (second (production-lhs p)))))
    (is (equalp (list (make-action ':= (intern "GOAL" pkg)
                                   (list (cons (intern "SNUM" pkg) (intern "=V1" pkg))
                                         (cons (intern "SDENOM" pkg) (intern "=V2" pkg)))))
                (production-rhs p)))))

(defun %mini-spec (name when)
  (make-bug-spec :name name :kind name :kc :k :feedback "f"
                 :goal-type 'task
                 :answers (list (list :action "value" :slot 'res :as 'digit))
                 :fact-slots (list (list 'digit :from (list :answer 0)))
                 :when when))

(test detect-bug.first-match-in-declared-order
  "detect-bug returns the FIRST spec whose :when holds (list order = detection
order), nil when none; the answer env shadows same-named goal slots. With
top-ones=4 BOTH mirror (8-4=4) and also (= digit 4) match — the assertion
genuinely exercises declared-order priority."
  (let ((env '((top-ones . 4) (bot-ones . 8) (res . nil))))
    (is (eq 'mirror
            (bug-spec-name (detect-bug (list (%mini-spec 'wrong '(= digit 99))
                                             (%mini-spec 'mirror '(= digit (- bot-ones top-ones)))
                                             (%mini-spec 'also '(= digit 4)))
                                       '(4) env))))
    (is (null (detect-bug (list (%mini-spec 'nope '(= digit 0))) '(4) env)))
    ;; shadowing: goal res=nil, answer digit=4 -> (= digit 4) true via ANSWER env
    (is (eq 'hit (bug-spec-name (detect-bug (list (%mini-spec 'hit '(= digit 4)))
                                            '(4) env))))))

;;; ---------------------------------------------------------------------------
;;; Phase 13: validate-bug-spec (authoring validator)

(defun %valid-subtraction-spec ()
  "A well-formed subtraction mirror spec (phase 12 §2.2 shape)."
  (make-bug-spec
   :name 'buggy-borrow-ignore :kind :borrow-ignore :kc :borrow
   :feedback "fb" :goal-type 'sub2 :goal-guard '((stage ones))
   :answers '((:action "value" :slot res-ones :as digit))
   :fact-slots '((digit :from (:answer 0)))
   :when '(and (< top-ones bot-ones) (= digit (- bot-ones top-ones)))))

(test validate-bug-spec.valid-spec-has-no-errors
  ;; top-ones / bot-ones are GOAL-slot names — the validator cannot derive
  ;; them from the spec (no chunk-type knowledge), so the caller declares
  ;; them via :extra-env-names (the parameter's exact purpose).
  (multiple-value-bind (errors warnings)
      (validate-bug-spec (%valid-subtraction-spec)
                         :extra-env-names '(top-ones bot-ones))
    (is (null errors))
    (is (null warnings))))

(test validate-bug-spec.missing-required-fields
  ;; a spec with name/kind/kc/goal-type nil -> one error per missing field
  (let ((spec (make-bug-spec :answers '((:action "value" :slot r :as d))
                             :fact-slots '((d :from (:answer 0)))
                             :when '(= d 1))))
    (multiple-value-bind (errors warnings)
        (validate-bug-spec spec)
      (declare (ignore warnings))
      (is (= 4 (length errors)))
      (is (find "name" errors :test #'(lambda (want e) (search want e))))
      (is (find "kind" errors :test #'(lambda (want e) (search want e))))
      (is (find "kc" errors :test #'(lambda (want e) (search want e))))
      (is (find "goal-type" errors :test #'(lambda (want e) (search want e)))))))

(test validate-bug-spec.answer-without-fact-slot
  "The headline silent degradation: answer 1 has no (:answer 1) fact slot ->
RHS would get (slot . nil). Must be an ERROR."
  (let ((spec (make-bug-spec
               :name 'b1 :kind :k :kc :kc1 :goal-type 'gt
               :answers '((:action "num" :slot s1 :as s1)
                          (:action "denom" :slot s2 :as s2))
               :fact-slots '((num :from (:answer 0)))   ; answer 1 unsourced
               :when '(= s1 num))))
    (multiple-value-bind (errors warnings)
        (validate-bug-spec spec)
      (declare (ignore warnings))
      (is (= 1 (length errors)))
      (is (and (search "answer 1" (first errors)) t))
      (is (and (search "(:answer 1)" (first errors)) t)))))

(test validate-bug-spec.answer-index-out-of-range
  "A fact slot (:answer 2) on a 2-answer spec -> index error. Both answers
must be SOURCED (num/den) — otherwise the headline answer-without-fact-slot
error would fire too and the count would not isolate the index error."
  (let ((spec (make-bug-spec
               :name 'b2 :kind :k :kc :kc1 :goal-type 'gt
               :answers '((:action "num" :slot s1 :as s1)
                          (:action "denom" :slot s2 :as s2))
               :fact-slots '((num :from (:answer 0)) (den :from (:answer 1))
                             (bogus :from (:answer 2)))
               :when '(= s1 num))))
    (multiple-value-bind (errors warnings)
        (validate-bug-spec spec)
      (declare (ignore warnings))
      (is (= 1 (length errors)))
      (is (and (search "out of range" (first errors)) t)))))

(test validate-bug-spec.fact-slot-without-from-or-literal
  "(name) with neither :from nor :literal degrades literal-nil at runtime -> error."
  (let ((spec (make-bug-spec
               :name 'b3 :kind :k :kc :kc1 :goal-type 'gt
               :answers '((:action "value" :slot s :as s))
               :fact-slots '((d))                        ; malformed
               :when '(= s 1))))
    (multiple-value-bind (errors warnings)
        (validate-bug-spec spec)
      (declare (ignore warnings))
      (is (and (search ":from" (first errors)) t)))))

(test validate-bug-spec.duplicate-answer-slot-and-as
  (let ((spec (make-bug-spec
               :name 'b4 :kind :k :kc :kc1 :goal-type 'gt
               :answers '((:action "a" :slot s1 :as x)
                          (:action "b" :slot s1 :as y))   ; duplicate :slot
               :fact-slots '((f0 :from (:answer 0)) (f1 :from (:answer 1)))
               :when '(= x 1))))
    (multiple-value-bind (errors warnings)
        (validate-bug-spec spec)
      (declare (ignore warnings))
      (is (and (search "duplicate" (first errors)) t)))))

(test validate-bug-spec.when-name-resolution
  ":when names must resolve to answer :as names / fact-slot names / goal-guard
slot names / extra-env-names. An unknown name AND an unknown operator are both
errors; a predicate supplied via :predicates resolves; extra-env-names resolves."
  (let ((spec (make-bug-spec
               :name 'b5 :kind :k :kc :kc1 :goal-type 'gt
               :goal-guard '((stage ones))
               :answers '((:action "value" :slot r :as d))
               :fact-slots '((digit :from (:answer 0)))
               :when '(and regular-p (verb-p d stage no-such-name)))))
    ;; without predicates/extra names: 3 errors (regular-p name, verb-p
    ;; operator, no-such-name name), first in emission order
    (multiple-value-bind (errors warnings)
        (validate-bug-spec spec)
      (declare (ignore warnings))
      (is (= 3 (length errors)))                        ; regular-p verb-p no-such-name
      (is (and (search "regular-p" (first errors)) t)))
    ;; with the domain table + env names: regular-p / verb-p resolve; the
    ;; genuinely-unknown no-such-name remains the SOLE error
    (multiple-value-bind (errors warnings)
        (validate-bug-spec spec
                           :predicates '((verb-p . (lambda (&rest _)
                                                     (declare (ignore _)) t)))
                           :extra-env-names '(regular-p))
      (declare (ignore warnings))
      (is (= 1 (length errors)))
      (is (and (search "no-such-name" (first errors)) t)))))

(test validate-bug-spec.builtin-arity
  "abs/not take exactly 1 arg; a 2-arg abs is an error."
  (let ((spec (make-bug-spec
               :name 'b6 :kind :k :kc :kc1 :goal-type 'gt
               :answers '((:action "value" :slot r :as d))
               :fact-slots '((digit :from (:answer 0)))
               :when '(= d (abs 1 2)))))
    (multiple-value-bind (errors warnings)
        (validate-bug-spec spec)
      (declare (ignore warnings))
      (is (= 1 (length errors)))
      (is (and (search "abs" (first errors)) t)))))

(test validate-bug-spec.malformed-goal-guard
  (let ((spec (make-bug-spec
               :name 'b7 :kind :k :kc :kc1 :goal-type 'gt
               :goal-guard '((stage))                    ; not a 2-list
               :answers '((:action "value" :slot r :as d))
               :fact-slots '((digit :from (:answer 0)))
               :when '(= d 1))))
    (multiple-value-bind (errors warnings)
        (validate-bug-spec spec)
      (declare (ignore warnings))
      (is (and (search "goal-guard" (first errors)) t)))))

;;; --- Phase 13 fix round 1: the purity contract (never signal) must hold
;;; --- for malformed-beyond-entry shapes too, not just well-typed entries.

(test validate-bug-spec.never-signals-atom-fact-slot-entry
  "Purity contract: an ATOM fact-slot entry (missing parens, e.g. (digit))
must COLLECT the malformed-entry error, not signal — step 6's fact-names
mapcar used to crash on (first 'digit) after step 3 had already diagnosed
the entry."
  (let ((spec (make-bug-spec
               :name 'b8 :kind :k :kc :kc1 :goal-type 'gt
               :answers '((:action "value" :slot s :as s))
               :fact-slots '(digit)                 ; atom entry — missing parens
               :when '(= s 1))))
    (multiple-value-bind (errors warnings)
        (validate-bug-spec spec)
      (declare (ignore warnings))
      (is (= 2 (length errors)))   ; malformed entry + unsourced answer 0
      (is (and (search "malformed fact-slot" (first errors)) t)))))

(test validate-bug-spec.never-signals-atom-goal-guard-pair
  "Same contract for ATOM goal-guard pairs (:goal-guard '(stage ones)): step
4 collects two malformed-entry errors; step 6's guard-names mapcar used to
crash on (first 'stage)."
  (let ((spec (make-bug-spec
               :name 'b9 :kind :k :kc :kc1 :goal-type 'gt
               :goal-guard '(stage ones)            ; atom entries — missing parens
               :answers '((:action "value" :slot r :as d))
               :fact-slots '((digit :from (:answer 0)))
               :when '(= d 1))))
    (multiple-value-bind (errors warnings)
        (validate-bug-spec spec)
      (declare (ignore warnings))
      (is (= 2 (length errors)))
      (is (and (search "goal-guard" (first errors)) t)))))

(test validate-bug-spec.never-signals-atom-answer-entry
  "Same contract for an ATOM :answers entry (a non-plist): step 2's getf used
to signal before the shape check could run. (A non-list :answers VALUE cannot
be constructed on SBCL — make-bug-spec's :type list fires first — so the atom
ENTRY is the reachable form of this path.)"
  (let ((spec (make-bug-spec
               :name 'b10 :kind :k :kc :kc1 :goal-type 'gt
               :answers '(42)                       ; atom entry — not a plist
               :fact-slots '((f :from (:answer 0)))
               :when t)))
    (multiple-value-bind (errors warnings)
        (validate-bug-spec spec)
      (declare (ignore warnings))
      (is (= 1 (length errors)))
      (is (and (search "malformed answer" (first errors)) t)))))

(test validate-bug-spec.never-signals-improper-answers-list
  "Same contract for an IMPROPER :answers list — it PASSES make-bug-spec's
:type list check (any cons is a LIST) but used to crash the step-2 dolist;
the collection now degrades to one collected error."
  (let ((spec (make-bug-spec
               :name 'b11 :kind :k :kc :kc1 :goal-type 'gt
               :answers '(1 . 2)
               :fact-slots '((f :literal 0))
               :when t)))
    (multiple-value-bind (errors warnings)
        (validate-bug-spec spec)
      (declare (ignore warnings))
      (is (= 1 (length errors)))
      (is (and (search ":answers" (first errors)) t)))))

(test validator.dotted-answer-entry-degrades-to-error
  "B2: a dotted answer entry ((5 . 5)) is a COLLECTED error, not a signal
(getf used to TYPE-ERROR)."
  (multiple-value-bind (errors warnings)
      (mtt:validate-bug-spec
       (mtt:make-bug-spec :name 'b :kind :k :kc :k :goal-type 'g
                          :answers '((5 . 5)) :when t))
    (declare (ignore warnings))
    (is (find-if (lambda (e) (search "malformed answer entry" e)) errors))))

(test validator.dotted-fact-slot-entry-degrades-to-error
  "B2: a dotted fact-slot entry ((digit . 5)) is a collected error, not a
signal."
  (multiple-value-bind (errors warnings)
      (mtt:validate-bug-spec
       (mtt:make-bug-spec :name 'b :kind :k :kc :k :goal-type 'g
                          :fact-slots '((digit . 5)) :when t))
    (declare (ignore warnings))
    (is (find-if (lambda (e) (search "malformed fact-slot entry" e)) errors))))

(test validator.dotted-goal-guard-entry-degrades-to-error
  "B2: a dotted goal-guard entry ((ones . 4)) is a collected error, not a
signal (length used to TYPE-ERROR)."
  (multiple-value-bind (errors warnings)
      (mtt:validate-bug-spec
       (mtt:make-bug-spec :name 'b :kind :k :kc :k :goal-type 'g
                          :goal-guard '((ones . 4)) :when t))
    (declare (ignore warnings))
    (is (find-if (lambda (e) (search "malformed goal-guard entry" e)) errors))))
