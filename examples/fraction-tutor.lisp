;;;; examples/fraction-tutor.lisp — fraction model loader + buggy library (Phase 7).
;;;; Mirrors examples/addition-tutor.lisp: load-fraction-model binds *PACKAGE* so
;;;; all model symbols (FRAC-ADD, NUM1, FIND-COMMON-DENOMINATOR, ...) land in
;;;; :mtt/fraction-tutor. Buggy rules are appended (mtt-only). KC attribution is
;;;; applied post-load via the declarative apply-kc-map utility (src/authoring.lisp)
;;;; so correct+buggy group into 2 skill KCs. NO global mutable state in this file.
(defpackage :mtt/fraction-tutor
  (:use :cl)
  (:nicknames :fraction-tutor)
  (:export #:load-fraction-model))
(in-package :mtt/fraction-tutor)

(defun buggy-rules ()
  "Four illustrative buggy rules for fraction addition. :kind is a KEYWORD
discriminant (compared as a literal in each production's =retrieval> bug-fact
test) — keywords are package-independent so the adapter (in a different package)
can prime a matching bug-fact. :kc attributes each bug to the skill it
misapplies. bug-fact num/denom carry the student's wrong answer (for
buggy-use-product, num = wrong cdenom, denom unused)."
  (flet ((bug (name kind kc feedback)
           (let ((use-product-p (eq kind :use-product)))
             (mtt:make-production
              name
              (list (mtt:make-buffer-pattern
                     'goal := 'frac-add
                     (list (mtt:make-slot-test (if use-product-p 'cdenom 'snum)
                                               :literal nil)))
                    (mtt:make-buffer-pattern
                     'retrieval := 'bug-fact
                     (list (mtt:make-slot-test 'kind :literal kind)
                           (mtt:make-slot-test 'num :variable '=v1)
                           (mtt:make-slot-test 'denom :variable '=v2))))
              (list (mtt:make-action
                     ':= 'goal
                     (if use-product-p
                         (list (cons 'cdenom '=v1))
                         (list (cons 'snum '=v1) (cons 'sdenom '=v2)))))
              kc :buggy feedback))))
    (list
     (bug 'buggy-add-across      :add-across      :add-fractions
          "You added the denominators. Find a common denominator first.")
     (bug 'buggy-keep-left-denom :keep-left-denom :add-fractions
          "You kept the first denominator — both must share a common denominator.")
     (bug 'buggy-no-convert      :no-convert      :add-fractions
          "Right common denominator, but convert each numerator before adding.")
     (bug 'buggy-use-product     :use-product     :common-denominator
          "That's the product of the denominators, not the least common denominator."))))

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
            (append (mtt:model-definition-productions md) (buggy-rules)))
      md)))
