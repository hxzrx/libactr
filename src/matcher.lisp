;;;; src/matcher.lisp — production matching engine (Task 5)
;;;
;;;; Runtime matching of compiled productions against a buffer-state.  Pure
;;;; functions only — no global mutable state — so the matcher is safe to call
;;;; concurrently for many sessions (multi-user foundation).
;;;
;;;; Adapted to the EXACT structures produced by Tasks 2 & 4:
;;;;   slot-test   — slot / kind(:literal|:variable|:negation) / operand
;;;;                 :literal  -> operand is the literal value to equal
;;;;                 :variable -> operand is the variable symbol (e.g. =num1)
;;;;                 :negation -> operand is (inner-kind . inner-val) where
;;;;                              inner-kind is :literal or :variable
;;;;   buffer-pattern — buffer / modifier(:= | :?) / type-name / slot-tests
;;;;   chunk         — isa / slots (alist: slot-symbol . value)
;;;;   buffer-state  — eq hash-table: buffer-name symbol -> chunk (or absent)
;;;;   chunk-type-def — name / slots / parent  (for ISA subtype walk)
;;;
;;;; Semantics:
;;;;   * :literal   — slot value EQUALS operand (nil matches nil).
;;;;   * :variable  — bind the variable symbol to the slot value; an existing
;;;;                  binding must agree (EQUAL) or the test fails (unification).
;;;;   * :negation  — slot value must NOT equal the inner value.  Inner literal
;;;;                  compares directly; inner variable compares against its
;;;;                  current binding, and an UNBOUND inner variable is
;;;;                  conservatively treated as non-matching (ACT-R requires
;;;;                  negated variables to be bound elsewhere first).
;;;;   * ISA        — chunk's isa EQUALS the pattern type-name, OR is a subtype
;;;;                  (walk chunk-type-def-parent chain in ct-table).  A nil
;;;;                  type-name means "no ISA test" and always passes.
;;;;   * :? buffer  — state query (e.g. ?retrieval> buffer empty).  This subset
;;;;                  models only buffer presence, so a :? pattern matches iff
;;;;                  the buffer is occupied and ISA-compatible; its slot-tests
;;;;                  (state keywords like BUFFER/STATE) are not chunk slots and
;;;;                  are ignored.
;;;
;;;; Internal vs public failure signalling:
;;;;   Bindings are an alist that may legitimately be NIL (empty — no variables
;;;;   bound yet).  To keep "matched with empty bindings" distinguishable from
;;;;   "failed" DURING the match, the internal helpers (match-slot-test,
;;;;   match-pattern) return the keyword :mtt-match-fail on failure and the
;;;;   (possibly nil) alist otherwise.  match-production, the public boundary,
;;;;   collapses :mtt-match-fail back to nil.  Consequence (documented): a
;;;;   production that matches while binding zero variables is reported as nil
;;;;   by match-production — i.e. treated as a non-match by the public API.
;;;;   Every fireable production in tutorial/unit1/addition.lisp binds at least
;;;;   one variable, so this does not arise in practice.
(in-package :mtt)

;; ------------------------------------------------------------------ helpers

(defun chunk-slot (chunk slot)
  "Value of SLOT inside CHUNK's slots alist, or nil if absent."
  (cdr (assoc slot (chunk-slots chunk))))

(defun isa-compatible-p (chunk-isa type-name ct-table)
  "True when CHUNK-ISA satisfies the pattern's ISA test (TYPE-NAME).
   Same type, or a subtype via the chunk-type-def-parent chain in CT-TABLE.
   A nil TYPE-NAME means no ISA test and always succeeds.  CT-TABLE may be nil
   (caller opted out of subtype reasoning): only exact isa equality is then
   accepted."
  (or (null type-name)
      (eq chunk-isa type-name)
      (when ct-table
        (loop :with ct := (gethash chunk-isa ct-table)
              :for parent := (and ct (chunk-type-def-parent ct))
              :while parent
              :thereis (eq parent type-name)
              :do (setf ct (gethash parent ct-table))))))

