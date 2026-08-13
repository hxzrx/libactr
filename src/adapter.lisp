;;;; src/adapter.lisp — domain-adapter protocol (Phase 5 service layer)
;;;; The engine/domain seam (spec §6.2): only these three generics are
;;;; domain-specific. Translating a trace-result to JSON, registering models,
;;;; running sessions, etc. are all domain-agnostic (server.lisp, http-api).
;;;; Lives in the :mtt package because adapters reference these symbols and the
;;;; mtt core owns the cognitive-session / step-intent / trace-result types they
;;;; operate on. NO global mutable state in this file.
(in-package :mtt)

(defgeneric prepare-session (adapter session problem-id)
  (:documentation "Initialize SESSION's cognitive state from PROBLEM-ID (called at
session start, e.g. parse \"5+2\" into the goal buffer's arg1/arg2). Returns the
session (the adapter may mutate it in place)."))

(defgeneric adapt-action (adapter action session)
  (:documentation "Translate a decoded student ACTION (an alist shaped by the
HTTP layer, e.g. ((type . start) (value . \"6\"))) into a step-intent OR a list of
step-intents the engine can trace. May prime the session's retrieval buffer as a
side-effect (legacy) — prefer bundling per-step buffer installs on each intent's
PRIME slot (Phase 6 multi-step support). A single step-intent return is treated
as a one-element list. When multiple intents are returned, they are traced in
order; each intent's PRIME (buffer . chunk) pairs are installed before that step.
The FIRST step's trace-result is the response's primary result (student-facing)."))

(defgeneric step-done? (adapter trace-result session)
  (:documentation "Domain-specific termination predicate: did TRACE-RESULT just
complete the problem? Returns a boolean."))

(defclass domain-adapter ()
  ()
  (:documentation "Mixin/tag for domain adapters. Subclass this and implement
the three protocol generics (prepare-session, adapt-action, step-done?)."))

;;; ===========================================================================
;;; Phase 8: reusable adapter base — the default plumbing every adapter duplicates.
;;; Holds the two pieces of per-domain config (model symbol package, terminal
;;; production name) and factors out intern / goal-slot / fact-chunk / prime /
;;; intent construction + a default step-done?. NO global mutable state.

(defclass standard-domain-adapter (domain-adapter)
  ((model-package       :initarg :model-package       :reader adapter-model-package
                        :documentation "PACKAGE object where this domain's model
symbols live, e.g. (find-package :mtt/fraction-tutor). adapter-intern interns here.")
   (terminal-production :initarg :terminal-production :reader adapter-terminal-production
                        :documentation "Name (string) of the production whose on-path
fire marks the problem done, e.g. \"ADD-FRACTIONS\". Compared by symbol-name
(package-agnostic) by the default step-done? method."))
  (:documentation "Reusable base for domain adapters. Holds the two pieces of
per-domain config every adapter needs and inherits default plumbing helpers +
a default step-done?. A subclass sets :model-package and :terminal-production
and implements prepare-session (parse + adapter-set-goal) and adapt-action (the
domain brain, using the adapter-* helpers)."))

(declaim (inline adapter-intern))
(defun adapter-intern (adapter name)
  "Intern NAME (string designator) in ADAPTER's model-package. Replaces %frac/%at."
  (intern name (adapter-model-package adapter)))

(defun adapter-goal-slot (adapter session slot-name)
  "Read SLOT-NAME (string) from SESSION's goal buffer chunk; nil if absent/empty.
Replaces the per-adapter %goal-slot."
  (let ((chunk (buffer-chunk (session-state session) (adapter-intern adapter "GOAL"))))
    (when chunk
      (cdr (assoc (adapter-intern adapter slot-name) (chunk-slots chunk))))))

(defun adapter-fact (adapter isa-name &rest slot-plist)
  "Build a chunk isa=ISA-NAME (interned in model-package) with slots from
SLOT-PLIST (:slot val ...). Slot keys interned; values pass through. PURE: no
buffer mutation. Replaces %fact-chunk / %number-chunk construction — callers
compute any lookups (e.g. dm-next) and pass results in via the plist."
  (let (slots)
    (loop :for (k v) :on slot-plist :by #'cddr
          :do (push (cons (adapter-intern adapter (string k)) v) slots))
    (make-chunk :isa (adapter-intern adapter isa-name) :slots (nreverse slots))))

(defun adapter-set-goal (adapter session isa-name &rest slot-plist)
  "Write SESSION's goal buffer with a fresh chunk (isa=ISA-NAME, slots from
PLIST). Returns SESSION. The shared tail of prepare-session."
  (setf (buffer-chunk (session-state session) (adapter-intern adapter "GOAL"))
        (apply #'adapter-fact adapter isa-name slot-plist))
  session)

(defun adapter-prime-pair (adapter chunk)
  "The (RETRIEVAL . chunk) pair for a step-intent's PRIME slot. Replaces %prime-pair."
  (cons (adapter-intern adapter "RETRIEVAL") chunk))

(defun adapter-primed-intent (adapter assignments prime-chunk)
  "A step-intent with ASSIGNMENTS and a single retrieval prime of PRIME-CHUNK.
Replaces %intent. Multi-intent adapters build a list of these."
  (make-step-intent :assignments assignments
                    :prime (list (adapter-prime-pair adapter prime-chunk))))

(defmethod step-done? ((adapter standard-domain-adapter) trace-result session)
  "Default termination: an on-path step whose production name matches the
adapter's terminal-production (by symbol-name). Replaces the per-adapter
step-done? methods."
  (declare (ignore session))
  (and (eq :on-path (trace-result-status trace-result))
       (let ((p (trace-result-production trace-result)))
         (and p (string= (adapter-terminal-production adapter)
                         (symbol-name (production-name p)))))))
