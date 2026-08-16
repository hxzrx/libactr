;;;; examples/subtraction-tutor.lisp — subtraction model loader + buggy
;;;; library (Phase 11). Mirrors examples/fraction-tutor.lisp:
;;;; load-subtraction-model binds *PACKAGE* so all model symbols land in
;;;; :mtt/subtraction-tutor. Buggy rules are appended (mtt-only). KC attribution
;;;; is applied post-load via the declarative apply-kc-map (src/authoring.lisp)
;;;; so correct productions group into the 2 skill KCs. NO global mutable state
;;;; in this file.
(defpackage :mtt/subtraction-tutor
  (:use :cl)
  (:nicknames :subtraction-tutor)
  (:export #:load-subtraction-model))
(in-package :mtt/subtraction-tutor)

(defun buggy-rules ()
  "Three buggy rules for 2-digit column subtraction (all detected at the ONES
column, spec §4). :kind is a KEYWORD discriminant (compared as a literal in each
production's =retrieval> bug-fact test — keywords are package-independent so
the adapter in another package can prime a matching bug-fact). :kc attributes
each bug to the skill it misapplies: borrow-ignore / always-borrow misuse the
BORROW skill; off-by-one sets up the borrow correctly but slips the subtraction
fact (column-subtract skill). bug-fact digit carries the student's wrong
answer."
  (flet ((bug (name kind kc feedback)
           (mtt:make-production
            name
            (list (mtt:make-buffer-pattern
                   'goal := 'sub2
                   (list (mtt:make-slot-test 'stage :literal 'ones)
                         (mtt:make-slot-test 'res-ones :literal nil)))
                  (mtt:make-buffer-pattern
                   'retrieval := 'bug-fact
                   (list (mtt:make-slot-test 'kind :literal kind)
                         (mtt:make-slot-test 'digit :variable '=v1))))
            (list (mtt:make-action ':= 'goal (list (cons 'res-ones '=v1))))
            kc :buggy feedback)))
    (list
     (bug 'buggy-borrow-ignore :borrow-ignore :borrow
          "The ones digit was too small — you needed to borrow from the tens. Subtracting the small from the large ignores the borrow.")
     (bug 'buggy-always-borrow :always-borrow :borrow
          "You borrowed in a column that didn't need it — the top digit was already big enough.")
     (bug 'buggy-off-by-one :off-by-one :column-subtract
          "You set up the borrow correctly but slipped on the subtraction fact."))))

(defun load-subtraction-model ()
  "Read+compile subtraction.lisp, attribute correct-production KCs, append the
buggy library. Model symbols land in :mtt/subtraction-tutor (*PACKAGE*
binding). The borrow pair subtract-ones-borrow + propagate-borrow shares the
:borrow KC (propagation is the bookkeeping half of the borrowing skill);
direct columns share :column-subtract."
  (let ((*package* (find-package :mtt/subtraction-tutor)))
    (let ((md (mtt:compile-model
               (mtt:read-model-file
                (asdf:system-relative-pathname "mtt" "models/subtraction.lisp")))))
      (mtt:apply-kc-map
       md
       '((subtract-ones-direct  . :column-subtract)
         (subtract-ones-borrow  . :borrow)
         (propagate-borrow      . :borrow)
         (subtract-tens-direct  . :column-subtract)))
      (setf (mtt:model-definition-productions md)
            (append (mtt:model-definition-productions md) (buggy-rules)))
      md)))
