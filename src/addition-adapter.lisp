;;;; src/addition-adapter.lisp — addition reference adapter (Phase 5, spec §6.2)
;;;; The engine/domain seam: maps student JSON actions -> step-intent and primes
;;;; retrieval, reusing the dogfooded mtt/addition-tutor model-build + dm priming.
;;;; Implements the 3-method mtt adapter protocol (prepare-session / adapt-action /
;;;; step-done?). Stateless: no global variables.
;;;;
;;;; TWO-STEP-PER-ACTION (the crux): the addition model requires, for each student
;;;; next-total, TWO trace steps — (a) increment-sum (the student's visible new
;;;; total), and (b) increment-count (the model's hidden bookkeeping so the goal's
;;;; count reaches arg2 and terminate-addition can fire on submit). Phase 6
;;;; multi-step support: adapt-action returns a 2-element list of primed intents
;;;; (sum first, count second); the server's server-step-session runs each in
;;;; order, installing each intent's PRIME (RETRIEVAL . number-chunk) before that
;;;; step, and returns the FIRST step's trace-result (= increment-sum, the
;;;; student-facing visible step). Both steps are logged and feed mastery. The
;;;; MANDATORY ordering (sum before count — increment-sum's LHS guards
;;;; -arg2=count, which fails once count reaches arg2) is preserved by list
;;;; order. Mirrors examples/addition-tutor.lisp tutor-step :next-total +
;;;; advance-count! exactly (prime-sum -> step-sum -> prime-count -> step-count),
;;;; now unified server-side instead of split across adapt-action/server.
;;;;
;;;; PACKAGE NOTE: load-tutor-model reads the addition model with *PACKAGE* bound
;;;; to :mtt/addition-tutor, so ALL model symbols (GOAL, ADD, SUM, COUNT, number
;;;; values FIVE/TWO/...) live in that package. This adapter references them via
;;;; %AT (intern into "MTT/ADDITION-TUTOR") so eq-correct buffer/slot lookup works
;;;; (buffer-state is an eq hash; a same-named symbol in THIS package would
;;;; silently miss). See examples/addition-tutor.lisp lines 36-49 for the
;;;; package-binding rationale.
(defpackage :mtt/addition-adapter
  (:use :cl)
  (:nicknames :addition-adapter)
  (:export #:addition-adapter #:make-addition-adapter #:build-addition-model))
(in-package :mtt/addition-adapter)

(defclass addition-adapter (mtt:domain-adapter) ()
  (:documentation "Reference addition domain adapter. Implements the 3-method
adapter protocol (prepare-session / adapt-action / step-done?) for the tutorial
addition model, reusing mtt/addition-tutor's model-load and dm priming. Stateless
(all state lives on the session passed into each method)."))

(defun make-addition-adapter ()
  "Construct a stateless addition-adapter instance."
  (make-instance 'addition-adapter))

(defun build-addition-model ()
  "Read+compile the tutorial addition model + the buggy library (reuses
mtt/addition-tutor:load-tutor-model). Returns a compiled model-definition
suitable for mtt/server:register-model. Model symbols land in
:mtt/addition-tutor per load-tutor-model's *PACKAGE* binding."
  (mtt/addition-tutor:load-tutor-model))

;;; --- helpers ---

(declaim (inline %at))
(defun %at (name)
  "Intern NAME (a string designator) in :mtt/addition-tutor, the package where
load-tutor-model interns all model symbols (GOAL, ADD, SUM, FIVE, ...). Use this
for every model data symbol so eq-hash buffer/slot lookups match the model."
  (intern name "MTT/ADDITION-TUTOR"))

(defun %num-word (digits)
  "Map a small digit string to its uppercase NUMBER word; pass through otherwise.
\"5\" -> \"FIVE\", \"2\" -> \"TWO\"."
  (let ((m '(("0" . "ZERO") ("1" . "ONE") ("2" . "TWO") ("3" . "THREE")
             ("4" . "FOUR") ("5" . "FIVE") ("6" . "SIX") ("7" . "SEVEN")
             ("8" . "EIGHT") ("9" . "NINE"))))
    (or (cdr (assoc digits m :test #'string=)) digits)))

(defun %parse-problem (problem-id)
  "Parse a problem id like \"5+2\" -> two values: arg1 and arg2 as model-package
number symbols (e.g. FIVE TWO). Returns values suitable for the goal buffer's
arg1/arg2 slots."
  (let* ((s (princ-to-string problem-id))
         (plus (position #\+ s)))
    (unless plus
      (error "mtt/addition-adapter: cannot parse problem-id ~a (expected \"N+M\")"
             problem-id))
    (values (%at (%num-word (subseq s 0 plus)))
            (%at (%num-word (subseq s (1+ plus)))))))

(defun %goal-slot (session slot-name)
  "Read SLOT-NAME (string) from SESSION's goal buffer chunk. Returns the model-
package symbol stored in that slot (or nil)."
  (mtt/addition-tutor:chunk-slot-val
   (mtt:buffer-chunk (mtt:session-state session) (%at "GOAL"))
   (%at slot-name)))

(defun %number-chunk (session value)
  "Build the NUMBER chunk for retrieval priming: isa NUMBER, NUMBER=value,
NEXT=dm-next(value). Pure (does not touch buffer-state). VALUE is a model-package
symbol read from the goal buffer."
  (let ((next (mtt/addition-tutor:dm-next (mtt:session-model session) value)))
    (mtt:make-chunk :isa (%at "NUMBER")
                    :slots `((,(%at "NUMBER") . ,value)
                             (,(%at "NEXT") . ,next)))))

(defun %prime-pair (session value)
  "Build the (RETRIEVAL . number-chunk) pair to put on a step-intent's PRIME slot."
  (cons (%at "RETRIEVAL") (%number-chunk session value)))

(defun %action-value (action)
  "Read the \"value\" entry of ACTION (an alist with string keys, as decoded by
the HTTP layer) and intern it as a model-package uppercase symbol."
  (%at (string-upcase (cdr (assoc "value" action :test #'string=)))))

;;; --- adapter protocol ---

(defmethod mtt:prepare-session ((a addition-adapter) session problem-id)
  "Initialize SESSION's goal buffer from PROBLEM-ID. Overrides the model's
default initial-goal (which hardcodes arg1=five arg2=two) with the parsed
problem-specific addends, so the same compiled model serves any small addition
problem. Returns SESSION."
  (declare (ignore a))
  (multiple-value-bind (arg1 arg2) (%parse-problem problem-id)
    (setf (mtt:buffer-chunk (mtt:session-state session) (%at "GOAL"))
          (mtt:make-chunk :isa (%at "ADD")
                          :slots `((,(%at "ARG1") . ,arg1)
                                   (,(%at "ARG2") . ,arg2)
                                   (,(%at "SUM")   . nil)))))
  session)

(defmethod mtt:adapt-action ((a addition-adapter) action session)
  "Translate a decoded student ACTION alist into a step-intent (or list of
intents) the engine can trace, with retrieval priming bundled on each intent's
PRIME slot (Phase 6 multi-step). Action types:
  :start       -> initialize-addition (sum=arg1, count=zero); single intent, no
                  prime (initialize-addition's LHS has no retrieval test).
  :next-total  -> increment-sum + increment-count as a 2-element primed intent
                  list (see TWO-STEP note in the file header: sum-intent first,
                  count-intent second; the server runs both and returns the
                  FIRST = increment-sum, the visible student step).
  :submit      -> terminate-addition (retrieval primed with the current sum,
                  bundled on the intent's PRIME slot)."
  (declare (ignore a))
  (let ((type (cdr (assoc "type" action :test #'string=))))
    (cond
      ((string= type "start")
       ;; initialize-addition's LHS has no =retrieval> test; no priming needed.
       ;; RHS sets sum=arg1, count=zero.
       (mtt:make-step-intent
        :assignments `((,(%at "GOAL") ,(%at "SUM")   ,(%goal-slot session "ARG1"))
                       (,(%at "GOAL") ,(%at "COUNT") ,(%at "ZERO")))))
      ((string= type "next-total")
       ;; Student reports a new total -> TWO ordered steps, each with its own
       ;; retrieval prime (built from pre-step state; the sum step does not
       ;; touch COUNT, so the count prime stays valid). The server runs them in
       ;; order, installing each prime before that step. The FIRST (sum) step is
       ;; the visible, student-facing step.
       (let* ((val           (%action-value action))
              (current-sum   (%goal-slot session "SUM"))
              (current-count (%goal-slot session "COUNT"))
              (newcount      (mtt/addition-tutor:dm-next
                              (mtt:session-model session) current-count)))
         (list
          ;; step 1 (visible): increment-sum. retrieval prime = number(current-sum).
          (mtt:make-step-intent
           :assignments `((,(%at "GOAL") ,(%at "SUM") ,val))
           :prime (list (%prime-pair session current-sum)))
          ;; step 2 (bookkeeping): increment-count. retrieval prime = number(current-count).
          (mtt:make-step-intent
           :assignments `((,(%at "GOAL") ,(%at "COUNT") ,newcount))
           :prime (list (%prime-pair session current-count))))))
      ((string= type "submit")
       ;; terminate-addition: LHS needs count=arg2, sum=answer, retrieval
       ;; number=answer. Prime retrieval with the current sum (the answer),
       ;; bundled on the intent's PRIME slot (server installs it).
       (let ((val (%action-value action)))
         (mtt:make-step-intent
          :assignments `((,(%at "GOAL") ,(%at "COUNT") nil)
                         (,(%at "GOAL") ,(%at "SUM")   ,val))
          :prime (list (%prime-pair session (%goal-slot session "SUM"))))))
      (t
       (error "mtt/addition-adapter: unknown action type ~a" type)))))

(defmethod mtt:step-done? ((a addition-adapter) trace-result session)
  "True when TRACE-RESULT's production is terminate-addition (the model's
termination production — fires when count reaches arg2 and the student submits
the final sum)."
  (declare (ignore a session))
  (let ((p (mtt:trace-result-production trace-result)))
    (and p (eq (mtt:production-name p) (%at "TERMINATE-ADDITION")))))
