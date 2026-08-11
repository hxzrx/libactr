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
HTTP layer, e.g. ((type . start) (value . \"6\"))) into a step-intent the engine
can trace. May prime the session's retrieval buffer as a side-effect. Returns a
step-intent."))

(defgeneric step-done? (adapter trace-result session)
  (:documentation "Domain-specific termination predicate: did TRACE-RESULT just
complete the problem? Returns a boolean."))

(defclass domain-adapter ()
  ()
  (:documentation "Mixin/tag for domain adapters. Subclass this and implement
the three protocol generics (prepare-session, adapt-action, step-done?)."))
