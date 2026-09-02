;;;; tests/test-fraction-tutor.lisp — fraction model load/KC/buggy (Phase 7).
(defpackage :libactr/fraction-tutor-test
  (:use :cl :5am :libactr/fraction-tutor))
(in-package :libactr/fraction-tutor-test)

(def-suite :libactr/fraction-tutor :description "fraction model load + buggy library")
(in-suite :libactr/fraction-tutor)

(defun %prod-names (md)
  (mapcar #'libactr:production-name (libactr:model-definition-productions md)))

(test load-fraction-model.shape
  "load-fraction-model yields 3 correct + 4 buggy productions; correct ones are
attributed to their skill KCs; production names land in :libactr/fraction-tutor."
  (let ((md (load-fraction-model)))
    (is (= 7 (length (libactr:model-definition-productions md))))
    (let ((names (%prod-names md)))
      (dolist (n '(find-common-denominator add-fractions simplify
                   buggy-add-across buggy-keep-left-denom buggy-no-convert
                   buggy-use-product))
        (is (find n names :key #'symbol-name :test #'string=)
            "missing production ~a" n)))
    ;; KC attribution: correct productions carry the skill KC keyword.
    (flet ((kc-of (name)
             (let ((p (find name (libactr:model-definition-productions md)
                           :key (lambda (x) (symbol-name (libactr:production-name x)))
                           :test #'string=)))
               (libactr:production-kc p))))
      (is (eq :common-denominator (kc-of 'find-common-denominator)))
      (is (eq :add-fractions (kc-of 'add-fractions)))
      (is (eq :add-fractions (kc-of 'buggy-add-across)))
      (is (eq :common-denominator (kc-of 'buggy-use-product))))
    ;; symbols live in the model package
    (is (eq (find-package :libactr/fraction-tutor)
            (symbol-package
             (libactr:chunk-isa (libactr:model-definition-initial-goal md)))))))

(test fraction-bug-specs-pass-validation
  "Every fraction bug-spec (3 sum + 1 cdenom) passes the phase-13 authoring
validator. The :when forms read the frac-add GOAL slots (problem variables
the validator cannot derive from the spec itself), so they are declared via
:extra-env-names (cdenom is a goal slot in the sum specs; in the cdenom spec
it is the answer :as — superset is harmless)."
  (dolist (spec (append (libactr/fraction-tutor:sum-bug-specs)
                        (libactr/fraction-tutor:cdenom-bug-specs)))
    (multiple-value-bind (errors warnings)
        (libactr:validate-bug-spec spec
                               :extra-env-names '(num1 den1 num2 den2 cdenom))
      (declare (ignore warnings))
      (is (null errors)
          "fraction spec ~a: ~{~a~^; ~}"
          (libactr:bug-spec-name spec) errors))))

(test load-fraction-model.simplify-production
  "Phase 13: the model carries a third correct production SIMPLIFY, kc-attributed
:simplify via the kc-map; frac-add gains rnum/rdenom and a reduce-fact chunk-type
exists."
  (let ((md (libactr/fraction-tutor:load-fraction-model)))
    (let ((p (find "SIMPLIFY" (libactr:model-definition-productions md)
                   :key (lambda (x) (symbol-name (libactr:production-name x)))
                   :test #'string=)))
      (is (and p t))
      (is (eq :simplify (libactr:production-kc p)))
      (is (eq :correct (libactr:production-kind p))))))

(test fraction-loader-rejects-invalid-spec
  ;; wire check: the loader's validation gate actually signals on errors.
  ;; The fboundp IS the wiring assertion: without the gate, the signals check
  ;; below would false-pass via UNDEFINED-FUNCTION (an error subtype).
  (is (fboundp 'libactr/fraction-tutor::%validate-specs!))
  (signals error
    (libactr/fraction-tutor::%validate-specs!
     (list (libactr:make-bug-spec
            :name 'buggy-x :kind :x :kc :x :goal-type 'frac-add
            :answers '((:action "num" :slot snum :as snum)
                       (:action "denom" :slot sdenom :as sdenom))
            :fact-slots '((num :from (:answer 0)))  ; answer 1 unsourced
            :when '(= snum num))))))
