;;;; tests/test-subtraction-tutor.lisp — subtraction model load/KC/buggy (Phase 11).
(defpackage :libactr/subtraction-tutor-test
  (:use :cl :5am :libactr/subtraction-tutor))
(in-package :libactr/subtraction-tutor-test)

(def-suite :libactr/subtraction-tutor
    :description "subtraction model load + KC attribution + buggy library")
(in-suite :libactr/subtraction-tutor)

(defun %prod-names (md)
  (mapcar #'libactr:production-name (libactr:model-definition-productions md)))

(defun %kc-of (md name)
  (libactr:production-kc
   (find name (libactr:model-definition-productions md)
         :key (lambda (x) (symbol-name (libactr:production-name x)))
         :test #'string=)))

(test load-subtraction-model.shape
  "load-subtraction-model yields 4 correct + 3 buggy productions; correct ones
are attributed to the 2 skill KCs (direct columns -> :column-subtract; the
borrow pair subtract-ones-borrow + propagate-borrow -> :borrow); buggy ones to
their misapplied-skill KCs; model symbols land in :libactr/subtraction-tutor."
  (let ((md (load-subtraction-model)))
    (is (= 7 (length (libactr:model-definition-productions md))))
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
    (is (eq (find-package :libactr/subtraction-tutor)
            (symbol-package
             (libactr:chunk-isa (libactr:model-definition-initial-goal md)))))))

(test subtraction-bug-specs-pass-validation
  "Every subtraction bug-spec passes the phase-13 authoring validator. The
:when forms read the sub2 GOAL slots (problem variables the validator cannot
derive from the spec itself), so they are declared via :extra-env-names (the
tens slots are a harmless superset — only the ones slots appear in :when)."
  (dolist (spec (libactr/subtraction-tutor:bug-specs))
    (multiple-value-bind (errors warnings)
        (libactr:validate-bug-spec spec
                               :extra-env-names
                               '(top-ones bot-ones top-tens bot-tens))
      (declare (ignore warnings))
      (is (null errors)
          "subtraction spec ~a: ~{~a~^; ~}"
          (libactr:bug-spec-name spec) errors))))

(test subtraction-loader-rejects-invalid-spec
  "C7: the loader's validation gate actually signals on errors (mirrors
fraction-loader-rejects-invalid-spec). The fboundp IS the wiring assertion."
  (is (fboundp 'libactr/subtraction-tutor::%validate-specs!))
  (signals error
    (libactr/subtraction-tutor::%validate-specs!
     (list (libactr:make-bug-spec
            :name 'buggy-x :kind :x :kc :x :goal-type 'sub2
            :answers '((:action "value" :slot res-ones :as d))
            :fact-slots '((num :from (:answer 1)))   ; out of range for 1 answer
            :when '(= d num))))))