(defun bind (var value bindings)
  "Return a bindings alist with VAR -> VALUE added.  If VAR is already bound,
   the existing binding must agree (EQUAL) — returns the same alist in that
   case.  On disagreement returns the sentinel :conflict so callers can
   distinguish a failed unification from a freshly extended alist.  Never
   mutates the input alist."
  (let ((existing (assoc var bindings)))
    (cond ((null existing) (acons var value bindings))
          ((equal (cdr existing) value) bindings)
          (t :conflict))))

;; ------------------------------------------------------ single-slot matching

(defun match-slot-test (st chunk bindings ct-table)
  "Match one slot-test ST against CHUNK, threading BINDINGS.
   Returns the (possibly nil) bindings alist on success, or the keyword
   :mtt-match-fail on failure.  CT-TABLE is accepted for symmetry/future use
   (no slot-test kind currently needs it)."
  (declare (ignore ct-table))
  (let ((actual (chunk-slot chunk (slot-test-slot st))))
    (ecase (slot-test-kind st)
      (:literal
       (if (equal actual (slot-test-operand st))
           bindings
           :mtt-match-fail))
      (:variable
       (let ((res (bind (slot-test-operand st) actual bindings)))
         (if (eq res :conflict)
             :mtt-match-fail
             res)))
      (:negation
       (destructuring-bind (inner-kind . inner-val) (slot-test-operand st)
         (ecase inner-kind
           (:literal
            (if (not (equal actual inner-val))
                bindings
                :mtt-match-fail))
           (:variable
            ;; Negated variable must be bound elsewhere first; if it is not,
            ;; we cannot decide and conservatively fail.
            (let ((bv (assoc inner-val bindings)))
              (if (and bv (not (equal actual (cdr bv))))
                  bindings
                  :mtt-match-fail)))))))))

;; ------------------------------------------------------ pattern / production

(defun match-pattern (bp state bindings ct-table)
  "Match one buffer-pattern BP against STATE, threading BINDINGS.
   Returns the (possibly nil) bindings alist on success, or :mtt-match-fail."
  (let ((chunk (buffer-chunk state (buffer-pattern-buffer bp))))
    (cond
      ((null chunk) :mtt-match-fail)
      ((not (isa-compatible-p (chunk-isa chunk)
                              (buffer-pattern-type-name bp)
                              ct-table))
       :mtt-match-fail)
      ;; :? state queries (e.g. ?retrieval> buffer empty): this subset models
      ;; only buffer presence, so they pass once the buffer is occupied and
      ;; ISA-compatible; their state keywords are not chunk slots.
      ((eq (buffer-pattern-modifier bp) :?) bindings)
      (t
       (loop :with b := bindings
             :for st :in (buffer-pattern-slot-tests bp)
             :while (not (eq (setf b (match-slot-test st chunk b ct-table))
                             :mtt-match-fail))
             :finally (return b))))))

(defun match-production (production state &optional (ct-table nil))
  "Match PRODUCTION's LHS buffer-patterns against STATE, threading a single
   bindings alist across all patterns so a variable shared between patterns
   unifies.  Returns the final bindings alist on success, or NIL if any
   pattern or slot-test fails.  CT-TABLE (from model-definition-chunk-types)
   enables ISA subtype matching; pass nil to accept exact isa only.
   Pure: allocates a fresh alist per call; does not mutate PRODUCTION, STATE,
   or any global."
  (let ((result (loop :with b := nil
                      :for bp :in (production-lhs production)
                      :while (not (eq (setf b (match-pattern bp state b ct-table))
                                      :mtt-match-fail))
                      :finally (return b))))
    (if (eq result :mtt-match-fail) nil result)))

(defun matching-productions (productions state &optional (ct-table nil))
  "Return a list of (production . bindings) for every production in PRODUCTIONS
   whose LHS matches STATE.  Order matches PRODUCTIONS.  Each bindings alist is
   freshly allocated by match-production."
  (loop :for p :in productions
        :for b := (match-production p state ct-table)
        :when b :collect (cons p b)))

(defun model-matching-productions (model-definition state)
  "Convenience wrapper: match the model's productions against STATE using the
   model's own chunk-types table for ISA subtype reasoning."
  (matching-productions (model-definition-productions model-definition)
                        state
                        (model-definition-chunk-types model-definition)))
