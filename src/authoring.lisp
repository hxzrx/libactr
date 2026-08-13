;;;; src/authoring.lisp — pure authoring helpers over a compiled model-definition.
;;;; Phase 8: KC attribution (apply-kc-map). Future authoring utilities land here.
;;;; NO global mutable state — pure transforms of their argument.
(in-package :mtt)

(defun apply-kc-map (model-definition kc-map)
  "Attribute production-kc on MODEL-DEFINITION's productions per KC-MAP.
KC-MAP is an alist (production-name (a symbol) . kc); each key is matched
against a production's name by SYMBOL-NAME (package-agnostic: the map is
authored in the tutor package, production names live in the model package).
Mutates MODEL-DEFINITION's productions in place (like compile-model) and
returns MODEL-DEFINITION. Productions absent from the map keep their existing
kc, so buggy rules that already carry their kc via make-production are
untouched when a loader applies the map before appending them."
  (dolist (p (model-definition-productions model-definition))
    (let ((kc (cdr (assoc (symbol-name (production-name p)) kc-map
                          :key #'symbol-name :test #'string=))))
      (when kc
        (setf (production-kc p) kc))))
  model-definition)
