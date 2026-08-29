;;;; tests/test-subtraction-tutor.lisp — subtraction model load/KC/buggy (Phase 11).
(defpackage :mtt/subtraction-tutor-test
  (:use :cl :5am :mtt/subtraction-tutor))
(in-package :mtt/subtraction-tutor-test)

(def-suite :mtt/subtraction-tutor
    :description "subtraction model load + KC attribution + buggy library")
(in-suite :mtt/subtraction-tutor)

(defun %prod-names (md)
  (mapcar #'mtt:production-name (mtt:model-definition-productions md)))

(defun %kc-of (md name)
  (mtt:production-kc
   (find name (mtt:model-definition-productions md)
         :key (lambda (x) (symbol-name (mtt:production-name x)))
         :test #'string=)))

(test load-subtraction-model.shape
  "load-subtraction-model yields 4 correct + 3 buggy productions; correct ones
are attributed to the 2 skill KCs (direct columns -> :column-subtract; the
borrow pair subtract-ones-borrow + propagate-borrow -> :borrow); buggy ones to
their misapplied-skill KCs; model symbols land in :mtt/subtraction-tutor."
  (let ((md (load-subtraction-model)))
    (is (= 7 (length (mtt:model-definition-productions md))))
    (let ((names (%prod-names md)))
      (dolist (n '(subtract-ones-direct subtract-ones-borrow propagate-borrow
                   subtract-tens-direct
                   buggy-borrow-ignore buggy-always-borrow buggy-off-by-one))
        (is (find n names :key #'symbol-name :test #'string=)
            "missing production ~a" n)))
    (is (eq :column-subtract (%kc-of md 'subtract-ones-direct)))
    (is (eq :borrow          (%kc-of md 'subtract-ones-borrow)))
    (is (eq :borrow          (%kc-of md 'propagate-borrow)))
    (is (eq :column-subtract (%kc-of md 'subtract-tens-direct)))
    (is (eq :borrow          (%kc-of md 'buggy-borrow-ignore)))
    (is (eq :borrow          (%kc-of md 'buggy-always-borrow)))
    (is (eq :column-subtract (%kc-of md 'buggy-off-by-one)))
    ;; symbols live in the model package
    (is (eq (find-package :mtt/subtraction-tutor)
            (symbol-package
             (mtt:chunk-isa (mtt:model-definition-initial-goal md)))))))

(test subtraction-bug-specs-pass-validation
  "Every subtraction bug-spec passes the phase-13 authoring validator. The
:when forms read the sub2 GOAL slots (problem variables the validator cannot
derive from the spec itself), so they are declared via :extra-env-names (the
tens slots are a harmless superset — only the ones slots appear in :when)."
  (dolist (spec (mtt/subtraction-tutor:bug-specs))
    (multiple-value-bind (errors warnings)
        (mtt:validate-bug-spec spec
                               :extra-env-names
                               '(top-ones bot-ones top-tens bot-tens))
      (declare (ignore warnings))
      (is (null errors)
          "subtraction spec ~a: ~{~a~^; ~}"
          (mtt:bug-spec-name spec) errors))))
