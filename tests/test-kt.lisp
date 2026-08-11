;;;; tests/test-kt.lisp — knowledge tracing (Phase 6, pure)
;;;; Reference values hand-computed in spec §3.4 (L0=1/10, T=1/10, G=1/5, S=1/10).
(in-package :mtt/test)
(in-suite :mtt)

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
