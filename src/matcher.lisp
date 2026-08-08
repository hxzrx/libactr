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
;;;;   * :? buffer  — state query (e.g. ?retrieval> buffer empty).  The state
;;;;                  keywords (BUFFER/STATE) and their values (EMPTY/FULL/
;;;;                  FAILURE/FREE/BUSY/ERROR) are evaluated against the
;;;;                  buffer's occupancy/module state, NOT against chunk slots:
;;;;                    buffer empty   -> match iff buffer chunk is nil
;;;;                    buffer full    -> match iff buffer chunk is non-nil
;;;;                    buffer failure -> never set in a static snapshot
;;;;                    state free     -> always true (module idle)
;;;;                    state busy     -> never true (no in-flight request)
;;;;                    state error    -> never true (no module error)
;;;;                  An empty query (no slot-tests) always succeeds.
;;;
;;;; Internal vs public failure signalling:
;;;;   Bindings are an alist that may legitimately be NIL (empty — no variables
;;;;   bound yet).  To keep "matched with empty bindings" distinguishable from
;;;;   "failed" DURING the match, the internal helpers (match-slot-test,
;;;;   match-pattern, %match-production*) return the keyword :mtt-match-fail on
;;;;   failure and the (possibly nil) alist otherwise.  match-production, the
;;;;   public boundary, collapses :mtt-match-fail back to nil — so by design a
;;;;   zero-variable match looks like nil through THAT entry point.  However
;;;;   matching-productions consumes %match-production* directly and filters on
;;;;   (eq b :mtt-match-fail), NOT truthiness, so a zero-variable match (e.g. a
;;;;   literal/ISA/negation-only LHS) IS kept there with its empty bindings.
;;;;   model-matching-productions delegates to matching-productions and
;;;;   therefore keeps such matches as well.
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

(defun match-buffer-state-query (slot-tests chunk)
  "Evaluate a :? buffer-state query's SLOT-TESTS against the buffer's current
   CHUNK (nil when empty).  State keywords test buffer occupancy or module
   state — never chunk slots — so this must be reachable even when CHUNK is
   nil (the whole point of 'buffer empty').  Returns T if every state query
   is satisfied, NIL otherwise.  See MATCHER top comment for the state table."
  (every (lambda (st) (state-query-satisfied-p st chunk))
         slot-tests))

(defun state-query-satisfied-p (st chunk)
  "True when the single state query in slot-test ST holds for CHUNK.
   Operates on symbol NAMES so it is package-agnostic — the query keywords
   may be interned in any package the model was read into."
  (let* ((slot-name (symbol-name (slot-test-slot st)))
         (operand   (slot-test-operand st))
         (val-name  (if (symbolp operand) (symbol-name operand)
                        (princ-to-string operand))))
    (cond
      ((string= slot-name "BUFFER")
       (cond
         ((string= val-name "EMPTY")  (null chunk))
         ((string= val-name "FULL")   (not (null chunk)))
         ;; FAILURE and any other buffer state: not tracked in a static
         ;; snapshot, so conservatively fail.
         (t nil)))
      ((string= slot-name "STATE")
       (cond
         ((string= val-name "FREE") t)
         ;; BUSY / ERROR and any other state: never in a static snapshot.
         (t nil)))
      (t nil))))            ; unknown state keyword: conservatively fail

(defun match-pattern (bp state bindings ct-table)
  "Match one buffer-pattern BP against STATE, threading BINDINGS.
   Returns the (possibly nil) bindings alist on success, or :mtt-match-fail."
  (let ((chunk (buffer-chunk state (buffer-pattern-buffer bp))))
    (cond
      ;; :? state queries evaluate buffer occupancy/module state, NOT chunk
      ;; slots.  Handle BEFORE the (null chunk) check: "buffer empty" must
      ;; match precisely when CHUNK IS nil.
      ((eq (buffer-pattern-modifier bp) :?)
       (if (match-buffer-state-query (buffer-pattern-slot-tests bp) chunk)
           bindings
           :mtt-match-fail))
      ((null chunk) :mtt-match-fail)
      ((not (isa-compatible-p (chunk-isa chunk)
                              (buffer-pattern-type-name bp)
                              ct-table))
       :mtt-match-fail)
      (t
       (loop :with b := bindings
             :for st :in (buffer-pattern-slot-tests bp)
             :while (not (eq (setf b (match-slot-test st chunk b ct-table))
                             :mtt-match-fail))
             :finally (return b))))))

(defun %match-production* (production state ct-table)
  "Internal: match PRODUCTION's LHS buffer-patterns against STATE, threading a
   single bindings alist across all patterns so a variable shared between
   patterns unifies.  Returns the (possibly nil/empty) bindings alist on
   success, or the keyword :mtt-match-fail on failure — keeping the two cases
   distinguishable for callers that must treat an empty-but-successful match
   (a zero-variable LHS) differently from no match.  CT-TABLE (from
   model-definition-chunk-types) enables ISA subtype matching.
   Pure: allocates a fresh alist per call; does not mutate PRODUCTION, STATE,
   or any global."
  (loop :with b := nil
        :for bp :in (production-lhs production)
        :while (not (eq (setf b (match-pattern bp state b ct-table))
                        :mtt-match-fail))
        :finally (return b)))

(defun match-production (production state &optional (ct-table nil))
  "Match PRODUCTION's LHS buffer-patterns against STATE, threading a single
   bindings alist across all patterns so a variable shared between patterns
   unifies.  Returns the final bindings alist on success, or NIL if any
   pattern or slot-test fails.  NOTE: a successful match that binds zero
   variables collapses to nil here and is thus indistinguishable from failure
   through THIS entry point — use matching-productions (or %match-production*)
   to observe zero-variable matches.  CT-TABLE (from model-definition-chunk-types)
   enables ISA subtype matching; pass nil to accept exact isa only."
  (let ((r (%match-production* production state ct-table)))
    (if (eq r :mtt-match-fail) nil r)))

(defun matching-productions (productions state &optional (ct-table nil))
  "Return a list of (production . bindings) for every production in PRODUCTIONS
   whose LHS matches STATE.  Order matches PRODUCTIONS.  Each bindings alist is
   freshly allocated per match.  Consumes %match-production* directly and
   filters on (eq b :mtt-match-fail) — NOT on truthiness of b — so a
   zero-variable match (a literal/ISA/negation-only LHS that succeeds while
   binding nothing) IS kept here with empty bindings, rather than being
   silently dropped as it would be through match-production."
  (loop :for p :in productions
        :for b := (%match-production* p state ct-table)
        :unless (eq b :mtt-match-fail) :collect (cons p b)))

(defun model-matching-productions (model-definition state)
  "Convenience wrapper: match the model's productions against STATE using the
   model's own chunk-types table for ISA subtype reasoning."
  (matching-productions (model-definition-productions model-definition)
                        state
                        (model-definition-chunk-types model-definition)))
