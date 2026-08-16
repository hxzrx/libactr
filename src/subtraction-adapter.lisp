;;;; src/subtraction-adapter.lisp — subtraction reference adapter (Phase 11,
;;;; spec §5). Implements the 3-method adapter protocol for the 2-digit
;;;; subtraction model. The ADAPTER IS THE DOMAIN BRAIN (Phase 7 §2 idiom): it
;;;; computes the correct column difference, detects the bug pattern, and
;;;; primes retrieval with the matching fact (col-fact with the discriminating
;;;; kind slot / bug-fact) so the matcher confirms and routes.
;;;;
;;;; CONDITIONAL MULTI-STEP (Phase 6 intent lists, third stress shape): a
;;;; borrow column returns a 2-element intent list — the visible
;;;; subtract-ones-borrow step, then the hidden propagate-borrow bookkeeping
;;;; step (the decremented tens digit is supplied via the fact, mirroring
;;;; addition's increment-sum + increment-count pair, but the list LENGTH is
;;;; conditional on the column needing a borrow). Non-borrow columns return a
;;;; single intent. The action's column is NOT carried by the action — the
;;;; goal's stage slot determines it (off-path steps leave stage unchanged, so
;;;; a wrong digit is retried against the same column, mirroring addition's
;;;; retry semantics).
;;;;
;;;; Detection order at the ones column (spec §4, proven mutually exclusive):
;;;; correct -> borrow-ignore (mirror; never collides with correct±1 since
;;;; 2(bot-top) ∈ {9,11} is impossible) -> always-borrow (value >= 10, only at
;;;; no-borrow columns) -> off-by-one (borrow columns only) -> unclassified.
;;;; The tens column only does correct / unclassified (spec §2.1: detection is
;;;; defined at ones; degenerate b-t=5 problems stay out of the bug corpus).
;;;; Stateless: all state lives on the session. NO global variables.
(defpackage :mtt/subtraction-adapter
  (:use :cl)
  (:nicknames :subtraction-adapter)
  (:export #:subtraction-adapter #:make-subtraction-adapter
           #:build-subtraction-model))
(in-package :mtt/subtraction-adapter)

(defclass subtraction-adapter (mtt:standard-domain-adapter) ()
  (:documentation "Reference subtraction domain adapter (2-digit column
subtraction with borrowing). Stateless. Subclasses standard-domain-adapter;
the single terminal production SUBTRACT-TENS-DIRECT and the default step-done?
are inherited — the fourth dogfood of the base."))

(defun make-subtraction-adapter ()
  (make-instance 'subtraction-adapter
                 :model-package (find-package :mtt/subtraction-tutor)
                 :terminal-production "SUBTRACT-TENS-DIRECT"))

(defun build-subtraction-model ()
  "Read+compile the subtraction model + buggy library (reuses
mtt/subtraction-tutor)."
  (mtt/subtraction-tutor:load-subtraction-model))

;;; --- domain helpers (plumbing comes from standard-domain-adapter) ---

(defun %parse-problem (problem-id)
  "Parse \"52-18\" -> values top bot (integers; top > bot is the domain
constraint — 2-digit minuend/subtrahend, positive result)."
  (let* ((s (princ-to-string problem-id))
         (dash (position #\- s)))
    (unless dash
      (error "mtt/subtraction-adapter: cannot parse problem-id ~a (expected \"NN-MM\")"
             problem-id))
    (values (parse-integer (subseq s 0 dash))
            (parse-integer (subseq s (1+ dash))))))

(defun %digit (n pos)
  "POS-th digit of integer N (0 = ones, 1 = tens)."
  (mod (floor n (expt 10 pos)) 10))

(defun %action-int (action)
  "The student's reported value (an integer digit; always-borrow answers may
be two-digit, e.g. 13)."
  (parse-integer (cdr (assoc "value" action :test #'string=))))

;;; --- adapter protocol ---

(defmethod mtt:prepare-session ((a subtraction-adapter) session problem-id)
  "Parse PROBLEM-ID into the goal's digit slots (integers) + stage=ones,
overriding the model's default initial-goal so one compiled model serves any
2-digit problem. Returns the session."
  (multiple-value-bind (top bot) (%parse-problem problem-id)
    (mtt:adapter-set-goal a session "SUB2"
                          :top-ones (%digit top 0) :top-tens (%digit top 1)
                          :bot-ones (%digit bot 0) :bot-tens (%digit bot 1)
                          :res-ones nil :res-tens nil
                          :stage (mtt:adapter-intern a "ONES")))
  session)

(defmethod mtt:adapt-action ((a subtraction-adapter) action session)
  "Translate a decoded student ACTION alist ((\"type\" . \"digit\")
  (\"value\" . \"4\")) into a primed step-intent — or, at a borrow column, a
2-element intent list (visible subtract-ones-borrow, then hidden
propagate-borrow). See the file header for the detection order and the
stage-driven column routing. Returns the intent(s) for server-step-session."
  (flet ((gi (name) (mtt:adapter-intern a name)))
    (let* ((type (cdr (assoc "type" action :test #'string=)))
           (d (%action-int action))
           (stage (mtt:adapter-goal-slot a session "STAGE"))
           (top-ones (mtt:adapter-goal-slot a session "TOP-ONES"))
           (bot-ones (mtt:adapter-goal-slot a session "BOT-ONES"))
           (top-tens (mtt:adapter-goal-slot a session "TOP-TENS"))
           (bot-tens (mtt:adapter-goal-slot a session "BOT-TENS")))
      (unless (string= type "digit")
        (error "mtt/subtraction-adapter: unknown action type ~a" type))
      (cond
        ((string= "ONES" (and stage (symbol-name stage)))
         (let ((correct (if (< top-ones bot-ones)
                            (+ 10 (- top-ones bot-ones))
                            (- top-ones bot-ones))))
           (cond
             ;; correct, no borrow needed: single intent
             ((and (>= top-ones bot-ones) (= d (- top-ones bot-ones)))
              (mtt:adapter-primed-intent
               a
               `((,(gi "GOAL") ,(gi "RES-ONES") ,d)
                 (,(gi "GOAL") ,(gi "STAGE") ,(gi "TENS")))
               (mtt:adapter-fact a "COL-FACT" :kind (gi "DIRECT")
                                 :top top-ones :bot bot-ones :diff d)))
             ;; correct, borrow needed: 2-intent list (visible + hidden
             ;; propagate whose fact supplies the decremented tens)
             ((and (< top-ones bot-ones) (= d correct))
              (list
               (mtt:adapter-primed-intent
                a
                `((,(gi "GOAL") ,(gi "RES-ONES") ,d)
                  (,(gi "GOAL") ,(gi "STAGE") ,(gi "PROPAGATE")))
                (mtt:adapter-fact a "COL-FACT" :kind (gi "BORROW")
                                  :top top-ones :bot bot-ones :diff d))
               (mtt:adapter-primed-intent
                a
                `((,(gi "GOAL") ,(gi "TOP-TENS") ,(- top-tens 1))
                  (,(gi "GOAL") ,(gi "STAGE") ,(gi "TENS")))
                (mtt:adapter-fact a "COL-FACT" :kind (gi "PROPAGATE")
                                  :old-top top-tens :new-top (- top-tens 1)))))
             ;; bug: borrow-ignore (smaller-from-larger mirror)
             ((and (< top-ones bot-ones) (= d (- bot-ones top-ones)))
              (mtt:adapter-primed-intent
               a
               `((,(gi "GOAL") ,(gi "RES-ONES") ,d))
               (mtt:adapter-fact a "BUG-FACT" :kind :borrow-ignore :digit d)))
             ;; bug: always-borrow (borrowed though not needed; value >= 10)
             ((and (>= top-ones bot-ones) (= d (+ 10 top-ones (- bot-ones))))
              (mtt:adapter-primed-intent
               a
               `((,(gi "GOAL") ,(gi "RES-ONES") ,d))
               (mtt:adapter-fact a "BUG-FACT" :kind :always-borrow :digit d)))
             ;; bug: off-by-one on a borrow column
             ((and (< top-ones bot-ones) (= 1 (abs (- d correct))))
              (mtt:adapter-primed-intent
               a
               `((,(gi "GOAL") ,(gi "RES-ONES") ,d))
               (mtt:adapter-fact a "BUG-FACT" :kind :off-by-one :digit d)))
             ;; unclassified: bare intent, no prime
             (t (mtt:make-step-intent
                 :assignments `((,(gi "GOAL") ,(gi "RES-ONES") ,d)))))))
        ((string= "TENS" (and stage (symbol-name stage)))
         (let ((correct (- top-tens bot-tens)))
           (cond
             ((= d correct)
              (mtt:adapter-primed-intent
               a
               `((,(gi "GOAL") ,(gi "RES-TENS") ,d)
                 (,(gi "GOAL") ,(gi "STAGE") ,(gi "DONE")))
               (mtt:adapter-fact a "COL-FACT" :kind (gi "DIRECT")
                                 :top top-tens :bot bot-tens :diff d)))
             ;; tens has NO bug detection (spec §2.1): unclassified
             (t (mtt:make-step-intent
                 :assignments `((,(gi "GOAL") ,(gi "RES-TENS") ,d)))))))
        (t
         (error "mtt/subtraction-adapter: unexpected goal stage ~a" stage))))))
