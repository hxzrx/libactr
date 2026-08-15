;;;; examples/past-tense-tutor.lisp — past-tense model loader + lexicon +
;;;; buggy library (Phase 10). Mirrors examples/fraction-tutor.lisp:
;;;; load-past-tense-model binds *PACKAGE* so all model symbols land in
;;;; :mtt/past-tense-tutor. Buggy rules are appended (mtt-only). KC attribution
;;;; is applied post-load via the declarative apply-kc-map (src/authoring.lisp).
;;;; NO global mutable state in this file (lexicon/analogy table are defuns
;;;; returning fresh/quoted literal data, not defparameters).
(defpackage :mtt/past-tense-tutor
  (:use :cl)
  (:nicknames :past-tense-tutor)
  (:export #:load-past-tense-model #:verb-info #:analogy-bugs))
(in-package :mtt/past-tense-tutor)

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

(defun buggy-rules ()
  "Three buggy rules for past-tense inflection, mirroring the fraction buggy
library: :kind keyword discriminant compared as a literal in =retrieval> bug-fact
(package-independent so the adapter in another package can prime a matching
bug-fact); :kc attributes each bug to the skill it misapplies; bug-fact verb/past
carry the student's answer."
  (flet ((bug (name kind kc feedback)
           (mtt:make-production
            name
            (list (mtt:make-buffer-pattern
                   'goal := 'past-tense-task
                   (list (mtt:make-slot-test 'past :literal nil)))
                  (mtt:make-buffer-pattern
                   'retrieval := 'bug-fact
                   (list (mtt:make-slot-test 'kind :literal kind)
                         (mtt:make-slot-test 'verb :variable '=v1)
                         (mtt:make-slot-test 'past :variable '=v2))))
            (list (mtt:make-action ':= 'goal (list (cons 'past '=v2))))
            kc :buggy feedback)))
    (list
     (bug 'buggy-over-regularize :over-regularize :irregular-retrieval
          "That verb is irregular — retrieve its past form instead of adding -ed.")
     (bug 'buggy-no-ed          :no-ed          :regular-inflection
          "This verb is regular — add -ed to form the past tense.")
     (bug 'buggy-vowel-analogy  :vowel-analogy  :irregular-retrieval
          "You swapped the vowel by analogy — this verb's past form is different."))))

(defun load-past-tense-model ()
  "Read+compile past-tense.lisp, attribute correct-production KCs, append the
buggy library. Model symbols land in :mtt/past-tense-tutor (*PACKAGE* binding)."
  (let ((*package* (find-package :mtt/past-tense-tutor)))
    (let ((md (mtt:compile-model
               (mtt:read-model-file
                (asdf:system-relative-pathname "mtt" "models/past-tense.lisp")))))
      (mtt:apply-kc-map
       md
       '((retrieve-irregular . :irregular-retrieval)
         (apply-regular     . :regular-inflection)))
      (setf (mtt:model-definition-productions md)
            (append (mtt:model-definition-productions md) (buggy-rules)))
      md)))
