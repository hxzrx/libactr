;;;; tests/test-past-tense-tutor.lisp — past-tense model load/KC/buggy (Phase 10).
(defpackage :libactr/past-tense-tutor-test
  (:use :cl :5am :libactr/past-tense-tutor))
(in-package :libactr/past-tense-tutor-test)

(def-suite :libactr/past-tense-tutor :description "past-tense model load + buggy library")
(in-suite :libactr/past-tense-tutor)

(defun %prod-names (md)
  (mapcar #'libactr:production-name (libactr:model-definition-productions md)))

(defun %kc-of (md name)
  (libactr:production-kc
   (find name (libactr:model-definition-productions md)
         :key (lambda (x) (symbol-name (libactr:production-name x)))
         :test #'string=)))

(test load-past-tense-model.shape
  "load-past-tense-model yields 2 correct + 3 buggy productions; correct ones
are attributed to the 2 skill KCs; buggy ones to their misapplied-skill KCs;
production names land in :libactr/past-tense-tutor."
  (let ((md (load-past-tense-model)))
    (is (= 5 (length (libactr:model-definition-productions md))))
    (let ((names (%prod-names md)))
      (dolist (n '(retrieve-irregular apply-regular
                   buggy-over-regularize buggy-no-ed buggy-vowel-analogy))
        (is (find n names :key #'symbol-name :test #'string=)
            "missing production ~a" n)))
    (is (eq :irregular-retrieval (%kc-of md 'retrieve-irregular)))
    (is (eq :regular-inflection    (%kc-of md 'apply-regular)))
    (is (eq :irregular-retrieval (%kc-of md 'buggy-over-regularize)))
    (is (eq :regular-inflection    (%kc-of md 'buggy-no-ed)))
    (is (eq :irregular-retrieval (%kc-of md 'buggy-vowel-analogy)))
    ;; symbols live in the model package
    (is (eq (find-package :libactr/past-tense-tutor)
            (symbol-package
             (libactr:chunk-isa (libactr:model-definition-initial-goal md)))))))

(test verb-info.lexicon
  "verb-info classifies regular/irregular/no-change and rejects unknown verbs."
  (multiple-value-bind (reg past) (verb-info "walk")
    (is (eq t reg)) (is (string= "WALKED" past)))
  (multiple-value-bind (reg past) (verb-info "Go")     ; case-insensitive
    (is (null reg)) (is (string= "WENT" past)))
  (multiple-value-bind (reg past) (verb-info "put")    ; no-change irregular
    (is (null reg)) (is (string= "PUT" past)))
  (multiple-value-bind (reg past) (verb-info "wug")    ; unknown
    (is (null reg)) (is (null past))))

(test analogy-bugs.table
  "The vowel-analogy table holds the two documented wrong forms."
  (is (string= "BRANG"  (cdr (assoc "BRING" (analogy-bugs) :test #'string=))))
  (is (string= "COUGHT" (cdr (assoc "CATCH" (analogy-bugs) :test #'string=)))))

(test past-tense-adapter-gate-rejects-invalid-spec
  "C7: the adapter-construction gate actually signals on errors (the gate
lives in make-past-tense-adapter; its %validate-specs! is directly driven
here — mirrors fraction-loader-rejects-invalid-spec)."
  (is (fboundp 'libactr/past-tense-adapter::%validate-specs!))
  (signals error
    (libactr/past-tense-adapter::%validate-specs!
     (list (libactr:make-bug-spec
            :name 'buggy-x :kind :x :kc :x :goal-type 'past-tense-task
            :answers '((:action "value" :slot past :as answer))
            :fact-slots '((verb :from (:goal verb)))
            :when '(frobnicate answer))))))          ; unknown operator
