;;; past-tense.lisp — English past-tense inflection, Phase 10 third domain.
;;; act-r/mtt common subset. Slot values are SYMBOLS in the model package
;;; (GO, WENT, WALKED — unlike fraction's integers; act-r accepts symbol
;;; chunks natively). Adapter primes retrieval with word-fact / rule-fact /
;;; bug-fact; add-dm intentionally absent (mtt traces against adapter-primed
;;; retrieval; dual-track sets retrieval directly). KC attribution is applied
;;; post-load by load-past-tense-model (reader does not parse kc).
(clear-all)

(define-model past-tense
  (sgp :esc t :lf .05)

  (chunk-type past-tense-task verb past)
  (chunk-type word-fact verb past)
  (chunk-type rule-fact verb past)
  (chunk-type bug-fact  kind verb past)

  (goal-focus (isa past-tense-task verb go past nil))

  (P retrieve-irregular
     =goal>
        ISA        past-tense-task
        verb       =v
        past       nil
     =retrieval>
        ISA        word-fact
        verb       =v
        past       =p
   ==>
     =goal>
        ISA        past-tense-task
        past       =p)

  (P apply-regular
     =goal>
        ISA        past-tense-task
        verb       =v
        past       nil
     =retrieval>
        ISA        rule-fact
        verb       =v
        past       =p
   ==>
     =goal>
        ISA        past-tense-task
        past       =p))
