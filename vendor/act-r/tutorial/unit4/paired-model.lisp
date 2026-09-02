
(clear-all)

(define-model paired
    
(sgp :v t :esc t :rt -2 :lf 0.4 :ans 0.5 :bll 0.5 :act nil :ncnar nil) 
(sgp :seed (200 4))

(chunk-type goal step)
(chunk-type pair probe answer)

(add-dm
 (start isa chunk) (attending-target isa chunk)
 (attending-probe isa chunk)
 (testing isa chunk) (read-study-item isa chunk))

(p attend-probe
    =goal>
      isa      goal
      step     start
    =visual-location>
    ?visual>
     state     free
   ==>
    +visual>               
      cmd      move-attention
      screen-pos =visual-location
    =goal>
      step     attending-probe
)

(p read-probe
    =goal>
      isa      goal
      step     attending-probe
    =visual>
      isa      visual-object
      value    =val
    ?imaginal>
      state    free
   ==>
    +imaginal>
      isa      pair
      probe    =val
    +retrieval>
      isa      pair
      probe    =val
    =goal>
      step     testing
)

(p recall
    =goal>
      isa      goal 
      step     testing
    =retrieval>
      isa      pair
      answer   =ans
    ?manual>   
      state    free
    ?visual>
      state    free
   ==>
    +manual>              
      cmd      press-key     
      key      =ans
    =goal>
      step     read-study-item
    +visual>
      cmd      clear
)


(p cannot-recall
    =goal>
      isa      goal 
      step     testing
    ?retrieval>
      buffer   failure
    ?visual>
      state    free
   ==>
    =goal>
     step     read-study-item
    +visual>
     cmd      clear
)

(p detect-study-item
    =goal>
      isa      goal
      step     read-study-item
   =visual-location>
   ?visual>
      state    free
   ==>
   +visual>               
      cmd      move-attention
      screen-pos =visual-location
    =goal>
      step     attending-target
)


(p associate
    =goal>
      isa      goal
      step     attending-target
   =visual>
      isa      visual-object
      value    =val
   =imaginal>
      isa      pair
      probe    =probe
   ?visual>
      state    free
  ==>
   =imaginal>
      answer   =val
   -imaginal>
   =goal>
      step     start  
   +visual>
      cmd      clear
)


(goal-focus (isa goal step start))
)
