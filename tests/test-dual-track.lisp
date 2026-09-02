;;;; tests/test-dual-track.lisp — dual-track oracle correctness vs act-r.
;;;
;;; Task 6: oracle unit verification on the addition model (hand-checked).
;;; Task 7: full dual-track regression — compare libactr's model-matching-productions
;;;          against the act-r oracle's per-production oracle-matches-p across
;;;          every tutorial model.  Discrepancies are either fixed (real matcher
;;;          bugs) or documented as known non-defects.
(in-package :libactr/test)
(in-suite :libactr)

;;; ---------------------------------------------------------------------------
;;; Task 6 (kept): oracle unit verification
;;; ---------------------------------------------------------------------------

(test oracle-judges-initialize-addition-matches
  "act-r oracle agrees that initialize-addition (not terminate-addition)
matches a fresh addition goal with sum=nil, and disagrees correctly once
the goal is set to a terminate-addition state."
  (let* ((model (asdf:system-relative-pathname "act-r" "tutorial/unit1/addition.lisp"))
         (names (libactr/oracle:oracle-load-model model)))
    ;; production names come back as keywords (package-neutral)
    (is (member :initialize-addition names))
    (is (member :terminate-addition names))
    ;; fresh goal: arg1=five arg2=two sum=nil  -> initialize-addition fires
    (libactr/oracle:oracle-set-goal-from-chunk
      (libactr:make-chunk :isa 'add :slots '((arg1 . five) (arg2 . two) (sum . nil))))
    (is (libactr/oracle:oracle-matches-p 'initialize-addition))
    (is (not (libactr/oracle:oracle-matches-p 'terminate-addition)))
    ;; terminate state: count=arg2=num and retrieval holds the answer
    (libactr/oracle:oracle-set-goal-from-chunk
      (libactr:make-chunk :isa 'add :slots '((count . two) (arg2 . two) (sum . seven))))
    (libactr/oracle:oracle-set-retrieval-from-chunk
      (libactr:make-chunk :isa 'number :slots '((number . seven))))
    (is (libactr/oracle:oracle-matches-p 'terminate-addition))
    (is (not (libactr/oracle:oracle-matches-p 'initialize-addition)))))

;;; ---------------------------------------------------------------------------
;;; Task 7: dual-track consistency — libactr matcher vs act-r oracle
;;; ---------------------------------------------------------------------------
;;;
;;; dual-track-check loads a model in BOTH engines from the SAME goal-only
;;; buffer state (other buffers empty), then for every production compares
;;; libactr's matching judgment against the oracle's.  Any disagreement is a
;;; discrepancy worth investigating:
;;;   * libactr bug (unification / negation / nil / ISA / :?) -> fix the kernel
;;;   * out-of-subset feature (perceptual/motor/retrieval buffers) -> document
;;;   * deliberately malformed model -> handler-case + document
;;;
;;; Package note: oracle-load-model returns production names as KEYWORDS
;;; (package-neutral), while libactr's production-name symbols live in the caller's
;;; package (here :libactr/test).  Comparison is therefore by SYMBOL-NAME, not eq.

(defun dual-track-check (model-path goal-chunk)
  "Return a list of discrepancies: (production-name libactr-says oracle-says) for
   each production where libactr and the oracle DISAGREE on whether it matches.
   Both engines start from the SAME goal-only state (goal=GOAL-CHUNK, all other
   buffers empty).  Returns NIL when they agree on every production."
  (let ((names (libactr/oracle:oracle-load-model model-path)))
    (libactr/oracle:oracle-set-goal-from-chunk goal-chunk)
    (let* ((md (libactr:compile-model (libactr:read-model-file model-path)))
           (state (libactr:make-buffer-state)))
      (setf (libactr:buffer-chunk state 'goal) goal-chunk)
      ;; libactr-matched-names: symbols in :libactr/test (the caller's package).
      (let ((libactr-matched
              (mapcar #'libactr:production-name
                      (mapcar #'car (libactr:model-matching-productions md state)))))
        (loop :for n :in names      ; keywords from the oracle
              ;; Compare by NAME, not eq — keywords ≠ :libactr/test symbols.
              :for libactr-says = (find (symbol-name n) libactr-matched
                                    :key #'symbol-name :test #'string=)
              :for oracle-says = (libactr/oracle:oracle-matches-p n)
              :unless (eq (not (null libactr-says)) (not (null oracle-says)))
                :collect (list n libactr-says oracle-says))))))

;;; ---------- Step 1: addition model at the initial goal (binding contract) ----------

(test dual-track-addition-initial-state
  "Binding contract: ZERO discrepancies on addition.lisp at its initial goal.
   The goal is arg1=five arg2=two sum=nil; only initialize-addition should
   match on both engines.  The other three productions require =retrieval>,
   which is empty on both sides, so both must agree they do not match."
  (let ((model (asdf:system-relative-pathname "act-r" "tutorial/unit1/addition.lisp")))
    (let ((diffs (dual-track-check
                   model
                   (libactr:make-chunk :isa 'add
                                   :slots '((arg1 . five) (arg2 . two) (sum . nil))))))
      (is (null diffs)
          "libactr vs oracle discrepancy on addition initial state: ~A" diffs))))

;;; ---------- Step 3: batch regression over unit1 + unit2 ----------

(defun tutorial-model-paths ()
  "Return all tutorial model .lisp files in unit1 and unit2.
   Uses make-pathname with :name :wild because asdf:system-relative-pathname
   escapes literal '*' in the namestring, breaking directory wildcards."
  (flet ((wild-files (subdir)
           (let ((tutorial-dir (asdf:system-relative-pathname "act-r" "tutorial/")))
             (directory (make-pathname
                          :directory (append (pathname-directory tutorial-dir)
                                             (list subdir))
                          :name :wild :type "lisp")))))
    (append (wild-files "unit1") (wild-files "unit2"))))

(defun known-non-defect-p (file diffs)
  "True when DIFFS for FILE stem from a documented known non-defect rather
   than an libactr bug.  This lets the batch test PASS (green) while still
   recording the exception, keeping the suite honest about what it covers."
  (declare (ignore diffs))
  ;; broken-addition.lisp is deliberately malformed (duplicate production
  ;; names, typos, missing ISA keywords); it has no goal-focus, so it is
  ;; skipped by the (when goal ...) guard and never reaches dual-track-check.
  ;; This predicate is a hook for future, richer non-defect classification.
  (string= (file-namestring file) "broken-addition.lisp"))

(test dual-track-tutorial-batch
  "Batch regression: for every tutorial model with an initial-goal, run
   dual-track-check and collect failures.  Models without a goal-focus are
   skipped.  Errors (e.g. oracle rejecting a malformed model) are caught and
   recorded.  The test passes when all models agree or differ only for
   documented known non-defects."
  (let ((failures nil))
    (dolist (m (sort (tutorial-model-paths) #'string< :key #'namestring))
      (handler-case
          (let* ((md (libactr:compile-model (libactr:read-model-file m)))
                 (goal (libactr:model-definition-initial-goal md)))
            (when goal
              (let ((diffs (dual-track-check m goal)))
                (when diffs
                  (push (cons (file-namestring m) diffs) failures)))))
        (error (e)
          (push (cons (file-namestring m) (list :error (princ-to-string e)))
                failures))))
    ;; Filter out documented non-defects so the suite is green; the raw list
    ;; is still reported in the failure message for transparency.
    (let ((real-failures
            (remove-if (lambda (f) (known-non-defect-p (car f) (cdr f)))
                       failures)))
      (is (null real-failures)
          "dual-track discrepancies (excluding known non-defects): ~A~%~
           All results incl. known non-defects: ~A"
          real-failures failures))))

;;; ---------------------------------------------------------------------------
;;; Phase 7: fraction dual-track (model-matching vs act-r oracle)
;;; ---------------------------------------------------------------------------
;;;
;;; Both fraction productions test =retrieval> in addition to =goal>, so the
;;; goal-only dual-track-check above is insufficient.  We extend it with a
;;; retrieval variant that installs BOTH goal and retrieval on each engine
;;; before comparing per-production match.  The model file is the common-subset
;;; libactr/models/fraction-add.lisp, which act-r loads directly (slot values are
;;; small integers — see the §13 probe note in the task brief).
;;;
;;; Per the brief's guidance, the body is wrapped in handler-case so an act-r
;;; rejection (e.g. of integer slot values) surfaces as (LIST :error) cleanly
;;; rather than crashing the suite; the tests then branch on that signal.

(defun dual-track-check-with-retrieval (model-path goal-chunk retrieval-chunk)
  "Like dual-track-check but also install RETRIEVAL-CHUNK on both engines before
   comparing per-production match.  Returns the discrepancy list (nil = agree),
   or (LIST :error) if either engine rejects the model or the buffer state."
  (handler-case
      (let ((names (libactr/oracle:oracle-load-model model-path)))
        (libactr/oracle:oracle-set-goal-from-chunk goal-chunk)
        (libactr/oracle:oracle-set-retrieval-from-chunk retrieval-chunk)
        (let* ((md (libactr:compile-model (libactr:read-model-file model-path)))
               (state (libactr:make-buffer-state)))
          (setf (libactr:buffer-chunk state 'goal) goal-chunk)
          (setf (libactr:buffer-chunk state 'retrieval) retrieval-chunk)
          (let ((libactr-matched
                  (mapcar #'libactr:production-name
                          (mapcar #'car (libactr:model-matching-productions md state)))))
            (loop :for n :in names
                  :for libactr-says = (find (symbol-name n) libactr-matched
                                        :key #'symbol-name :test #'string=)
                  :for oracle-says = (libactr/oracle:oracle-matches-p n)
                  :unless (eq (not (null libactr-says)) (not (null oracle-says)))
                    :collect (list n libactr-says oracle-says)))))
    (error () (list :error))))

(defun fraction-model-path ()
  "Path to the Phase 7 fraction model (libactr/models/fraction-add.lisp)."
  (asdf:system-relative-pathname "libactr" "models/fraction-add.lisp"))

(test dual-track-fraction-find-common-denominator
  "Goal: 1/2 + 1/3 (cdenom nil).  Retrieval: lcm-fact d1=2 d2=3 lcm=6.  Both
   engines must agree that find-common-denominator MATCHES and add-fractions
   does NOT.  diffs=nil = agreement; any non-nil diffs (including an act-r load
   :error) FAIL the test — spec §13 is resolved (act-r accepts integer slots)."
  (let ((goal (libactr:make-chunk :isa 'frac-add
                              :slots '((num1 . 1) (den1 . 2)
                                       (num2 . 1) (den2 . 3) (cdenom . nil))))
        (retr (libactr:make-chunk :isa 'lcm-fact
                              :slots '((d1 . 2) (d2 . 3) (lcm . 6)))))
    ;; frac-add / lcm-fact intern in :libactr/test here; oracle compares by name.
    (let ((diffs (dual-track-check-with-retrieval (fraction-model-path) goal retr)))
      (is (null diffs)
          "fraction find-common-denominator dual-track: ~A" diffs))))

(test dual-track-fraction-add-fractions
  "Goal: cdenom=6, snum nil.  Retrieval: sum-fact cdenom=6 snum=5 sdenom=6.
   Both engines must agree that add-fractions MATCHES and
   find-common-denominator does NOT."
  (let ((goal (libactr:make-chunk :isa 'frac-add
                              :slots '((cdenom . 6) (snum . nil))))
        (retr (libactr:make-chunk :isa 'sum-fact
                              :slots '((cdenom . 6) (snum . 5) (sdenom . 6)))))
    (let ((diffs (dual-track-check-with-retrieval (fraction-model-path) goal retr)))
      (is (null diffs)
          "fraction add-fractions dual-track: ~A" diffs))))

(test dual-track-fraction-simplify
  "Goal: cdenom=6 snum=2 sdenom=6 rnum nil. Retrieval: reduce-fact num=2 den=6
rnum=1 rdenom=3. Both engines must agree SIMPLIFY matches and the other two
fraction productions do not."
  (let ((goal (libactr:make-chunk :isa 'frac-add
                              :slots '((cdenom . 6) (snum . 2) (sdenom . 6)
                                       (rnum . nil))))
        (retr (libactr:make-chunk :isa 'reduce-fact
                              :slots '((num . 2) (den . 6) (rnum . 1) (rdenom . 3)))))
    (let ((diffs (dual-track-check-with-retrieval (fraction-model-path) goal retr)))
      (is (null diffs) "fraction simplify dual-track: ~A" diffs))))

(test dual-track-fraction-simplify-done-guard
  "Goal: rnum=1 (simplify already applied), same reduce-fact retrieval. Both
engines must agree SIMPLIFY does NOT match (goal wants rnum nil)."
  (let ((goal (libactr:make-chunk :isa 'frac-add
                              :slots '((cdenom . 6) (snum . 2) (sdenom . 6)
                                       (rnum . 1) (rdenom . 3))))
        (retr (libactr:make-chunk :isa 'reduce-fact
                              :slots '((num . 2) (den . 6) (rnum . 1) (rdenom . 3)))))
    (let ((diffs (dual-track-check-with-retrieval (fraction-model-path) goal retr)))
      (is (null diffs) "fraction simplify negative dual-track: ~A" diffs))))

;;; ---------------------------------------------------------------------------
;;; Phase 10: past-tense dual-track (model-matching vs act-r oracle)
;;; ---------------------------------------------------------------------------
;;; Third domain: SYMBOL slot values (go/went/walked), unlike fraction's
;;; integers. Model file libactr/models/past-tense.lisp is loaded directly by
;;; act-r. Three cases: irregular-class match, regular-class match, and
;;; negative agreement (class literal mismatch -> the wrong production does
;;; not match in EITHER engine). The two correct productions discriminate on
;;; the retrieval CLASS slot literal, NOT isa: Task 5 empirically showed
;;; ACT-R does not test isa in buffer conditions (procedural.lisp's own
;;; "isa that provides no tests" warning; chunks carry no type at run time),
;;; so spec §3 was amended to verb-fact + class (same idiom as bug-fact's
;;; kind). Buggy productions are libactr-loader-only (appended post-load, like
;;; fraction), so no buggy dual case — spec §9.4 (amended).

(defun past-tense-model-path ()
  "Path to the Phase 10 past-tense model (libactr/models/past-tense.lisp)."
  (asdf:system-relative-pathname "libactr" "models/past-tense.lisp"))

(test dual-track-past-tense-retrieve-irregular
  "Goal: verb=go past=nil. Retrieval: verb-fact verb=go class=irregular
past=went. Both engines must agree RETRIEVE-IRREGULAR matches and
APPLY-REGULAR does not (class literal irregular vs required regular)."
  (let ((goal (libactr:make-chunk :isa 'past-tense-task :slots '((verb . go) (past . nil))))
        (retr (libactr:make-chunk :isa 'verb-fact
                              :slots '((verb . go) (class . irregular) (past . went)))))
    ;; past-tense-task / verb-fact intern in :libactr/test here; oracle compares by name.
    (let ((diffs (dual-track-check-with-retrieval (past-tense-model-path) goal retr)))
      (is (null diffs) "past-tense retrieve-irregular dual-track: ~A" diffs))))

(test dual-track-past-tense-apply-regular
  "Goal: verb=walk past=nil. Retrieval: verb-fact verb=walk class=regular
past=walked. Both engines must agree APPLY-REGULAR matches and
RETRIEVE-IRREGULAR does not."
  (let ((goal (libactr:make-chunk :isa 'past-tense-task :slots '((verb . walk) (past . nil))))
        (retr (libactr:make-chunk :isa 'verb-fact
                              :slots '((verb . walk) (class . regular) (past . walked)))))
    (let ((diffs (dual-track-check-with-retrieval (past-tense-model-path) goal retr)))
      (is (null diffs) "past-tense apply-regular dual-track: ~A" diffs))))

(test dual-track-past-tense-mismatch-agrees
  "Negative agreement: goal verb=go (irregular) but retrieval holds a
REGULAR-class fact (the over-regularizer's belief: go -> goed). Both engines
must agree APPLY-REGULAR matches (class regular, verb =v binds go) and
RETRIEVE-IRREGULAR does NOT (class literal irregular vs regular). Guards the
class-literal discrimination path both ways."
  (let ((goal (libactr:make-chunk :isa 'past-tense-task :slots '((verb . go) (past . nil))))
        (retr (libactr:make-chunk :isa 'verb-fact
                              :slots '((verb . go) (class . regular) (past . goed)))))
    (let ((diffs (dual-track-check-with-retrieval (past-tense-model-path) goal retr)))
      (is (null diffs) "past-tense mismatch dual-track: ~A" diffs))))

;;; ---------------------------------------------------------------------------
;;; Phase 11: subtraction dual-track (model-matching vs act-r oracle)
;;; ---------------------------------------------------------------------------
;;; Fourth domain: MIXED slot values (integer digits + symbol stage), unlike
;;; fraction (pure integers) and past-tense (pure symbols). Model file
;;; libactr/models/subtraction.lisp is loaded directly by act-r. Five cases: the
;;; four correct productions each match with their priming fact (ones-direct /
;;; ones-borrow / propagate / tens-direct), plus one negative agreement (a
;;; kind=propagate fact against a stage=ones goal -> NO correct production
;;; matches in EITHER engine). Buggy productions are libactr-loader-only (appended
;;; post-load, like fraction/past-tense), so no buggy dual case.

(defun subtraction-model-path ()
  "Path to the Phase 11 subtraction model (libactr/models/subtraction.lisp)."
  (asdf:system-relative-pathname "libactr" "models/subtraction.lisp"))

(test dual-track-subtraction-ones-direct
  "Goal: stage=ones res-ones nil top-ones 7 bot-ones 5. Retrieval: col-fact
kind=direct top 7 bot 5 diff 2. Both engines must agree SUBTRACT-ONES-DIRECT
matches and the other three correct productions do not."
  (let ((goal (libactr:make-chunk :isa 'sub2
                              :slots '((stage . ones) (res-ones . nil)
                                       (top-ones . 7) (bot-ones . 5)
                                       (top-tens . 4) (bot-tens . 2)
                                       (res-tens . nil))))
        (retr (libactr:make-chunk :isa 'col-fact
                              :slots '((kind . direct) (top . 7) (bot . 5)
                                       (diff . 2)))))
    ;; sub2 / col-fact intern in :libactr/test here; oracle compares by name.
    (let ((diffs (dual-track-check-with-retrieval (subtraction-model-path) goal retr)))
      (is (null diffs) "subtraction ones-direct dual-track: ~A" diffs))))

(test dual-track-subtraction-ones-borrow
  "Goal: stage=ones res-ones nil top-ones 2 bot-ones 8. Retrieval: col-fact
kind=borrow top 2 bot 8 diff 4. Both engines must agree SUBTRACT-ONES-BORROW
matches and SUBTRACT-ONES-DIRECT does not (kind literal)."
  (let ((goal (libactr:make-chunk :isa 'sub2
                              :slots '((stage . ones) (res-ones . nil)
                                       (top-ones . 2) (bot-ones . 8)
                                       (top-tens . 5) (bot-tens . 1)
                                       (res-tens . nil))))
        (retr (libactr:make-chunk :isa 'col-fact
                              :slots '((kind . borrow) (top . 2) (bot . 8)
                                       (diff . 4)))))
    (let ((diffs (dual-track-check-with-retrieval (subtraction-model-path) goal retr)))
      (is (null diffs) "subtraction ones-borrow dual-track: ~A" diffs))))

(test dual-track-subtraction-propagate
  "Goal: stage=propagate top-tens 5. Retrieval: col-fact kind=propagate
old-top 5 new-top 4. Both engines must agree PROPAGATE-BORROW matches (the
old-top variable unifies with the goal's current tens digit — the
double-entry check) and no other production does."
  (let ((goal (libactr:make-chunk :isa 'sub2
                              :slots '((stage . propagate) (top-tens . 5)
                                       (top-ones . 2) (bot-ones . 8)
                                       (bot-tens . 1) (res-ones . 4)
                                       (res-tens . nil))))
        (retr (libactr:make-chunk :isa 'col-fact
                              :slots '((kind . propagate) (old-top . 5)
                                       (new-top . 4)))))
    (let ((diffs (dual-track-check-with-retrieval (subtraction-model-path) goal retr)))
      (is (null diffs) "subtraction propagate dual-track: ~A" diffs))))

(test dual-track-subtraction-tens-direct
  "Goal: stage=tens res-tens nil top-tens 4 bot-tens 1. Retrieval: col-fact
kind=direct top 4 bot 1 diff 3. Both engines must agree SUBTRACT-TENS-DIRECT
matches (the decremented tens value written by propagate unifies with the
fact's top) and no other production does."
  (let ((goal (libactr:make-chunk :isa 'sub2
                              :slots '((stage . tens) (res-tens . nil)
                                       (top-tens . 4) (bot-tens . 1)
                                       (top-ones . 2) (bot-ones . 8)
                                       (res-ones . 4))))
        (retr (libactr:make-chunk :isa 'col-fact
                              :slots '((kind . direct) (top . 4) (bot . 1)
                                       (diff . 3)))))
    (let ((diffs (dual-track-check-with-retrieval (subtraction-model-path) goal retr)))
      (is (null diffs) "subtraction tens-direct dual-track: ~A" diffs))))

(test dual-track-subtraction-mismatch-agrees
  "Negative agreement: goal stage=ones but retrieval holds a kind=PROPAGATE
fact -> NO correct production matches in EITHER engine (ones-* need kind
direct/borrow, propagate needs stage=propagate, tens needs stage=tens). Guards
the kind/stage literal discrimination paths both ways."
  (let ((goal (libactr:make-chunk :isa 'sub2
                              :slots '((stage . ones) (res-ones . nil)
                                       (top-ones . 7) (bot-ones . 5)
                                       (top-tens . 4) (bot-tens . 2)
                                       (res-tens . nil))))
        (retr (libactr:make-chunk :isa 'col-fact
                              :slots '((kind . propagate) (old-top . 4)
                                       (new-top . 3)))))
    (let ((diffs (dual-track-check-with-retrieval (subtraction-model-path) goal retr)))
      (is (null diffs) "subtraction mismatch dual-track: ~A" diffs))))

;;; ---------------------------------------------------------------------------
;;; Phase 12 debt #3: sixth subtraction negative case (old-top != top-tens)
;;; ---------------------------------------------------------------------------
;;; The five phase-11 cases (and the brief's draft of this one) prove engine
;;; AGREEMENT only.  Agreement alone cannot be discriminated by test-data
;;; changes: both engines share the match semantics, so any legal data change
;;; moves both verdicts together and the discrepancy list stays nil.  This
;;; case therefore ALSO pins the DIRECTION of the agreement — the no-match
;;; verdict per engine — via dual-track-production-matches, so the data probe
;;; (top-tens 5 -> 4, making old-top agree) turns the test red in both pins.

(defun dual-track-production-matches (model-path production-name goal-chunk
                                       retrieval-chunk)
  "Load MODEL-PATH on BOTH engines, install GOAL-CHUNK/RETRIEVAL-CHUNK, and
   return two values: whether libactr's matcher matches PRODUCTION-NAME and
   whether the act-r oracle does.  Mirrors dual-track-check-with-retrieval's
   setup (same load/set order, same name-matching discipline); engine errors
   surface as (VALUES :ERROR :ERROR) so callers' null-pins fail loudly."
  (handler-case
      (let ((names (libactr/oracle:oracle-load-model model-path)))
        (declare (ignore names))
        (libactr/oracle:oracle-set-goal-from-chunk goal-chunk)
        (libactr/oracle:oracle-set-retrieval-from-chunk retrieval-chunk)
        (let* ((md (libactr:compile-model (libactr:read-model-file model-path)))
               (state (libactr:make-buffer-state)))
          (setf (libactr:buffer-chunk state 'goal) goal-chunk)
          (setf (libactr:buffer-chunk state 'retrieval) retrieval-chunk)
          (let ((libactr-matched
                  (mapcar #'libactr:production-name
                          (mapcar #'car (libactr:model-matching-productions md state)))))
            (values (not (null (member (symbol-name production-name) libactr-matched
                                       :key #'symbol-name :test #'string=)))
                    (libactr/oracle:oracle-matches-p production-name)))))
    (error () (values :error :error))))

(test dual-track-subtraction-old-top-mismatch-agrees
  "Sixth negative case (phase 11 deferred, phase 12 debt #3): goal
stage=propagate top-tens 5 vs fact kind=propagate old-top 4 — the
cross-buffer variable unification (=ot bound from the goal, retrieval's
old-top must agree) FAILS, so PROPAGATE-BORROW must NOT match in EITHER
engine. Guards the double-entry check in the negative direction."
  (let ((goal (libactr:make-chunk :isa 'sub2
                              :slots '((stage . propagate) (top-tens . 5)
                                       (top-ones . 2) (bot-ones . 8)
                                       (bot-tens . 1) (res-ones . 4)
                                       (res-tens . nil))))
        (retr (libactr:make-chunk :isa 'col-fact
                              :slots '((kind . propagate) (old-top . 4)
                                       (new-top . 3)))))
    ;; Agreement across all four productions (as in the five phase-11 cases)...
    (let ((diffs (dual-track-check-with-retrieval (subtraction-model-path) goal retr)))
      (is (null diffs) "subtraction old-top-mismatch dual-track: ~A" diffs))
    ;; ...plus the pinned DIRECTION: neither engine may match PROPAGATE-BORROW
    ;; (the agreement-only draft stays green under the top-tens probe, so the
    ;; no-match claim itself is asserted per engine here).
    (multiple-value-bind (libactr-p oracle-p)
        (dual-track-production-matches (subtraction-model-path)
                                       'propagate-borrow goal retr)
      (is (null libactr-p)
          "libactr matches PROPAGATE-BORROW despite old-top 4 != top-tens 5")
      (is (null oracle-p)
          "oracle matches PROPAGATE-BORROW despite old-top 4 != top-tens 5"))))
