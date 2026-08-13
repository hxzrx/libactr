;;;; src/fraction-adapter.lisp — fraction reference adapter (Phase 7, spec §6.2).
;;;; Implements the 3-method adapter protocol for the fraction-addition model.
;;;; The ADAPTER IS THE DOMAIN BRAIN (spec §2): it computes the correct answer,
;;;; detects the bug pattern, and primes retrieval with the matching fact so the
;;;; matcher confirms and routes (on-path / off-path-buggy / off-path). Stateless;
;;;; all state lives on the session passed into each method. NO global variables.
(defpackage :mtt/fraction-adapter
  (:use :cl)
  (:nicknames :fraction-adapter)
  (:export #:fraction-adapter #:make-fraction-adapter #:build-fraction-model))
(in-package :mtt/fraction-adapter)

(defclass fraction-adapter (mtt:standard-domain-adapter) ()
  (:documentation "Reference fraction domain adapter (unlike-denominator addition).
Stateless: all state lives on the session passed into each method. Subclasses
standard-domain-adapter for reusable plumbing (spec §3)."))

(defun make-fraction-adapter ()
  (make-instance 'fraction-adapter
                 :model-package (find-package :mtt/fraction-tutor)
                 :terminal-production "ADD-FRACTIONS"))

(defun build-fraction-model ()
  "Read+compile the fraction model + buggy library (reuses mtt/fraction-tutor)."
  (mtt/fraction-tutor:load-fraction-model))

;;; --- domain helpers (plumbing comes from standard-domain-adapter) ---

(defun %gcd (a b) (if (zerop b) a (%gcd b (mod a b))))
(defun %lcm (a b) (/ (* a b) (%gcd a b)))

(defun %parse-problem (problem-id)
  "Parse \"a/b+c/d\" -> values num1 den1 num2 den2 (integers)."
  (let* ((s (princ-to-string problem-id))
         (plus (position #\+ s))
         (slash1 (position #\/ s)))
    (unless (and plus slash1)
      (error "mtt/fraction-adapter: cannot parse problem-id ~a (expected \"a/b+c/d\")"
             problem-id))
    (let ((slash2 (position #\/ s :start (1+ plus))))
      (unless slash2
        (error "mtt/fraction-adapter: cannot parse problem-id ~a (expected \"a/b+c/d\")"
               problem-id))
      (values (parse-integer (subseq s 0 slash1))
              (parse-integer (subseq s (1+ slash1) plus))
              (parse-integer (subseq s (1+ plus) slash2))
              (parse-integer (subseq s (1+ slash2)))))))

(defun %action-int (action key)
  (parse-integer (cdr (assoc key action :test #'string=))))

;;; --- adapter protocol ---

(defmethod mtt:prepare-session ((a fraction-adapter) session problem-id)
  "Parse PROBLEM-ID into the goal's num1/den1/num2/den2 (integers), overriding the
model's default initial-goal so one compiled model serves any problem."
  (multiple-value-bind (num1 den1 num2 den2) (%parse-problem problem-id)
    (mtt:adapter-set-goal a session "FRAC-ADD"
                          :num1 num1 :den1 den1 :num2 num2 :den2 den2
                          :cdenom nil :snum nil :sdenom nil))
  session)

(defmethod mtt:adapt-action ((a fraction-adapter) action session)
  "Translate a decoded student ACTION alist into a primed step-intent. The adapter
computes the correct value, detects the bug (if any), and primes retrieval with
the matching fact (lcm-fact / sum-fact / bug-fact). See spec §6."
  (flet ((gi (name) (mtt:adapter-intern a name)))
    (let* ((type (cdr (assoc "type" action :test #'string=)))
           (num1 (mtt:adapter-goal-slot a session "NUM1"))
           (den1 (mtt:adapter-goal-slot a session "DEN1"))
           (num2 (mtt:adapter-goal-slot a session "NUM2"))
           (den2 (mtt:adapter-goal-slot a session "DEN2"))
           (cdenom (mtt:adapter-goal-slot a session "CDENOM")))
      (cond
        ((string= type "common-denom")
         (let* ((student (%action-int action "value"))
                (correct (%lcm den1 den2)))
           (cond
             ((= student correct)
              (mtt:adapter-primed-intent
               a
               `((,(gi "GOAL") ,(gi "CDENOM") ,correct))
               (mtt:adapter-fact a "LCM-FACT" :d1 den1 :d2 den2 :lcm correct)))
             ((= student (* den1 den2))        ; use-product (only a bug when ≠ LCM)
              (mtt:adapter-primed-intent
               a
               `((,(gi "GOAL") ,(gi "CDENOM") ,student))
               (mtt:adapter-fact a "BUG-FACT" :kind :use-product :num student :denom 0)))
             (t                                ; unclassified: prime nothing
              (mtt:make-step-intent
               :assignments `((,(gi "GOAL") ,(gi "CDENOM") ,student)))))))
        ((string= type "sum")
         (let* ((ssnum (%action-int action "num"))
                (ssdenom (%action-int action "denom"))
                (cnum1 (* num1 (/ cdenom den1)))
                (cnum2 (* num2 (/ cdenom den2)))
                (correct-snum (+ cnum1 cnum2))
                (correct-sdenom cdenom))
           (cond
             ((and (= ssnum correct-snum) (= ssdenom correct-sdenom))
              (mtt:adapter-primed-intent
               a
               `((,(gi "GOAL") ,(gi "SNUM") ,ssnum)
                 (,(gi "GOAL") ,(gi "SDENOM") ,ssdenom))
               (mtt:adapter-fact a "SUM-FACT" :cdenom cdenom :snum ssnum :sdenom ssdenom)))
             ((and (= ssnum (+ num1 num2)) (= ssdenom (+ den1 den2)))
              (mtt:adapter-primed-intent
               a
               `((,(gi "GOAL") ,(gi "SNUM") ,ssnum)
                 (,(gi "GOAL") ,(gi "SDENOM") ,ssdenom))
               (mtt:adapter-fact a "BUG-FACT" :kind :add-across :num ssnum :denom ssdenom)))
             ((and (= ssnum (+ num1 num2)) (= ssdenom den1))
              (mtt:adapter-primed-intent
               a
               `((,(gi "GOAL") ,(gi "SNUM") ,ssnum)
                 (,(gi "GOAL") ,(gi "SDENOM") ,ssdenom))
               (mtt:adapter-fact a "BUG-FACT" :kind :keep-left-denom :num ssnum :denom ssdenom)))
             ((and (= ssnum (+ num1 num2)) (= ssdenom cdenom))
              (mtt:adapter-primed-intent
               a
               `((,(gi "GOAL") ,(gi "SNUM") ,ssnum)
                 (,(gi "GOAL") ,(gi "SDENOM") ,ssdenom))
               (mtt:adapter-fact a "BUG-FACT" :kind :no-convert :num ssnum :denom ssdenom)))
             (t
              (mtt:make-step-intent
               :assignments `((,(gi "GOAL") ,(gi "SNUM") ,ssnum)
                              (,(gi "GOAL") ,(gi "SDENOM") ,ssdenom)))))))
        (t
         (error "mtt/fraction-adapter: unknown action type ~a" type))))))
