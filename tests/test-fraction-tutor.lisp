;;;; tests/test-fraction-tutor.lisp — fraction model load/KC/buggy (Phase 7).
(defpackage :mtt/fraction-tutor-test
  (:use :cl :5am :mtt/fraction-tutor))
(in-package :mtt/fraction-tutor-test)

(def-suite :mtt/fraction-tutor :description "fraction model load + buggy library")
(in-suite :mtt/fraction-tutor)

(defun %prod-names (md)
  (mapcar #'mtt:production-name (mtt:model-definition-productions md)))

(test load-fraction-model.shape
  "load-fraction-model yields 2 correct + 4 buggy productions; correct ones are
attributed to the 2 skill KCs; production names land in :mtt/fraction-tutor."
  (let ((md (load-fraction-model)))
    (is (= 6 (length (mtt:model-definition-productions md))))
    (let ((names (%prod-names md)))
      (dolist (n '(find-common-denominator add-fractions
                   buggy-add-across buggy-keep-left-denom buggy-no-convert
                   buggy-use-product))
        (is (find n names :key #'symbol-name :test #'string=)
            "missing production ~a" n)))
    ;; KC attribution: correct productions carry the skill KC keyword.
    (flet ((kc-of (name)
             (let ((p (find name (mtt:model-definition-productions md)
                           :key (lambda (x) (symbol-name (mtt:production-name x)))
                           :test #'string=)))
               (mtt:production-kc p))))
      (is (eq :common-denominator (kc-of 'find-common-denominator)))
      (is (eq :add-fractions (kc-of 'add-fractions)))
      (is (eq :add-fractions (kc-of 'buggy-add-across)))
      (is (eq :common-denominator (kc-of 'buggy-use-product))))
    ;; symbols live in the model package
    (is (eq (find-package :mtt/fraction-tutor)
            (symbol-package
             (mtt:chunk-isa (mtt:model-definition-initial-goal md)))))))

(test fraction-bug-specs-pass-validation
  "Every fraction bug-spec (3 sum + 1 cdenom) passes the phase-13 authoring
validator. The :when forms read the frac-add GOAL slots (problem variables
the validator cannot derive from the spec itself), so they are declared via
:extra-env-names (cdenom is a goal slot in the sum specs; in the cdenom spec
it is the answer :as — superset is harmless)."
  (dolist (spec (append (mtt/fraction-tutor:sum-bug-specs)
                        (mtt/fraction-tutor:cdenom-bug-specs)))
    (multiple-value-bind (errors warnings)
        (mtt:validate-bug-spec spec
                               :extra-env-names '(num1 den1 num2 den2 cdenom))
      (declare (ignore warnings))
      (is (null errors)
          "fraction spec ~a: ~{~a~^; ~}"
          (mtt:bug-spec-name spec) errors))))

(test fraction-loader-rejects-invalid-spec
  ;; wire check: the loader's validation gate actually signals on errors.
  ;; The fboundp IS the wiring assertion: without the gate, the signals check
  ;; below would false-pass via UNDEFINED-FUNCTION (an error subtype).
  (is (fboundp 'mtt/fraction-tutor::%validate-specs!))
  (signals error
    (mtt/fraction-tutor::%validate-specs!
     (list (mtt:make-bug-spec
            :name 'buggy-x :kind :x :kc :x :goal-type 'frac-add
            :answers '((:action "num" :slot snum :as snum)
                       (:action "denom" :slot sdenom :as sdenom))
            :fact-slots '((num :from (:answer 0)))  ; answer 1 unsourced
            :when '(= snum num))))))
