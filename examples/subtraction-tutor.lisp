;;;; examples/subtraction-tutor.lisp — subtraction model loader + buggy
;;;; library (Phase 11). Mirrors examples/fraction-tutor.lisp:
;;;; load-subtraction-model binds *PACKAGE* so all model symbols land in
;;;; :mtt/subtraction-tutor. Buggy rules are appended (mtt-only). KC attribution
;;;; is applied post-load via the declarative apply-kc-map (src/authoring.lisp)
;;;; so correct productions group into the 2 skill KCs. NO global mutable state
;;;; in this file.
(defpackage :mtt/subtraction-tutor
  (:use :cl)
  (:nicknames :subtraction-tutor)
  (:export #:load-subtraction-model #:bug-specs))
(in-package :mtt/subtraction-tutor)

(defun bug-specs ()
  "Three bug declarations for 2-digit column subtraction (all detected at the
ONES column, phase 11 spec §4; phase 12 spec §2.2). ONE declaration -> THREE
artifacts (buggy production / detection predicate / prime) via the phase-12
bug-DSL. List order IS the detection order (phase 11 mutual-exclusion proof:
correct -> borrow-ignore -> always-borrow -> off-by-one); off-by-one inlines
the borrow-column correct value (10+top-bot) — within its (< top bot) guard
that IS correct. Symbols land in :mtt/subtraction-tutor (this file's
package = the model package)."
  (list
   (mtt:make-bug-spec
    :name 'buggy-borrow-ignore :kind :borrow-ignore :kc :borrow
    :feedback "The ones digit was too small — you needed to borrow from the tens. Subtracting the small from the large ignores the borrow."
    :goal-type 'sub2 :goal-guard '((stage ones))
    :answers '((:action "value" :slot res-ones :as digit))
    :fact-slots '((digit :from (:answer 0)))
    :when '(and (< top-ones bot-ones) (= digit (- bot-ones top-ones))))
   (mtt:make-bug-spec
    :name 'buggy-always-borrow :kind :always-borrow :kc :borrow
    :feedback "You borrowed in a column that didn't need it — the top digit was already big enough."
    :goal-type 'sub2 :goal-guard '((stage ones))
    :answers '((:action "value" :slot res-ones :as digit))
    :fact-slots '((digit :from (:answer 0)))
    :when '(and (>= top-ones bot-ones)
                (= digit (- (+ 10 top-ones) bot-ones))))
   (mtt:make-bug-spec
    :name 'buggy-off-by-one :kind :off-by-one :kc :column-subtract
    :feedback "You set up the borrow correctly but slipped on the subtraction fact."
    :goal-type 'sub2 :goal-guard '((stage ones))
    :answers '((:action "value" :slot res-ones :as digit))
    :fact-slots '((digit :from (:answer 0)))
    :when '(and (< top-ones bot-ones)
                (= 1 (abs (- digit (- (+ 10 top-ones) bot-ones))))))))

(defun load-subtraction-model ()
  "Read+compile subtraction.lisp, attribute correct-production KCs, append the
buggy library. Model symbols land in :mtt/subtraction-tutor (*PACKAGE*
binding). The borrow pair subtract-ones-borrow + propagate-borrow shares the
:borrow KC (propagation is the bookkeeping half of the borrowing skill);
direct columns share :column-subtract."
  (let ((*package* (find-package :mtt/subtraction-tutor)))
    (let ((md (mtt:compile-model
               (mtt:read-model-file
                (asdf:system-relative-pathname "mtt" "models/subtraction.lisp")))))
      (mtt:apply-kc-map
       md
       '((subtract-ones-direct  . :column-subtract)
         (subtract-ones-borrow  . :borrow)
         (propagate-borrow      . :borrow)
         (subtract-tens-direct  . :column-subtract)))
      (setf (mtt:model-definition-productions md)
            (append (mtt:model-definition-productions md)
                    (mapcar #'mtt:bug-production (%validate-specs! (bug-specs)))))
      md)))

(defun %validate-specs! (specs)
  "Authoring-time gate (phase 13 spec §6): signal when any spec has errors,
return SPECS. The subtraction :when forms read the sub2 GOAL slots (problem
variables the validator cannot derive from the spec itself), so they are
declared via :extra-env-names (the tens slots are a harmless superset — only
the ones slots appear in :when)."
  (dolist (spec specs)
    (multiple-value-bind (errors warnings)
        (mtt:validate-bug-spec spec
                               :extra-env-names
                               '(top-ones bot-ones top-tens bot-tens))
      (declare (ignore warnings))
      (when errors
        (error "invalid bug-spec ~a: ~{~a~^; ~}" (mtt:bug-spec-name spec) errors))))
  specs)
