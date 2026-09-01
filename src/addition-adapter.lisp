;;;; src/addition-adapter.lisp — addition reference adapter (Phase 5, spec §6.2).
;;;; The engine/domain seam: maps student JSON actions -> step-intent and primes
;;;; retrieval, reusing the dogfooded mtt/addition-tutor model-build + dm priming.
;;;; Implements the 3-method mtt adapter protocol (prepare-session / adapt-action /
;;;; step-done?). Stateless: no global variables. Subclasses standard-domain-adapter
;;;; (Phase 8) for reusable intern / goal-slot / fact / primed-intent plumbing.
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
;;;; values FIVE/TWO/...) live in that package. The base adapter-intern (parameter-
;;;; ized on :model-package = :mtt/addition-tutor, set in the constructor) interns
;;;; every model symbol there so eq-correct buffer/slot lookup works (buffer-state
;;;; is an eq hash; a same-named symbol in another package would silently miss).
;;;; See examples/addition-tutor.lisp lines 36-49 for the package-binding rationale.
(defpackage :mtt/addition-adapter
  (:use :cl)
  (:nicknames :addition-adapter)
  (:export #:addition-adapter #:make-addition-adapter #:build-addition-model))
(in-package :mtt/addition-adapter)

(defclass addition-adapter (mtt:standard-domain-adapter) ()
  (:documentation "Reference addition domain adapter (Phase 5). Subclasses
standard-domain-adapter for reusable plumbing (Phase 8). Implements the adapter
protocol (prepare-session / adapt-action; step-done? inherited from the base) for
the tutorial addition model, reusing mtt/addition-tutor's model-load and dm
priming. Stateless (all state lives on the session passed into each method)."))

(defun make-addition-adapter ()
  "Construct a stateless addition-adapter instance. Configures the base with the
:mtt/addition-tutor model package and the TERMINATE-ADDITION terminal production."
  (make-instance 'addition-adapter
                 :model-package (find-package :mtt/addition-tutor)
                 :terminal-production "TERMINATE-ADDITION"))

(defun build-addition-model ()
  "Read+compile the tutorial addition model + the buggy library (reuses
mtt/addition-tutor:load-tutor-model). Returns a compiled model-definition
suitable for mtt/server:register-model. Model symbols land in
:mtt/addition-tutor per load-tutor-model's *PACKAGE* binding."
  (mtt/addition-tutor:load-tutor-model))

;;; --- domain helpers (plumbing comes from standard-domain-adapter) ---

(defun %num-word (digits)
  "Map a small digit string to its uppercase NUMBER word; pass through otherwise.
\"5\" -> \"FIVE\", \"2\" -> \"TWO\". Pure string->string map (no interning)."
  (let ((m '(("0" . "ZERO") ("1" . "ONE") ("2" . "TWO") ("3" . "THREE")
             ("4" . "FOUR") ("5" . "FIVE") ("6" . "SIX") ("7" . "SEVEN")
             ("8" . "EIGHT") ("9" . "NINE"))))
    (or (cdr (assoc digits m :test #'string=)) digits)))

(defun %parse-problem (problem-id pkg)
  "Parse a problem id like \"5+2\" -> two values: arg1 and arg2 as
model-package number symbols (e.g. FIVE TWO in PKG). Semantic constraint
(phase 12 debt #1): both addends are single digits 0-9 — the dm number chain
covers exactly 0-9, and \"12+3\" used to intern garbage symbols silently.
All failures signal bad-tutor-request (400 over HTTP)."
  (let* ((s (princ-to-string problem-id))
         (plus (position #\+ s))
         (a (and plus (plusp (length s)) (subseq s 0 plus)))
         (b (and plus (subseq s (1+ plus)))))
    (unless (and a b (= 1 (length a)) (= 1 (length b))
                 (digit-char-p (char a 0)) (digit-char-p (char b 0)))
      (mtt:signal-bad-request
       "mtt/addition-adapter: cannot parse problem-id ~a (addends must be single digits 0-9, \"N+M\")"
       problem-id))
    (values (intern (%num-word a) pkg) (intern (%num-word b) pkg))))

(defun %action-value (action a)
  "Read the \"value\" entry of ACTION (an alist with string keys, as decoded by
the HTTP layer) and intern it as a model-package uppercase symbol via the base
adapter-intern. B1 (phase 14): a missing value entry signals bad-tutor-request
(string-upcase of nil used to reach a TYPE-ERROR -> HTTP 500)."
  (let ((raw (cdr (assoc "value" action :test #'string=))))
    (unless raw
      (mtt:signal-bad-request
       "mtt/addition-adapter: action ~s is missing the \"value\" entry" action))
    (mtt:adapter-intern a (string-upcase raw))))

;;; --- adapter protocol ---

(defmethod mtt:prepare-session ((a addition-adapter) session problem-id)
  "Initialize SESSION's goal buffer from PROBLEM-ID. Overrides the model's
default initial-goal (which hardcodes arg1=five arg2=two) with the parsed
problem-specific addends, so the same compiled model serves any small addition
problem. Returns SESSION."
  (multiple-value-bind (arg1 arg2) (%parse-problem problem-id (mtt:adapter-model-package a))
    (mtt:adapter-set-goal a session "ADD" :arg1 arg1 :arg2 arg2 :sum nil))
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
  (flet ((gi (name) (mtt:adapter-intern a name)))
    (let ((type (cdr (assoc "type" action :test #'string=))))
      (cond
        ((string= type "start")
         ;; initialize-addition's LHS has no =retrieval> test; no priming needed.
         ;; RHS sets sum=arg1, count=zero.
         (mtt:make-step-intent
          :assignments `((,(gi "GOAL") ,(gi "SUM")   ,(mtt:adapter-goal-slot a session "ARG1"))
                         (,(gi "GOAL") ,(gi "COUNT") ,(gi "ZERO")))))
        ((string= type "next-total")
         ;; Student reports a new total -> TWO ordered steps, each with its own
         ;; retrieval prime (built from pre-step state; the sum step does not
         ;; touch COUNT, so the count prime stays valid). The server runs them in
         ;; order, installing each prime before that step. The FIRST (sum) step is
         ;; the visible, student-facing step.
         (let* ((val           (%action-value action a))
                (current-sum   (mtt:adapter-goal-slot a session "SUM"))
                (current-count (mtt:adapter-goal-slot a session "COUNT")))
           ;; B1 (phase 14): out-of-order guard — before "start" both slots
           ;; are nil and dm-next would prime number-facts with nil slots.
           (unless (and current-sum current-count)
             (mtt:signal-bad-request
              "mtt/addition-adapter: \"next-total\" submitted before the \"start\" action"))
           (let ((newcount (mtt/addition-tutor:dm-next
                            (mtt:session-model session) current-count)))
             (list
              ;; step 1 (visible): increment-sum. retrieval prime = number(current-sum).
              (mtt:adapter-primed-intent
               a
               `((,(gi "GOAL") ,(gi "SUM") ,val))
               (mtt:adapter-fact a "NUMBER" :number current-sum
                                 :next (mtt/addition-tutor:dm-next (mtt:session-model session) current-sum)))
              ;; step 2 (bookkeeping): increment-count. retrieval prime = number(current-count).
              (mtt:adapter-primed-intent
               a
               `((,(gi "GOAL") ,(gi "COUNT") ,newcount))
               (mtt:adapter-fact a "NUMBER" :number current-count :next newcount))))))
        ((string= type "submit")
         ;; terminate-addition: LHS needs count=arg2, sum=answer, retrieval
         ;; number=answer. Prime retrieval with the current sum (the answer),
         ;; bundled on the intent's PRIME slot (server installs it).
         (let* ((val (%action-value action a))
                (current-sum (mtt:adapter-goal-slot a session "SUM")))
           ;; B1 (phase 14): out-of-order guard — before "start" SUM is nil and
           ;; the number-fact prime would carry a nil :number slot.
           (unless current-sum
             (mtt:signal-bad-request
              "mtt/addition-adapter: \"submit\" submitted before the \"start\" action"))
           (mtt:adapter-primed-intent
            a
            `((,(gi "GOAL") ,(gi "COUNT") nil)
              (,(gi "GOAL") ,(gi "SUM")   ,val))
            (mtt:adapter-fact a "NUMBER" :number current-sum
                              :next (mtt/addition-tutor:dm-next (mtt:session-model session) current-sum)))))
        (t
         (mtt:signal-bad-request "mtt/addition-adapter: unknown action type ~a" type))))))
