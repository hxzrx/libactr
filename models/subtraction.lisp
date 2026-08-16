;;; subtraction.lisp — 2-digit column subtraction with borrowing, Phase 11
;;; second arithmetic domain. act-r/mtt common subset. MIXED slot values:
;;; digit slots are small integers (fraction precedent), stage is a model-
;;; package symbol (past-tense precedent). Discrimination is on slot LITERALS
;;; (col-fact kind / sub2 stage) + cross-buffer variable unification — NOT
;;; isa (Phase 10 lesson: act-r does not test isa in buffer conditions).
;;; Borrowing is represented as V1 decrement-in-place: the hidden
;;; propagate-borrow production rewrites top-tens to the decremented value
;;; supplied by the adapter's primed fact (mirrors addition's increment-sum +
;;; increment-count pair). add-dm intentionally absent (mtt traces against
;;; adapter-primed retrieval; dual-track sets retrieval directly). KC
;;; attribution is applied post-load by load-subtraction-model.
(clear-all)

(define-model subtraction-2digit
  (sgp :esc t :lf .05)

  (chunk-type sub2     top-ones top-tens bot-ones bot-tens res-ones res-tens stage)
  (chunk-type col-fact kind top bot diff old-top new-top)
  (chunk-type bug-fact kind digit)

  (goal-focus (isa sub2 top-ones 2 top-tens 5 bot-ones 8 bot-tens 1
                   res-ones nil res-tens nil stage ones))

  (P subtract-ones-direct
     =goal>
        ISA        sub2
        stage      ones
        res-ones   nil
        top-ones   =t
        bot-ones   =b
     =retrieval>
        ISA        col-fact
        kind       direct
        top        =t
        bot        =b
        diff       =d
   ==>
     =goal>
        ISA        sub2
        res-ones   =d
        stage      tens)

  (P subtract-ones-borrow
     =goal>
        ISA        sub2
        stage      ones
        res-ones   nil
        top-ones   =t
        bot-ones   =b
     =retrieval>
        ISA        col-fact
        kind       borrow
        top        =t
        bot        =b
        diff       =d
   ==>
     =goal>
        ISA        sub2
        res-ones   =d
        stage      propagate)

  (P propagate-borrow
     =goal>
        ISA        sub2
        stage      propagate
        top-tens   =ot
     =retrieval>
        ISA        col-fact
        kind       propagate
        old-top    =ot
        new-top    =nt
   ==>
     =goal>
        ISA        sub2
        top-tens   =nt
        stage      tens)

  (P subtract-tens-direct
     =goal>
        ISA        sub2
        stage      tens
        res-tens   nil
        top-tens   =t
        bot-tens   =b
     =retrieval>
        ISA        col-fact
        kind       direct
        top        =t
        bot        =b
        diff       =d
   ==>
     =goal>
        ISA        sub2
        res-tens   =d
        stage      done))
