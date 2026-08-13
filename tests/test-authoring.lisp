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
