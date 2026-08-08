;;;; tests/test-dual-track.lisp — dual-track oracle correctness vs act-r.
;;;
;;; Task 6: oracle unit verification on the addition model (hand-checked).
;;; Task 7: full dual-track regression — compare mtt's model-matching-productions
;;;          against the act-r oracle's per-production oracle-matches-p across
;;;          every tutorial model.  Discrepancies are either fixed (real matcher
;;;          bugs) or documented as known non-defects.
(in-package :mtt/test)
(in-suite :mtt)

;;; ---------------------------------------------------------------------------
;;; Task 6 (kept): oracle unit verification
;;; ---------------------------------------------------------------------------

(test oracle-judges-initialize-addition-matches
  "act-r oracle agrees that initialize-addition (not terminate-addition)
matches a fresh addition goal with sum=nil, and disagrees correctly once
the goal is set to a terminate-addition state."
  (let* ((model (asdf:system-relative-pathname "act-r" "tutorial/unit1/addition.lisp"))
         (names (mtt/oracle:oracle-load-model model)))
    ;; production names come back as keywords (package-neutral)
    (is (member :initialize-addition names))
    (is (member :terminate-addition names))
    ;; fresh goal: arg1=five arg2=two sum=nil  -> initialize-addition fires
    (mtt/oracle:oracle-set-goal-from-chunk
      (mtt:make-chunk :isa 'add :slots '((arg1 . five) (arg2 . two) (sum . nil))))
    (is (mtt/oracle:oracle-matches-p 'initialize-addition))
    (is (not (mtt/oracle:oracle-matches-p 'terminate-addition)))
    ;; terminate state: count=arg2=num and retrieval holds the answer
    (mtt/oracle:oracle-set-goal-from-chunk
      (mtt:make-chunk :isa 'add :slots '((count . two) (arg2 . two) (sum . seven))))
    (mtt/oracle:oracle-set-retrieval-from-chunk
      (mtt:make-chunk :isa 'number :slots '((number . seven))))
    (is (mtt/oracle:oracle-matches-p 'terminate-addition))
    (is (not (mtt/oracle:oracle-matches-p 'initialize-addition)))))

;;; ---------------------------------------------------------------------------
;;; Task 7: dual-track consistency — mtt matcher vs act-r oracle
;;; ---------------------------------------------------------------------------
;;;
;;; dual-track-check loads a model in BOTH engines from the SAME goal-only
;;; buffer state (other buffers empty), then for every production compares
;;; mtt's matching judgment against the oracle's.  Any disagreement is a
;;; discrepancy worth investigating:
;;;   * mtt bug (unification / negation / nil / ISA / :?) -> fix the kernel
;;;   * out-of-subset feature (perceptual/motor/retrieval buffers) -> document
;;;   * deliberately malformed model -> handler-case + document
;;;
;;; Package note: oracle-load-model returns production names as KEYWORDS
;;; (package-neutral), while mtt's production-name symbols live in the caller's
;;; package (here :mtt/test).  Comparison is therefore by SYMBOL-NAME, not eq.

(defun dual-track-check (model-path goal-chunk)
  "Return a list of discrepancies: (production-name mtt-says oracle-says) for
   each production where mtt and the oracle DISAGREE on whether it matches.
   Both engines start from the SAME goal-only state (goal=GOAL-CHUNK, all other
   buffers empty).  Returns NIL when they agree on every production."
  (let ((names (mtt/oracle:oracle-load-model model-path)))
    (mtt/oracle:oracle-set-goal-from-chunk goal-chunk)
    (let* ((md (mtt:compile-model (mtt:read-model-file model-path)))
           (state (mtt:make-buffer-state)))
      (setf (mtt:buffer-chunk state 'goal) goal-chunk)
      ;; mtt-matched-names: symbols in :mtt/test (the caller's package).
      (let ((mtt-matched
              (mapcar #'mtt:production-name
                      (mapcar #'car (mtt:model-matching-productions md state)))))
        (loop :for n :in names      ; keywords from the oracle
              ;; Compare by NAME, not eq — keywords ≠ :mtt/test symbols.
              :for mtt-says = (find (symbol-name n) mtt-matched
                                    :key #'symbol-name :test #'string=)
              :for oracle-says = (mtt/oracle:oracle-matches-p n)
              :unless (eq (not (null mtt-says)) (not (null oracle-says)))
                :collect (list n mtt-says oracle-says))))))

;;; ---------- Step 1: addition model at the initial goal (binding contract) ----------

(test dual-track-addition-initial-state
  "Binding contract: ZERO discrepancies on addition.lisp at its initial goal.
   The goal is arg1=five arg2=two sum=nil; only initialize-addition should
   match on both engines.  The other three productions require =retrieval>,
   which is empty on both sides, so both must agree they do not match."
  (let ((model (asdf:system-relative-pathname "act-r" "tutorial/unit1/addition.lisp")))
    (let ((diffs (dual-track-check
                   model
                   (mtt:make-chunk :isa 'add
                                   :slots '((arg1 . five) (arg2 . two) (sum . nil))))))
      (is (null diffs)
          "mtt vs oracle discrepancy on addition initial state: ~A" diffs))))

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
   than an mtt bug.  This lets the batch test PASS (green) while still
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
          (let* ((md (mtt:compile-model (mtt:read-model-file m)))
                 (goal (mtt:model-definition-initial-goal md)))
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
