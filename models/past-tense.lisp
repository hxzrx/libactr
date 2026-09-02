;;; past-tense.lisp — English past-tense inflection, Phase 10 third domain.
;;; act-r/libactr common subset. Slot values are SYMBOLS in the model package
;;; (GO, WENT, WALKED — unlike fraction's integers; act-r accepts symbol
;;; chunks natively). Adapter primes retrieval with verb-fact / bug-fact;
;;; add-dm intentionally absent (libactr traces against adapter-primed
;;; retrieval; dual-track sets retrieval directly). KC attribution is applied
;;; post-load by load-past-tense-model (reader does not parse kc).
;;;
;;; Design note (spec §3, amended 2026-08-15): the two correct productions
;;; discriminate on the retrieval CLASS slot literal (irregular/regular),
;;; NOT on chunk-type isa. ACT-R 7's runtime does not test isa in buffer
;;; conditions (chunks carry no type at run time; procedural.lisp warns
;;; "isa that provides no tests"), so an isa-only discriminator would
;;; diverge between the libactr matcher and the act-r oracle. A plain slot
;;; literal is a real test in BOTH engines — same idiom as bug-fact's kind.
(clear-all)

(define-model past-tense
  (sgp :esc t :lf .05)

  (chunk-type past-tense-task verb past)
  (chunk-type verb-fact verb class past)
  (chunk-type bug-fact  kind verb past)

  (goal-focus (isa past-tense-task verb go past nil))

  (P retrieve-irregular
     =goal>
        ISA        past-tense-task
        verb       =v
        past       nil
     =retrieval>
        ISA        verb-fact
        verb       =v
        class      irregular
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
        ISA        verb-fact
        verb       =v
        class      regular
        past       =p
   ==>
     =goal>
        ISA        past-tense-task
        past       =p))
