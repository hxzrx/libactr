;;;; examples/past-tense-tutor.lisp — past-tense model loader + lexicon +
;;;; buggy library (Phase 10). Mirrors examples/fraction-tutor.lisp:
;;;; load-past-tense-model binds *PACKAGE* so all model symbols land in
;;;; :libactr/past-tense-tutor. Buggy rules are appended (libactr-only). KC attribution
;;;; is applied post-load via the declarative apply-kc-map (src/authoring.lisp).
;;;; NO global mutable state in this file (lexicon/analogy table are defuns
;;;; returning fresh/quoted literal data, not defparameters).
(defpackage :libactr/past-tense-tutor
  (:use :cl)
  (:nicknames :past-tense-tutor)
  (:export #:load-past-tense-model #:verb-info #:analogy-bugs #:bug-specs))
(in-package :libactr/past-tense-tutor)

(defun verb-info (verb)
  "Look up VERB (string designator, case-insensitive) in the domain lexicon ->
(values regular-p correct-past), both correct-past and the inputs are uppercase
strings. Second value nil signals an unknown verb. No-change irregulars (put,
cut, hit) have correct-past = the stem."
  (let* ((v (string-upcase (string verb)))
         (regular   '(("WALK" . "WALKED") ("JUMP" . "JUMPED")
                      ("PLAY" . "PLAYED") ("HELP" . "HELPED")))
         (irregular '(("GO" . "WENT") ("RUN" . "RAN") ("SING" . "SANG")
                      ("BRING" . "BROUGHT") ("CATCH" . "CAUGHT")
                      ("PUT" . "PUT") ("CUT" . "CUT") ("HIT" . "HIT"))))
    (cond ((assoc v regular :test #'string=)
           (values t (cdr (assoc v regular :test #'string=))))
          ((assoc v irregular :test #'string=)
           (values nil (cdr (assoc v irregular :test #'string=))))
          (t (values nil nil)))))

(defun analogy-bugs ()
  "Known vowel-analogy wrong forms (bug 3 lookup table, not computable):
bring->brang (by sing/sang), catch->cought (by teach/taught). Uppercase strings."
  '(("BRING" . "BRANG") ("CATCH" . "COUGHT")))

(defun bug-specs ()
  "Three bug declarations for past-tense inflection (phase 12 spec §2.2) —
the F5 lookup family through the DSL's named-predicate extension: the :when
forms call DOMAIN predicates (verb+ed-p / string= / analogy-p, defined in
src/past-tense-adapter.lisp) registered by the adapter's bug-predicates
table. known-p guards over-regularize so UNKNOWN verbs stay unclassified
(the old branch tested correct non-nil). List order IS the detection order."
  (list
   (libactr:make-bug-spec
    :name 'buggy-over-regularize :kind :over-regularize :kc :irregular-retrieval
    :feedback "That verb is irregular — retrieve its past form instead of adding -ed."
    :goal-type 'past-tense-task
    :answers '((:action "value" :slot past :as answer))
    :fact-slots '((verb :from (:goal verb)) (past :from (:answer 0)))
    :when '(and known-p (not regular-p) (verb+ed-p answer verb)))
   (libactr:make-bug-spec
    :name 'buggy-no-ed :kind :no-ed :kc :regular-inflection
    :feedback "This verb is regular — add -ed to form the past tense."
    :goal-type 'past-tense-task
    :answers '((:action "value" :slot past :as answer))
    :fact-slots '((verb :from (:goal verb)) (past :from (:answer 0)))
    :when '(and regular-p (string= answer verb)))
   (libactr:make-bug-spec
    :name 'buggy-vowel-analogy :kind :vowel-analogy :kc :irregular-retrieval
    :feedback "You swapped the vowel by analogy — this verb's past form is different."
    :goal-type 'past-tense-task
    :answers '((:action "value" :slot past :as answer))
    :fact-slots '((verb :from (:goal verb)) (past :from (:answer 0)))
    :when '(analogy-p answer verb))))

(defun load-past-tense-model ()
  "Read+compile past-tense.lisp, attribute correct-production KCs, append the
buggy library. Model symbols land in :libactr/past-tense-tutor (*PACKAGE* binding)."
  (let ((*package* (find-package :libactr/past-tense-tutor)))
    (let ((md (libactr:compile-model
               (libactr:read-model-file
                (asdf:system-relative-pathname "libactr" "models/past-tense.lisp")))))
      (libactr:apply-kc-map
       md
       '((retrieve-irregular . :irregular-retrieval)
         (apply-regular     . :regular-inflection)))
      (setf (libactr:model-definition-productions md)
            (append (libactr:model-definition-productions md)
                    (mapcar #'libactr:bug-production (bug-specs))))
      md)))
