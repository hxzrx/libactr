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
