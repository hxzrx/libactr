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

;; ----------------------------------------------------------------- Layer 2
;; On-path judgment (spec §7.1 indicator #2/#3 end-to-end): for addition's
;; correct path, each expert step is judged on-path by mtt's trace-step, with
;; expected post-state oracle-verified via oracle-fire-and-read-slots (the
;; Layer 1 mechanism). Curated correct-path states — NOT auto-forward-trace —
;; because headless act-r forward-trace auto-capture is fragile (retrieval-wait
;; pmatches=nil gaps).

(test layer2-on-path-initialize-agrees-with-oracle
  "Layer 2: the expert's first step (initialize-addition) is judged on-path by
   mtt, resolving to initialize-addition. Expected post-state oracle-verified."
  (mtt/oracle:oracle-load-model (addition-model-path))
  (let* ((goal (mtt:make-chunk :isa 'add :slots '((arg1 . five) (arg2 . two) (sum . nil))))
         ;; oracle-verify the post-state of firing initialize-addition
         (post (mtt/oracle:oracle-fire-and-read-slots goal '(sum count) nil))
         (expected-sum (cdr (assoc :sum post))))
    (is (eq :five expected-sum) "oracle confirms initialize → sum=five")
    ;; mtt must judge the expert step on-path with the same production
    (let* ((md (mtt:compile-model (mtt:read-model-file (addition-model-path))))
           (state (let ((s (mtt:make-buffer-state)))
                    (setf (mtt:buffer-chunk s 'goal) goal) s))
           (intent (mtt:make-step-intent
                    :assignments `((goal sum ,(intern (string expected-sum) :mtt/test))
                                   (goal count zero))))
           (r (mtt:trace-step md state nil intent)))
      (is (eq :on-path (mtt:trace-result-status r)))
      (is (eq 'initialize-addition
              (mtt:production-name (mtt:trace-result-production r)))))))

(test layer2-on-path-increment-sum-agrees-with-oracle
  "Layer 2: a mid-count state (sum=five count=zero, retrieval holding number five
   next six) → expert fires increment-sum (sum six). mtt judges the student's
   'enter next total = six' on-path via increment-sum. Retrieval provisioned
   explicitly; post-state oracle-verified."
  (mtt/oracle:oracle-load-model (addition-model-path))
  (let* ((goal (mtt:make-chunk :isa 'add :slots '((sum . five) (count . zero) (arg1 . five) (arg2 . two))))
         (ret  (mtt:make-chunk :isa 'number :slots '((number . five) (next . six))))
         (post (mtt/oracle:oracle-fire-and-read-slots goal '(sum) ret)))
    (is (eq :six (cdr (assoc :sum post))) "oracle confirms increment-sum → sum=six")
    (let* ((md (mtt:compile-model (mtt:read-model-file (addition-model-path))))
           (state (let ((s (mtt:make-buffer-state)))
                    (setf (mtt:buffer-chunk s 'goal) goal)
                    (setf (mtt:buffer-chunk s 'retrieval) ret) s))
           (intent (mtt:make-step-intent :assignments '((goal sum six))))
           (r (mtt:trace-step md state nil intent)))
      (is (eq :on-path (mtt:trace-result-status r)))
      (is (eq 'increment-sum (mtt:production-name (mtt:trace-result-production r)))))))
