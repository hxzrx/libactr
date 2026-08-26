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
