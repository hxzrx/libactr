;;;; tests/test-dual-track.lisp — dual-track oracle correctness vs act-r.
;;;; Task 6: oracle unit verification on the addition model (hand-checked).
;;;; Task 7 extends this into a full batch regression over many models.
(in-package :mtt/test)
(in-suite :mtt)

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
