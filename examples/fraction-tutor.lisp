;;;; examples/fraction-tutor.lisp — fraction model loader + buggy library (Phase 7).
;;;; Mirrors examples/addition-tutor.lisp: load-fraction-model binds *PACKAGE* so
;;;; all model symbols (FRAC-ADD, NUM1, FIND-COMMON-DENOMINATOR, ...) land in
;;;; :mtt/fraction-tutor. Buggy rules are appended (mtt-only). KC attribution is
;;;; applied post-load via the declarative apply-kc-map utility (src/authoring.lisp)
;;;; so correct+buggy group into 2 skill KCs. NO global mutable state in this file.
(defpackage :mtt/fraction-tutor
  (:use :cl)
  (:nicknames :fraction-tutor)
  (:export #:load-fraction-model #:sum-bug-specs #:cdenom-bug-specs))
(in-package :mtt/fraction-tutor)

(defun sum-bug-specs ()
  "Three bug declarations for the :sum step (phase 12 spec §2.2). List order
IS the detection order (add-across -> keep-left -> no-convert)."
  (list
   (mtt:make-bug-spec
    :name 'buggy-add-across :kind :add-across :kc :add-fractions
    :feedback "You added the denominators. Find a common denominator first."
    :goal-type 'frac-add
    :answers '((:action "num" :slot snum :as snum)
               (:action "denom" :slot sdenom :as sdenom))
    :fact-slots '((num :from (:answer 0)) (denom :from (:answer 1)))
    :when '(and (= snum (+ num1 num2)) (= sdenom (+ den1 den2))))
   (mtt:make-bug-spec
    :name 'buggy-keep-left-denom :kind :keep-left-denom :kc :add-fractions
    :feedback "You kept the first denominator — both must share a common denominator."
    :goal-type 'frac-add
    :answers '((:action "num" :slot snum :as snum)
               (:action "denom" :slot sdenom :as sdenom))
    :fact-slots '((num :from (:answer 0)) (denom :from (:answer 1)))
    :when '(and (= snum (+ num1 num2)) (= sdenom den1)))
   (mtt:make-bug-spec
    :name 'buggy-no-convert :kind :no-convert :kc :add-fractions
    :feedback "Right common denominator, but convert each numerator before adding."
    :goal-type 'frac-add
    :answers '((:action "num" :slot snum :as snum)
               (:action "denom" :slot sdenom :as sdenom))
    :fact-slots '((num :from (:answer 0)) (denom :from (:answer 1)))
    :when '(and (= snum (+ num1 num2)) (= sdenom cdenom)))))

(defun cdenom-bug-specs ()
  "One bug declaration for the :common-denom step. The (<> LCM) guard is
IMPLICIT in correct-first detection ordering (the correct branch runs before
detect-bug, so a product answer that IS the LCM never reaches this spec)."
  (list
   (mtt:make-bug-spec
    :name 'buggy-use-product :kind :use-product :kc :common-denominator
    :feedback "That's the product of the denominators, not the least common denominator."
    :goal-type 'frac-add
    :answers '((:action "value" :slot cdenom :as cdenom))
    :fact-slots '((num :from (:answer 0)) (denom :literal 0))
    :when '(= cdenom (* den1 den2)))))

(defun load-fraction-model ()
  "Read+compile fraction-add.lisp, attribute correct-production KCs, append the
buggy library. Model symbols land in :mtt/fraction-tutor (*PACKAGE* binding)."
  (let ((*package* (find-package :mtt/fraction-tutor)))
    (let ((md (mtt:compile-model
               (mtt:read-model-file
                (asdf:system-relative-pathname "mtt" "models/fraction-add.lisp")))))
      ;; Attribute correct productions to their skill KC (keyword symbols) via the
      ;; pure declarative kc-map (src/authoring.lisp). Applied before appending the
      ;; buggy library, which already carries its own kc.
      (mtt:apply-kc-map
       md
       '((find-common-denominator . :common-denominator)
         (add-fractions          . :add-fractions)))
      (setf (mtt:model-definition-productions md)
            (append (mtt:model-definition-productions md)
                    (mapcar #'mtt:bug-production
                            (append (sum-bug-specs) (cdenom-bug-specs)))))
      md)))
