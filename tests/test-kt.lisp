;;;; tests/test-kt.lisp — knowledge tracing (Phase 6, pure)
;;;; Reference values hand-computed in spec §3.4 (L0=1/10, T=1/10, G=1/5, S=1/10).
(in-package :libactr/test)
(in-suite :libactr)

(defmacro approx (x y &optional (tol 1e-6))
  `(< (abs (- ,x ,y)) ,tol))

(test kt-update.single-correct-from-l0
  "kt-update(L0=0.1, correct) = posterior 1/3 + transit = 2/5 = 0.4 (spec §3.4 [t])."
  (let ((p (make-kt-params)))
    (is (approx (kt-update 0.1d0 t p) 2/5))))

(test kt-update.single-incorrect-from-l0
  "kt-update(L0=0.1, incorrect) = 41/365 ≈ 0.112329 (spec §3.4 [nil])."
  (let ((p (make-kt-params)))
    (is (approx (kt-update 0.1d0 nil p) 41/365))))

(test kt-posterior.reference-sequences
  "kt-posterior over spec §3.4 reference sequences (folded from L0)."
  (let ((p (make-kt-params)))
    (is (approx (kt-posterior (list t)           p) 2/5))      ; 0.4
    (is (approx (kt-posterior (list t t)         p) 31/40))    ; 0.775
    (is (approx (kt-posterior (list t nil)       p) 11/65))    ; 0.169231
    (is (approx (kt-posterior (list nil)         p) 41/365))   ; 0.112329
    (is (approx (kt-posterior (list nil t)       p) 241/565))  ; 0.426549
    (is (approx (kt-posterior (list t t t)       p) 52/55))))  ; 0.945455

(test kt-posterior.empty-is-l0
  "Empty observation list returns the prior L0."
  (let ((p (make-kt-params)))
    (is (approx (kt-posterior nil p) 0.1d0))))

(test kt-posterior.params-injection-changes-result
  "Same sequence, different guess → different P(L). [t] with G=0.3 → 0.325, not 0.4."
  (let ((default (make-kt-params))
        (hi-guess (make-kt-params :guess 0.3d0)))
    (is (approx (kt-posterior (list t) default) 2/5))
    (is (approx (kt-posterior (list t) hi-guess) 13/40))        ; 0.325
    (is (not (approx (kt-posterior (list t) default)
                     (kt-posterior (list t) hi-guess))))))

(test kt-params-for.override-wins
  "kt-params-for returns the per-KC override when present (assoc by eql on kc)."
  (let* ((slow (make-kt-params :transit 0.01d0))
         (p (make-kt-params :overrides (list (cons :common-denominator slow)))))
    (is (eq slow (kt-params-for :common-denominator p)))))

(test kt-params-for.fallback-to-base
  "kt-params-for falls back to the base params when no override for the kc."
  (let ((p (make-kt-params)))
    (is (eq p (kt-params-for :add-fractions p)))
    (is (null (kt-params-overrides p)))))

(test kt-posterior.uses-per-kc-override
  "An override param set changes P(L) for the same sequence. [t t t] base=52/55;
with transit=0.01 the fold climbs slower -> strictly lower P(L)."
  (let ((base (make-kt-params))
        (slow (make-kt-params :transit 0.01d0)))
    (is (approx (kt-posterior (list t t t) base) 52/55))
    (is (< (kt-posterior (list t t t) slow)
           (kt-posterior (list t t t) base)))))

;;; ---------- Review F9: BKT parameter-contract validation ----------------------

(test kt.check-kt-params-accepts-valid-sets
  "F9: the default set and a legal override table pass check-kt-params (returns
the params)."
  (let ((p (make-kt-params)))
    (is (eq p (check-kt-params p))))
  (let ((p (make-kt-params
            :overrides (list (cons :kc (make-kt-params :transit 0.3d0))))))
    (is (eq p (check-kt-params p)))))

(test kt.check-kt-params-rejects-deceptive-region
  "F9: G+S>=1 drives kt-update's Bayes denominator to zero — rejected at the
boundary instead of dividing by zero at mastery time."
  (signals error (check-kt-params (make-kt-params :guess 0.7d0 :slip 0.4d0))))

(test kt.check-kt-params-rejects-out-of-range
  "F9: every parameter must be a real strictly inside (0,1)."
  (signals error (check-kt-params (make-kt-params :transit 1.0d0)))
  (signals error (check-kt-params (make-kt-params :l0 0.0d0)))
  (signals error (check-kt-params (make-kt-params :slip 1.5d0))))

(test kt.check-kt-params-rejects-bad-override
  "F9: overrides are validated too (a violating per-KC set used to slip through
to the fold)."
  (signals error
    (check-kt-params
     (make-kt-params
      :overrides (list (cons :some-kc (make-kt-params :guess 0.9d0 :slip 0.2d0)))))))

(test kt.compute-mastery-signals-on-bad-params
  "F9 backstop: compute-mastery validates before folding (a clear error, not a
division by zero mid-fold)."
  (signals error (compute-mastery nil :kt-params (make-kt-params :guess 0.8d0 :slip 0.3d0))))
