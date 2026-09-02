;;;; src/fraction-adapter.lisp — fraction reference adapter (Phase 7, spec §6.2).
;;;; Implements the 3-method adapter protocol for the fraction-addition model.
;;;; The ADAPTER IS THE DOMAIN BRAIN (spec §2): it computes the correct answer,
;;;; detects the bug pattern, and primes retrieval with the matching fact so the
;;;; matcher confirms and routes (on-path / off-path-buggy / off-path). The bug
;;;; branches at both action types are now driven by the phase-12 bug-DSL
;;;; (per-action-type spec lists; list order IS the detection order). Stateless;
;;;; all state lives on the session passed into each method. NO global variables.
(defpackage :libactr/fraction-adapter
  (:use :cl)
  (:nicknames :fraction-adapter)
  (:export #:fraction-adapter #:make-fraction-adapter #:build-fraction-model))
(in-package :libactr/fraction-adapter)

(defclass fraction-adapter (libactr:standard-domain-adapter) ()
  (:documentation "Reference fraction domain adapter (unlike-denominator addition).
Stateless: all state lives on the session passed into each method. Subclasses
standard-domain-adapter for reusable plumbing (spec §3)."))

(defun make-fraction-adapter ()
  (make-instance 'fraction-adapter
                 :model-package (find-package :libactr/fraction-tutor)
                 :terminal-production '("ADD-FRACTIONS" "SIMPLIFY")))

(defun build-fraction-model ()
  "Read+compile the fraction model + buggy library (reuses libactr/fraction-tutor)."
  (libactr/fraction-tutor:load-fraction-model))

;;; --- domain helpers (plumbing comes from standard-domain-adapter) ---

(defun %gcd (a b) (if (zerop b) a (%gcd b (mod a b))))
(defun %lcm (a b) (/ (* a b) (%gcd a b)))

(defun %parse-problem (problem-id)
  "Parse \"a/b+c/d\" -> values num1 den1 num2 den2 (integers). Semantic
constraint (phase 12 debt #1): positive denominators — \"1/0+…\" used to
reach %lcm and crash with a division by zero. All failures signal
bad-tutor-request (400 over HTTP)."
  (flet ((bad ()
           (libactr:signal-bad-request
            "libactr/fraction-adapter: cannot parse problem-id ~a (expected \"a/b+c/d\")"
            problem-id))
         (int (part)
           (handler-case (parse-integer part)
             (parse-error () (bad)))))
    (let* ((s (princ-to-string problem-id))
           (plus (position #\+ s))
           (slash1 (position #\/ s)))
      (unless (and plus slash1) (bad))
      (let ((slash2 (position #\/ s :start (1+ plus))))
        (unless slash2 (bad))
        (let ((num1 (int (subseq s 0 slash1)))
              (den1 (int (subseq s (1+ slash1) plus)))
              (num2 (int (subseq s (1+ plus) slash2)))
              (den2 (int (subseq s (1+ slash2)))))
          (unless (and (> den1 0) (> den2 0))
            (libactr:signal-bad-request
             "libactr/fraction-adapter: denominators must be positive in problem-id ~a"
             problem-id))
          (values num1 den1 num2 den2))))))

(defun %action-int (action key)
  "The student's integer answer for KEY; a non-integer signals
bad-tutor-request."
  (let ((raw (cdr (assoc key action :test #'string=))))
    (handler-case (parse-integer raw)
      (parse-error ()
        (libactr:signal-bad-request
         "libactr/fraction-adapter: action ~a must be an integer, got ~s" key raw)))))

;;; --- adapter protocol ---

(defmethod libactr:prepare-session ((a fraction-adapter) session problem-id)
  "Parse PROBLEM-ID into the goal's num1/den1/num2/den2 (integers), overriding the
model's default initial-goal so one compiled model serves any problem."
  (multiple-value-bind (num1 den1 num2 den2) (%parse-problem problem-id)
    (libactr:adapter-set-goal a session "FRAC-ADD"
                          :num1 num1 :den1 den1 :num2 num2 :den2 den2
                          :cdenom nil :snum nil :sdenom nil
                          :rnum nil :rdenom nil))
  session)

(defmethod libactr:adapt-action ((a fraction-adapter) action session)
  "Translate a decoded student ACTION alist into a primed step-intent. The adapter
computes the correct value, detects the bug (if any), and primes retrieval with
the matching fact (lcm-fact / sum-fact / reduce-fact / bug-fact). See spec §6."
  (flet ((gi (name) (libactr:adapter-intern a name)))
    (let* ((type (cdr (assoc "type" action :test #'string=)))
           (num1 (libactr:adapter-goal-slot a session "NUM1"))
           (den1 (libactr:adapter-goal-slot a session "DEN1"))
           (num2 (libactr:adapter-goal-slot a session "NUM2"))
           (den2 (libactr:adapter-goal-slot a session "DEN2"))
           (cdenom (libactr:adapter-goal-slot a session "CDENOM")))
      (cond
        ((string= type "common-denom")
         (let* ((student (%action-int action "value"))
                (correct (%lcm den1 den2)))
           (cond
             ((= student correct)
              (libactr:adapter-primed-intent
               a
               `((,(gi "GOAL") ,(gi "CDENOM") ,correct))
               (libactr:adapter-fact a "LCM-FACT" :d1 den1 :d2 den2 :lcm correct)))
             (t
              (let* ((answers (list student))
                     (spec (libactr:detect-bug
                            (libactr/fraction-tutor:cdenom-bug-specs) answers
                            (libactr:bug-goal-env a session))))
                (if spec
                    (libactr:bug-intent a session spec answers)
                    (libactr:make-step-intent
                     :assignments `((,(gi "GOAL") ,(gi "CDENOM") ,student)))))))))
        ((string= type "sum")
         ;; B1 (phase 14): out-of-order guard — cdenom unset means the
         ;; common-denominator step has not run; (/ cdenom den1) on nil was
         ;; a TYPE-ERROR 500.
         (unless cdenom
           (libactr:signal-bad-request
            "libactr/fraction-adapter: \"sum\" submitted before the common-denominator step"))
         (let* ((ssnum (%action-int action "num"))
                (ssdenom (%action-int action "denom"))
                (cnum1 (* num1 (/ cdenom den1)))
                (cnum2 (* num2 (/ cdenom den2)))
                (correct-snum (+ cnum1 cnum2))
                (correct-sdenom cdenom))
           (cond
             ((and (= ssnum correct-snum) (= ssdenom correct-sdenom))
              (libactr:adapter-primed-intent
               a
               `((,(gi "GOAL") ,(gi "SNUM") ,ssnum)
                 (,(gi "GOAL") ,(gi "SDENOM") ,ssdenom))
               (libactr:adapter-fact a "SUM-FACT" :cdenom cdenom :snum ssnum :sdenom ssdenom)))
             (t
              (let* ((answers (list ssnum ssdenom))
                     (spec (libactr:detect-bug
                            (libactr/fraction-tutor:sum-bug-specs) answers
                            (libactr:bug-goal-env a session))))
                (if spec
                    (libactr:bug-intent a session spec answers)
                    (libactr:make-step-intent
                     :assignments `((,(gi "GOAL") ,(gi "SNUM") ,ssnum)
                                    (,(gi "GOAL") ,(gi "SDENOM") ,ssdenom)))))))))
        ((string= type "simplify")
         (let* ((rnum (%action-int action "num"))
                (rdenom (%action-int action "denom"))
                (snum (libactr:adapter-goal-slot a session "SNUM"))
                (sdenom (libactr:adapter-goal-slot a session "SDENOM")))
           ;; B1 (phase 14): out-of-order guard — %gcd nil nil was a
           ;; TYPE-ERROR 500.
           (unless (and snum sdenom)
             (libactr:signal-bad-request
              "libactr/fraction-adapter: \"simplify\" submitted before the sum step"))
           (let ((g (%gcd snum sdenom)))
             (cond
               ((and (> g 1) (= rnum (/ snum g)) (= rdenom (/ sdenom g)))
                (libactr:adapter-primed-intent
                 a
                 `((,(gi "GOAL") ,(gi "RNUM") ,rnum)
                   (,(gi "GOAL") ,(gi "RDENOM") ,rdenom))
                 (libactr:adapter-fact a "REDUCE-FACT"
                                   :num snum :den sdenom :rnum rnum :rdenom rdenom)))
               ((= g 1)
                (libactr:signal-bad-request
                 "libactr/fraction-adapter: the sum is already in lowest terms — no simplify step for this problem"))
               (t                            ; wrong reduction: unclassified off-path
                (libactr:make-step-intent
                 :assignments `((,(gi "GOAL") ,(gi "RNUM") ,rnum)
                                (,(gi "GOAL") ,(gi "RDENOM") ,rdenom))))))))
        (t
         (libactr:signal-bad-request "libactr/fraction-adapter: unknown action type ~a" type))))))

;;; --- Phase 13: conditional termination --------------------------------------
;;; The terminal-name list cannot express "ADD-FRACTIONS is terminal ONLY when
;;; the summed fraction is already in lowest terms" (ANY-match would end a
;;; simplifiable problem one step early), so this adapter overrides step-done?
;;; locally (mirrors the pre-phase-8 per-domain local override precedent; phase
;;; 13 spec §8 amendment). The override governs; the terminal list above is
;;; documentation config.

(defmethod libactr:step-done? ((a fraction-adapter) trace-result session)
  "Conditional termination (phase 13 spec §8 amendment): SIMPLIFY on-path is
always done; ADD-FRACTIONS on-path is done ONLY when the summed fraction is
already in lowest terms (gcd(snum,sdenom)=1, read from the session goal) —
the terminal-name list cannot express this (ANY-match would end simplifiable
problems one step early). Other productions are never done."
  (and (eq :on-path (libactr:trace-result-status trace-result))
       (let ((p (libactr:trace-result-production trace-result)))
         (and p
              (let ((n (symbol-name (libactr:production-name p))))
                (cond
                  ((string= "SIMPLIFY" n) t)
                  ((string= "ADD-FRACTIONS" n)
                   (= 1 (%gcd (libactr:adapter-goal-slot a session "SNUM")
                              (libactr:adapter-goal-slot a session "SDENOM"))))
                  (t nil)))))))
