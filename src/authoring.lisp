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
  "Pure-data declaration of ONE bug — the single source from which the three
artifacts derive: the buggy production (bug-production), the detection
predicate (eval-bug-form / detect-bug over :when), and the runtime
prime+intent (bug-goal-env / bug-intent in adapter.lisp). Authored in the
tutor package; generated symbols intern in the NAME's package (= the model
package). Validate with validate-bug-spec before wiring into a tutor."
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

(defun %fact-slot-name (fs) (first fs))
(defun %fact-slot-from (fs) (getf (rest fs) :from))
(defun %fact-slot-literal (fs) (getf (rest fs) :literal))

(defun bug-production (spec)
  "Build the buggy production from SPEC — the exact structural shape the four
domains' hand-written bug flets produced. ONE intentional deviation: a
:literal fact slot becomes a literal slot-test instead of the old dummy
variable (use-product's denom 0) — same acceptance set against the facts the
adapter primes. Goal pattern: :goal-guard literal tests + an automatic
(slot nil) test per answer slot. Retrieval pattern: isa BUG-FACT with the
KIND keyword literal + one VARIABLE test per :from fact slot, numbered =v1,
=v2, ... in fact-slots declaration order (skipping :literal slots). RHS:
one (slot . =vN) pair per answer, N = the variable of the fact slot sourcing
that answer. All GENERATED symbols (GOAL/RETRIEVAL/BUG-FACT/KIND/=vN) intern
in the package of the spec's NAME (= the model package): authoring.lisp's
own 'goal would be MTT::GOAL and silently never match a model-package
buffer."
  (let* ((name (bug-spec-name spec))
         (pkg (symbol-package name))
         (goal-buf (intern "GOAL" pkg))
         (retr-buf (intern "RETRIEVAL" pkg))
         (fact-isa (intern "BUG-FACT" pkg))
         (kind-slot (intern "KIND" pkg))
         (var-of (make-hash-table :test #'eq))
         (n 0))
    (dolist (fs (bug-spec-fact-slots spec))
      (when (%fact-slot-from fs)
        (incf n)
        (setf (gethash (%fact-slot-name fs) var-of)
              (intern (format nil "=V~d" n) pkg))))
    (flet ((answer-var (i)
             (loop :for fs :in (bug-spec-fact-slots spec)
                   :when (equal (%fact-slot-from fs) (list :answer i))
                     :return (gethash (%fact-slot-name fs) var-of))))
      (make-production
       name
       (list
        (make-buffer-pattern
         goal-buf := (bug-spec-goal-type spec)
         (append
          (loop :for (slot literal) :in (bug-spec-goal-guard spec)
                :collect (make-slot-test slot :literal literal))
          (loop :for entry :in (bug-spec-answers spec)
                :collect (make-slot-test (getf entry :slot) :literal nil))))
        (make-buffer-pattern
         retr-buf := fact-isa
         (cons (make-slot-test kind-slot :literal (bug-spec-kind spec))
               (loop :for fs :in (bug-spec-fact-slots spec)
                     :for nm := (%fact-slot-name fs)
                     :collect (if (%fact-slot-from fs)
                                  (make-slot-test nm :variable (gethash nm var-of))
                                  (make-slot-test nm :literal (%fact-slot-literal fs)))))))
       (list
        (make-action ':= goal-buf
                     (loop :for entry :in (bug-spec-answers spec)
                           :for i :from 0
                           :collect (cons (getf entry :slot) (answer-var i)))))
       (bug-spec-kc spec) :buggy (bug-spec-feedback spec)))))

(defun detect-bug (specs answers env &key (predicates nil))
  "First bug-spec in SPECS whose :when form evaluates true; nil when none
matches. SPECS list order IS the detection order (per-domain collision
analysis lives in that order — phase 11 §6.3). ANSWERS are the parsed student
values in spec-answers order; they are prepended to ENV (shadowing unwritten
goal slots). PREDICATES: the caller-supplied named-predicate alist for
non-builtin operators (zero global registry)."
  (loop :for spec :in specs
        :when (eval-bug-form (bug-spec-when spec)
                             (append (bug-answer-env spec answers) env)
                             :predicates predicates)
          :return spec))

;;; ---------------------------------------------------------------------------
;;; Phase 13: validate-bug-spec — the authoring validator (spec §6).
;;; Pure function over a bug-spec: collects ERRORS (authoring mistakes that
;;; would otherwise degrade silently — the phase-12 final-review backlog) and
;;; WARNINGS (conditions the constructor cannot fully decide). make-bug-spec
;;; itself is untouched; tutor loaders / adapter makers call this and signal
;;; on non-empty errors (Task 3). Never signals, never mutates.

(defun %builtin-op-p (op)
  "The closed builtin operator set of eval-bug-form (all CL symbols — :when
forms are read in a package that :use :cl, so the case in eval-bug-form and
this member agree on identity)."
  (and (symbolp op) (not (null op))
       (member op '(and or not = < <= > >= + - * abs))))

(defun %builtin-arity-errors (op args)
  "Arity violations for the closed builtin set (mirrors eval-bug-form
semantics: not/abs read exactly one arg; and/or take any; the rest apply over
>= 1)."
  (case op
    ((not abs)
     (unless (= 1 (length args))
       (list (format nil "operator ~(~a~) takes exactly 1 argument, got ~d"
                     op (length args)))))
    ((and or) nil)
    (t (unless (>= (length args) 1)
         (list (format nil "operator ~(~a~) needs at least 1 argument" op))))))

(defun %walk-when (form resolvable-p predicates)
  "Walk the restricted :when form (the same shape language eval-bug-form
reads): collect one error per unresolvable name, unknown operator, or builtin
arity violation."
  (cond
    ((symbolp form)
     (if (or (null form) (eq form t) (funcall resolvable-p form))
         nil
         (list (format nil
                       "unresolvable name ~(~a~) in :when (not an answer :as, fact-slot, goal-guard slot, or extra-env-name)"
                       form))))
    ((consp form)
     (let ((op (first form)) (args (rest form)))
       (append
        (unless (or (%builtin-op-p op)
                    (cdr (assoc op predicates :key #'symbol-name :test #'string=)))
          (list (format nil
                        "unknown operator ~(~a~) in :when (not builtin, not in :predicates)"
                        op)))
        (when (%builtin-op-p op) (%builtin-arity-errors op args))
        (loop :for a :in args :append (%walk-when a resolvable-p predicates)))))
    (t nil)))

(defun validate-bug-spec (spec &key (predicates nil) (extra-env-names nil))
  "Validate a bug-spec declaration, returning (values ERRORS WARNINGS) as
lists of human-readable strings. ERRORS catch what would otherwise degrade
silently: missing required fields (name/kind/kc/goal-type must be non-nil
symbols), malformed answer entries (:action string + :slot symbol), malformed fact-slot
entries ((name :from (:answer i)|(:goal s)) or (name :literal v)), a fact-slot
index out of range, an answer with no matching (:answer i) fact slot (the RHS
would silently get (slot . nil)), duplicate answer :slot or :as names (env
shadowing), malformed goal-guard entries, unresolvable names in :when, unknown
operators, and builtin arity violations. WARNINGS hold constructor-undecidable
notes (e.g. non-string feedback). PREDICATES is the caller's named-predicate
alist (the same one detect-bug receives); EXTRA-ENV-NAMES is the catch-all
for every :when name not derivable from the spec itself — adapter-added env
names (e.g. past-tense's regular-p / known-p) AND plain goal-slot names (the
validator has no chunk-type knowledge, so real specs' top-ones / bot-ones /
verb ... must be declared here). Robustness: malformed COLLECTIONS (a
:answers/:fact-slots/:goal-guard that is not a proper list), atom ENTRIES,
and the enumerated entry shapes degrade to collected errors; per-ENTRY
proper-list guards (phase 14 B2) extend the never-signal guarantee to
dotted/atom ENTRIES in :answers/:fact-slots/:goal-guard. Circular
(self-referential) structure is the honest exclusion — the CL reader cannot
produce one in a quoted literal without #n= syntax and validator input is
programmatic data. Pure: never mutates the spec."
  (let* ((answers (bug-spec-answers spec))
         (fact-slots (bug-spec-fact-slots spec))
         (goal-guard (bug-spec-goal-guard spec))
         (errors nil) (warnings nil))
    (flet ((err (fmt &rest args) (push (apply #'format nil fmt args) errors))
           (note (fmt &rest args) (push (apply #'format nil fmt args) warnings))
           (proper-list-p (x) (and (listp x) (null (cdr (last x))))))
      ;; 0. collection shape — a collection that is not a proper list
      ;;    degrades to a collected error + an empty LOCAL (the spec is never
      ;;    mutated). make-bug-spec's :type list lets improper lists through
      ;;    (any cons is a LIST), and a port without defstruct type checking
      ;;    would let atoms through too. Scope of the never-signal guarantee
      ;;    (phase 14 B2): malformed collections, atom entries, dotted
      ;;    entries, and the enumerated entry shapes below ALL degrade to
      ;;    collected errors (per-entry proper-list guards).
      (unless (proper-list-p answers)
        (err ":answers is not a proper list (~s) — treated as empty" answers)
        (setf answers nil))
      (unless (proper-list-p fact-slots)
        (err ":fact-slots is not a proper list (~s) — treated as empty" fact-slots)
        (setf fact-slots nil))
      (unless (proper-list-p goal-guard)
        (err ":goal-guard is not a proper list (~s) — treated as empty" goal-guard)
        (setf goal-guard nil))
      ;; 1. required fields (nil IS a symbol in CL and the defstruct default,
      ;;    so the check is non-nil-symbol, not bare symbolp)
      (unless (and (symbolp (bug-spec-name spec)) (bug-spec-name spec))
        (err "missing required field name"))
      (unless (and (symbolp (bug-spec-kind spec)) (bug-spec-kind spec))
        (err "missing required field kind"))
      (unless (and (symbolp (bug-spec-kc spec)) (bug-spec-kc spec))
        (err "missing required field kc"))
      (unless (and (symbolp (bug-spec-goal-type spec)) (bug-spec-goal-type spec))
        (err "missing required field goal-type"))
      ;; 2. answers shape + duplicate :slot / :as (a malformed ENTRY — atom
      ;;    or dotted — degrades to one collected error, no dup tracking)
      (let ((slots-seen nil) (as-seen nil))
        (dolist (entry answers)
          (if (not (proper-list-p entry))
              (err "malformed answer entry ~s (not a proper list)" entry)
              (progn
                (unless (and (stringp (getf entry :action))
                             (symbolp (getf entry :slot)))
                  (err "malformed answer entry ~s (need :action string + :slot symbol)"
                       entry))
                (let ((slot (getf entry :slot))
                      (as (or (getf entry :as) (getf entry :slot))))
                  (when (member slot slots-seen)
                    (err "duplicate answer :slot ~a" slot))
                  (when (member as as-seen)
                    (err "duplicate answer :as name ~a (env shadowing)" as))
                  (push slot slots-seen) (push as as-seen))))))
      ;; 3. fact-slots shape + index range (:literal presence via plist keys —
      ;;    getf cannot distinguish absent from nil-valued)
      (dolist (fs fact-slots)
        (if (not (and (proper-list-p fs) (symbolp (first fs))))
            (err "malformed fact-slot entry ~s (need a proper list (name ...))" fs)
            (let ((from (getf (rest fs) :from))
                  (literal-present-p (member :literal (rest fs))))
              (cond
                ((and from literal-present-p)
                 (err "fact-slot ~a has BOTH :from and :literal" (first fs)))
                (from
                 (unless (and (listp from)
                              (member (first from) '(:answer :goal))
                              (or (and (eq (first from) :answer) (integerp (second from)))
                                  (and (eq (first from) :goal) (symbolp (second from)))))
                   (err "malformed :from ~s on fact-slot ~a" from (first fs)))
                 (when (and (listp from) (eq (first from) :answer)
                            (integerp (second from)))
                   (unless (< -1 (second from) (length answers))
                     (err "fact-slot ~a references (:answer ~d) — out of range for ~d answers"
                          (first fs) (second from) (length answers)))))
                ((not literal-present-p)
                 (err "fact-slot ~a has neither :from nor :literal (degrades to literal nil at runtime)"
                      (first fs)))))))
      ;; 4. goal-guard shape
      (dolist (pair goal-guard)
        (unless (and (proper-list-p pair) (= 2 (length pair)) (symbolp (first pair)))
          (err "malformed goal-guard entry ~s (need a proper list (slot literal))" pair)))
      ;; 5. answer <-> fact-slot cross reference (the headline check)
      (loop :for i :from 0 :below (length answers)
            :unless (some (lambda (fs)
                            (and (proper-list-p fs)
                                 (equal (getf (rest fs) :from) (list :answer i))))
                          fact-slots)
              :do (err "answer ~d has no fact slot (:answer ~d) — RHS would silently get (slot . nil)"
                       i i))
      ;; 6. :when walk (names resolvable = answer :as + fact names + goal-guard
      ;;    slots + extra-env-names, matched by symbol-name like apply-kc-map).
      ;;    The mapcars guard entry shape: (first atom) / (getf atom ...) on
      ;;    a malformed entry would signal — the entry is already diagnosed
      ;;    by steps 2-4; here it just contributes no name.
      (let* ((as-names (mapcar (lambda (e) (and (proper-list-p e)
                                                (or (getf e :as) (getf e :slot))))
                               answers))
             (fact-names (mapcar (lambda (fs) (if (proper-list-p fs) (first fs) nil))
                                 fact-slots))
             (guard-names (mapcar (lambda (p) (if (proper-list-p p) (first p) nil))
                                  goal-guard))
             (resolvable (append as-names fact-names guard-names extra-env-names))
             (resolvable-p (lambda (n)
                             (and (symbolp n)
                                  (member n resolvable
                                          :key (lambda (x) (and (symbolp x) x))
                                          :test #'string=)
                                  t))))
        ;; push (not append) so the final nreverse keeps ALL errors in
        ;; emission order: append placed the walk list after the pushed
        ;; err messages and the nreverse then reversed the walk order
        (dolist (e (%walk-when (bug-spec-when spec) resolvable-p predicates))
          (push e errors)))
      ;; 7. warnings
      (when (and (bug-spec-feedback spec) (not (stringp (bug-spec-feedback spec))))
        (note "feedback is not a string"))
      (values (nreverse errors) (nreverse warnings)))))
