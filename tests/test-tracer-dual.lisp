;;;; tests/test-tracer-dual.lisp — Phase 3 dual-track: Layer 1 (RHS-effect)
;;;; and Layer 2 (oracle-verified correct-path corpus).
(in-package :mtt/test)
(in-suite :mtt)

(defun addition-model-path ()
  (asdf:system-relative-pathname "act-r" "tutorial/unit1/addition.lisp"))

(defun kw (x) "Coerce a symbol value to a package-neutral keyword (or pass through nil/non-symbol)."
  (typecase x (null nil) (symbol (intern (symbol-name x) :keyword)) (t x)))

(test layer1-rhs-effect-initialize-addition-matches-act-r
  "Layer 1: mtt apply-rhs on initialize-addition agrees with act-r firing it.
   Fresh goal arg1=five arg2=two sum=nil → after firing, goal sum/count match."
  (mtt/oracle:oracle-load-model (addition-model-path))
  (let* ((goal (mtt:make-chunk :isa 'add :slots '((arg1 . five) (arg2 . two) (sum . nil))))
         (oracle-slots (mtt/oracle:oracle-fire-and-read-slots
                        goal '(sum count) nil)))
    ;; oracle returns (slot-name-keyword . value-keyword)
    (let ((oracle-sum  (cdr (assoc :sum  oracle-slots)))
          (oracle-count (cdr (assoc :count oracle-slots))))
      (is (eq :five oracle-sum)   "oracle: initialize-addition sets sum=five")
      (is (eq :zero oracle-count) "oracle: initialize-addition sets count=zero"))
    ;; mtt side
    (let* ((md (mtt:compile-model (mtt:read-model-file (addition-model-path))))
           (prod (find 'initialize-addition (mtt:model-definition-productions md)
                       :key #'mtt:production-name))
           (state (let ((s (mtt:make-buffer-state)))
                    (setf (mtt:buffer-chunk s 'goal) goal) s))
           (bindings (mtt:match-production prod state (mtt:model-definition-chunk-types md)))
           (next (mtt:apply-rhs (mtt:production-rhs prod) state bindings)))
      (is (eq :five  (kw (mtt:chunk-slot (mtt:buffer-chunk next 'goal) 'sum))))
      (is (eq :zero  (kw (mtt:chunk-slot (mtt:buffer-chunk next 'goal) 'count)))))))
