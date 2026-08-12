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

(defclass fraction-adapter (mtt:domain-adapter) ()
  (:documentation "Reference fraction domain adapter (unlike-denominator addition).
Stateless: all state lives on the session passed into each method."))

(defun make-fraction-adapter ()
  (make-instance 'fraction-adapter))

(defun build-fraction-model ()
  "Read+compile the fraction model + buggy library (reuses mtt/fraction-tutor)."
  (mtt/fraction-tutor:load-fraction-model))

;;; --- helpers ---

(declaim (inline %frac))
(defun %frac (name)
  "Intern NAME in :mtt/fraction-tutor, where load-fraction-model interns all model
symbols (FRAC-ADD, NUM1, RETRIEVAL, ...). Use for every model data symbol so
eq-hash buffer/slot lookups match the model."
  (intern name "MTT/FRACTION-TUTOR"))

(defun %gcd (a b) (if (zerop b) a (%gcd b (mod a b))))
(defun %lcm (a b) (/ (* a b) (%gcd a b)))

(defun %goal-slot (session slot-name)
  "Read SLOT-NAME (string) from SESSION's goal buffer chunk; returns an integer or nil."
  (let ((chunk (mtt:buffer-chunk (mtt:session-state session) (%frac "GOAL"))))
    (when chunk
      (cdr (assoc (%frac slot-name) (mtt:chunk-slots chunk))))))

(defun %fact-chunk (type-name &rest slot-plist)
  "Build a chunk isa=TYPE-NAME (string) with slots from SLOT-PLIST (:slot val ...).
Slot names interned via %frac; values pass through (integers)."
  (let (slots)
    (loop :for (k v) :on slot-plist :by #'cddr
          :do (push (cons (%frac (string k)) v) slots))
    (mtt:make-chunk :isa (%frac type-name) :slots (nreverse slots))))

(defun %prime-pair (chunk)
  "The (RETRIEVAL . chunk) pair for a step-intent's PRIME slot."
  (cons (%frac "RETRIEVAL") chunk))

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
  (declare (ignore a))
  (multiple-value-bind (num1 den1 num2 den2) (%parse-problem problem-id)
    (setf (mtt:buffer-chunk (mtt:session-state session) (%frac "GOAL"))
          (mtt:make-chunk :isa (%frac "FRAC-ADD")
                          :slots `((,(%frac "NUM1") . ,num1)
                                   (,(%frac "DEN1") . ,den1)
                                   (,(%frac "NUM2") . ,num2)
                                   (,(%frac "DEN2") . ,den2)
                                   (,(%frac "CDENOM") . nil)
                                   (,(%frac "SNUM") . nil)
                                   (,(%frac "SDENOM") . nil)))))
  session)

(defun %intent (assignments prime-chunk)
  "Build a single step-intent with ASSIGNMENTS and a retrieval prime of PRIME-CHUNK."
  (mtt:make-step-intent
   :assignments assignments
   :prime (list (%prime-pair prime-chunk))))

(defmethod mtt:adapt-action ((a fraction-adapter) action session)
  "Translate a decoded student ACTION alist into a primed step-intent. The adapter
computes the correct value, detects the bug (if any), and primes retrieval with
the matching fact (lcm-fact / sum-fact / bug-fact). See spec §6."
  (declare (ignore a))
  (let* ((type (cdr (assoc "type" action :test #'string=)))
         (num1 (%goal-slot session "NUM1")) (den1 (%goal-slot session "DEN1"))
         (num2 (%goal-slot session "NUM2")) (den2 (%goal-slot session "DEN2"))
         (cdenom (%goal-slot session "CDENOM")))
    (cond
      ((string= type "common-denom")
       (let* ((student (%action-int action "value"))
              (correct (%lcm den1 den2)))
         (cond
           ((= student correct)
            (%intent `((,(%frac "GOAL") ,(%frac "CDENOM") ,correct))
                     (%fact-chunk "LCM-FACT" :d1 den1 :d2 den2 :lcm correct)))
           ((= student (* den1 den2))      ; use-product (only a bug when ≠ LCM)
            (%intent `((,(%frac "GOAL") ,(%frac "CDENOM") ,student))
                     (%fact-chunk "BUG-FACT" :kind :use-product :num student :denom 0)))
           (t                              ; unclassified: prime nothing
            (mtt:make-step-intent
             :assignments `((,(%frac "GOAL") ,(%frac "CDENOM") ,student)))))))
      ((string= type "sum")
       (let* ((ssnum (%action-int action "num"))
              (ssdenom (%action-int action "denom"))
              (cnum1 (* num1 (/ cdenom den1)))
              (cnum2 (* num2 (/ cdenom den2)))
              (correct-snum (+ cnum1 cnum2))
              (correct-sdenom cdenom))
         (cond
           ((and (= ssnum correct-snum) (= ssdenom correct-sdenom))
            (%intent `((,(%frac "GOAL") ,(%frac "SNUM") ,ssnum)
                       (,(%frac "GOAL") ,(%frac "SDENOM") ,ssdenom))
                     (%fact-chunk "SUM-FACT" :cdenom cdenom :snum ssnum :sdenom ssdenom)))
           ((and (= ssnum (+ num1 num2)) (= ssdenom (+ den1 den2)))
            (%intent `((,(%frac "GOAL") ,(%frac "SNUM") ,ssnum)
                       (,(%frac "GOAL") ,(%frac "SDENOM") ,ssdenom))
                     (%fact-chunk "BUG-FACT" :kind :add-across :num ssnum :denom ssdenom)))
           ((and (= ssnum (+ num1 num2)) (= ssdenom den1))
            (%intent `((,(%frac "GOAL") ,(%frac "SNUM") ,ssnum)
                       (,(%frac "GOAL") ,(%frac "SDENOM") ,ssdenom))
                     (%fact-chunk "BUG-FACT" :kind :keep-left-denom :num ssnum :denom ssdenom)))
           ((and (= ssnum (+ num1 num2)) (= ssdenom cdenom))
            (%intent `((,(%frac "GOAL") ,(%frac "SNUM") ,ssnum)
                       (,(%frac "GOAL") ,(%frac "SDENOM") ,ssdenom))
                     (%fact-chunk "BUG-FACT" :kind :no-convert :num ssnum :denom ssdenom)))
           (t
            (mtt:make-step-intent
             :assignments `((,(%frac "GOAL") ,(%frac "SNUM") ,ssnum)
                            (,(%frac "GOAL") ,(%frac "SDENOM") ,ssdenom)))))))
      (t
       (error "mtt/fraction-adapter: unknown action type ~a" type)))))

(defmethod mtt:step-done? ((a fraction-adapter) trace-result session)
  "True when add-fractions fired on-path (the terminal correct step)."
  (declare (ignore a session))
  (and (eq :on-path (mtt:trace-result-status trace-result))
       (let ((p (mtt:trace-result-production trace-result)))
         (and p (string= "ADD-FRACTIONS" (symbol-name (mtt:production-name p)))))))
