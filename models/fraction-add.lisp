;;; fraction-add.lisp — fraction addition (unlike denominators), Phase 7 model.
;;; act-r/libactr common subset. Slot values are small integers. Adapter primes
;;; retrieval with lcm-fact / sum-fact / bug-fact; add-dm intentionally absent
;;; (libactr traces against adapter-primed retrieval; dual-track sets retrieval
;;; directly). KC attribution is applied post-load by load-fraction-model
;;; (reader does not parse kc), NOT in this file.
;;; Phase 13: SIMPLIFY (3rd correct production, kc :simplify) reduces the summed
;;; fraction via a reduce-fact (num den rnum rdenom) primed retrieval; step
;;; sequencing stays nil-guard (cdenom nil -> snum nil -> rnum nil).
(clear-all)

(define-model fraction-addition
  (sgp :esc t :lf .05)

  (chunk-type frac-add num1 den1 num2 den2 cdenom snum sdenom rnum rdenom)
  (chunk-type lcm-fact    d1 d2 lcm)
  (chunk-type sum-fact    cdenom snum sdenom)
  (chunk-type reduce-fact num den rnum rdenom)
  (chunk-type bug-fact    kind num denom)

  (goal-focus (isa frac-add num1 1 den1 2 num2 1 den2 3))

  (P find-common-denominator
     =goal>
        ISA        frac-add
        den1       =d1
        den2       =d2
        cdenom     nil
     =retrieval>
        ISA        lcm-fact
        d1         =d1
        d2         =d2
        lcm        =lcd
   ==>
     =goal>
        ISA        frac-add
        cdenom     =lcd)

  (P add-fractions
     =goal>
        ISA        frac-add
        cdenom     =cd
        snum       nil
     =retrieval>
        ISA        sum-fact
        cdenom     =cd
        snum       =sn
        sdenom     =sd
   ==>
     =goal>
        ISA        frac-add
        snum       =sn
        sdenom     =sd)

  (P simplify
     =goal>
        ISA        frac-add
        rnum       nil
     =retrieval>
        ISA        reduce-fact
        num        =sn
        den        =sd
        rnum       =rn
        rdenom     =rd
   ==>
     =goal>
        ISA        frac-add
        rnum       =rn
        rdenom     =rd))
