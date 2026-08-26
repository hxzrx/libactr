;;;; src/authoring.lisp — pure authoring helpers over a compiled model-definition.
;;;; Phase 8: KC attribution (apply-kc-map). Future authoring utilities land here.
;;;; Phase 12: minimal bug-DSL core — bug-spec data / bug-answer-env / eval-bug-form.
;;;; NO global mutable state — pure transforms of their argument.
(in-package :mtt)

(defun apply-kc-map (model-definition kc-map)
  "Attribute production-kc on MODEL-DEFINITION's productions per KC-MAP.
KC-MAP is an alist (production-name (a symbol) . kc); each key is matched
against a production's name by SYMBOL-NAME (package-agnostic: the map is
authored in the tutor package, production names live in the model package).
Mutates MODEL-DEFINITION's productions in place (like compile-model) and
returns MODEL-DEFINITION. Productions absent from the map keep their existing
kc, so buggy rules that already carry their kc via make-production are
untouched when a loader applies the map before appending them."
  (dolist (p (model-definition-productions model-definition))
    (let ((kc (cdr (assoc (symbol-name (production-name p)) kc-map
                          :key #'symbol-name :test #'string=))))
      (when kc
        (setf (production-kc p) kc))))
  model-definition)

;;; ---------------------------------------------------------------------------
;;; Phase 12: minimal bug-DSL — ONE declaration -> THREE artifacts.
;;; A bug-spec is pure data authored in the tutor package (its symbols land in
;;; the model package by the same *PACKAGE* trick as the old hand-written bug
;;; flets). The pure functions below turn it into (a) the buggy production
;;; (bug-production, consumed by the tutor loader) and (b) the detection
;;; predicate (eval-bug-form / detect-bug, driven by the adapter's bug
;;; branch); the runtime prime+intent half (bug-goal-env / bug-intent) lives
;;; in src/adapter.lisp next to adapter-fact. Scope routing / correct
;;; branches / collision-ordering arguments stay in the adapter (phase 11
;;; §6.3 boundary); the LIST ORDER of specs IS the detection order.

(defstruct (bug-spec (:constructor make-bug-spec
                      (&key (name nil) (kind nil) (kc nil) (feedback nil)
                            (goal-type nil) (goal-guard nil)
                            (answers nil) (fact-slots nil) (when nil))))
  (name nil :type symbol)      ; production name (tutor/model package symbol)
  (kind nil :type symbol)      ; keyword discriminant in bug-fact's kind slot
  (kc nil :type symbol)        ; KC attribution (pedagogical judgment, declared)
  (feedback nil)
  (goal-type nil :type symbol) ; isa of the goal pattern
  (goal-guard nil :type list)  ; extra goal literal tests ((slot literal) ...)
  (answers nil :type list)     ; ((:action "value" :slot s :as n) ...)
  (fact-slots nil :type list)  ; ((name :from (:answer i)|(:goal s)) | (name :literal v) ...)
  (when nil))                  ; restricted detection S-expr (data)

(defun bug-answer-env (spec answers)
  "Alist ((:as-name . value) ...) pairing each answer entry of SPEC with the
corresponding element of ANSWERS (the parsed student values, in
spec-answers order). :as defaults to the entry's :slot name. detect-bug
prepends this to the goal env so student values shadow not-yet-written goal
slots."
  (loop :for entry :in (bug-spec-answers spec)
        :for v :in answers
        :collect (cons (or (getf entry :as) (getf entry :slot)) v)))

(defun bug-env-lookup (name env)
  "Look NAME up in ENV by SYMBOL-NAME (package-agnostic; apply-kc-map
precedent — :when names are read in the tutor package, env keys come from
the model package, which coincide but need not). Uses the assoc CELL so a
name legitimately bound to nil is distinct from an unbound name: unbound
signals an error (authoring typo); bound-to-nil is a legal value."
  (let ((cell (assoc name env :key #'symbol-name :test #'string=)))
    (if cell
        (cdr cell)
        (error "mtt: eval-bug-form: unbound name ~a in bug :when form" name))))

(defun eval-bug-form (form env &key (predicates nil))
  "Evaluate the restricted bug-detection S-expr FORM against ENV (alist of
name . value). Atoms: non-symbol atoms are themselves; symbols are env
lookups by symbol-name (unbound -> error). Compound (op . args):
  builtins — CLOSED numeric set: and (short-circuit) or (short-circuit)
    not = < <= > >= + - * abs (CL semantics, multi-arg where CL is);
  any other operator: looked up in PREDICATES (alist (name . function)
    supplied BY THE CALLER — no global registry), matched by symbol-name;
    arguments are evaluated first, then applied (unknown -> error).
Returns a generalized boolean."
  (labels ((ev (f)
             (cond
               ((symbolp f) (bug-env-lookup f env))
               ((consp f)
                (let ((op (first f)) (args (rest f)))
                  (case op
                    ((and) (loop :for a :in args :always (ev a)))
                    ((or)  (loop :for a :in args :thereis (ev a)))
                    ((not) (not (ev (first args))))
                    ((= < <= > >= + - * abs)
                     (apply op (mapcar #'ev args)))
                    (t
                     (let ((fn (cdr (assoc op predicates
                                           :key #'symbol-name :test #'string=))))
                       (unless fn
                         (error "mtt: eval-bug-form: unknown operator ~a in bug :when form"
                                op))
                       (apply fn (mapcar #'ev args)))))))
               (t f))))
    (ev form)))
