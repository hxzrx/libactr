;;;  -*- mode: LISP; Syntax: COMMON-LISP;  Base: 10 -*-
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 
;;; Author      : Dan Bothell
;;; Copyright   : (c) 2005 Dan Bothell
;;; Availability: Covered by the GNU LGPL, see LGPL.txt
;;; Address     : Department of Psychology 
;;;             : Carnegie Mellon University
;;;             : Pittsburgh, PA 15213-3890
;;;             : db30@andrew.cmu.edu
;;; 
;;; 
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 
;;; Filename    : spacing-effect.lisp
;;; Version     : 3.0
;;; 
;;; Description : A module to allow one to toggle the base-level learning
;;;             : equation from the default to the one proposed by 
;;;             : Pavlik and Anderson in Cognitive Science 29 (2005) 559-586.
;;; 
;;; Bugs        : 
;;;
;;; To do       : 
;;; 
;;; ----- History -----
;;; 2005.08.31 Dan
;;;             : * Creation for David Peebles.
;;; 2010.11.15 Dan
;;;             : * Took out the :bll setting since it's no longer necessary
;;;             :   and now generates a warning.
;;;             : * Except, it is still necessary...  So, now it's set to a 
;;;             :   large positive value instead.
;;;             : * Also added a reset function to turn off eblse before the
;;;             :   default parameters get set since declarative could go first
;;;             :   which would cause warnings from those default settings.
;;; 2011.04.25 Dan
;;;             : * Updated since DM uses millisecond times internally now.
;;; 2011.04.28 Dan
;;;             : * Suppress warnings about extending chunks at initial load.
;;; 2016.03.14 Dan
;;;             : * Added the provide so that it works well with require-extra.
;;; 2018.08.21 Dan [2.0]
;;;             : * Updated for 7.6+ with a lock to protect the internals.
;;; 2020.01.10 Dan [2.1]
;;;             : * Removed the #' from the module interface functions since 
;;;             :   that's not allowed in the general system now.
;;; 2022.05.09 Dan
;;;             : * Changed the "flag" value for :bll from 91923.12 to 12.34
;;;             :   to avoid potential overflow issues in DM's setting of some
;;;             :   other values in response.
;;; 2022.05.23 Dan
;;;             : * Set :ol to nil before setting the flag value of :bll when
;;;             :   setting :eblse to avoid the warning about complex numbers.
;;; 2023.05.16 Dan
;;;             : * Use exp-coerced for the error handling.
;;; 2023.05.22 Dan
;;;             : * Use model-output instead of pprint in the test functions so
;;;             :   that it shows up in the test output.
;;; 2025.03.24 Dan [3.0]
;;;             : * Fix a problem with how it works when used in a running model
;;;             :   instead of just setting the reference lists directly.  It 
;;;             :   was updating the m[i-1] values every time activations were
;;;             :   computed instead of only at the reference time.
;;;             : * Don't record the last-m value at all -- the merging will
;;;             :   handle that along with the chunk-add-hook.
;;;             : * Record the times with the decays so that if the reference-
;;;             :   list gets changed it will recompute the decays.
;;;             : * Try to clean up if it's disabled after having been enabled,
;;;             :   and print warnings about that.
;;;             : * Use set/get-parameter-value instead of (no-output (sgp ...))
;;; 2025.03.26 Dan
;;;             : * Added some more chunks to the new test case to have some 
;;;             :   more situations in the testing.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; General Docs:
;;; 
;;; When the :eblse (enable base level spacing effect) paramter is set to t
;;; base level activation is computed using the new equation.
;;;
;;; To do so, :ol (optimized learning) must be set to nil and the model 
;;; must not be using the :bl-hook functionality (warnings will be printed if
;;; violations of either of those conditions are noticed).  In addition,
;;; the setting of :bll by the model will be ignored and it will be set to
;;; the value 12.34 to enable the computation of base levels (since that 
;;; parameter is both the switch and the parameter value) and provide a value 
;;; that I can check against for saftey testing (since it's very unlikely that 
;;; a user will every set that specific value).
;;;
;;; The new equation for base level activation is similar to the old one:
;;;
;;;           n
;;; B[n] = ln( sum t[i]^-d[i])
;;;          i=1
;;;
;;; The only difference being that the decay exponent value is no longer
;;; a constant, but is now based on the previous base level values by this
;;; equation:
;;;
;;; d[i] = c*e^m[i-1] + a
;;;
;;; whre m[i] = B[i] + (permanant noise of the chunk)
;;;
;;; The paramters :se-intercept (spacing effect intercept) and :se-scale
;;; (spacing effect scale) control the new computation for a and c respectively.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Public API:
;;;
;;; New parameters :eblse, :se-intercept, and :se-scale only.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Design Choices:
;;;
;;; Because this was never actually implemented in ACT-R before, I asked Phil 
;;; which activation to use for m in the general case. His thoughts were that 
;;; it should only be based on the history of use of the chunk. That suggests 
;;; using only the base level computation plus any permanent noise present.  
;;; Thus, spreading activation, partial matching, and transient noise should 
;;; not be considered for this.
;;;
;;; It does not support changing the c and a parameters "on the fly".  When
;;; the model creates a reference the corresponding decay value is cached. 
;;; The only time it would recompute the decays is when the reference times
;;; are changed explicitly outside of the normal merging process after decays
;;; have been computed i.e. the number of references don't match the number 
;;; and/or times of the existing decays.  When that happens, it will recompute
;;; all of the decays (a potentially slow process).
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 
;;; The code
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

#+:packaged-actr (in-package :act-r)
#+(and :clean-actr (not :packaged-actr) :ALLEGRO-IDE) (in-package :cg-user)
#-(or (not :clean-actr) :packaged-actr :ALLEGRO-IDE) (in-package :cl-user)


(defstruct spacing-effect
  enabled
  scale
  intercept
  (lock (bt:make-recursive-lock "spacing-effect")))

(defun add-decay-value (chunk1 chunk2)
  "Add another decay to the list based on the activation of the chunk
   at the reference time."
  (declare (ignore chunk2))
  (let ((module (get-module spacing-effect))
        (c1-refs (chunk-reference-list chunk1))
        (c1-decays (chunk-decays chunk1))
        (current-time (mp-time-ms)))
    
    (bt:with-recursive-lock-held ((spacing-effect-lock module))
      (when (spacing-effect-enabled module)
        
        ;; The two expected situations assuming nothing odd has
        ;;    happened with the refs (the activation calculation
        ;;    checks for consistency and will fix the delays if
        ;;    something odd has happended):
        ;; - refs and decays are same length and times match
        ;;    which means decays are being merged first.
        ;;    So, compute a new decay and can use the
        ;;    compute-spacing-effect-activation to do so.
        ;; - there's one more ref than decay and it is the
        ;;    current time.  Temporarily change the refs so
        ;;    compute-spacing-effect-activation can be used
        ;;    to get the new decay value and then set it back.
        ;;
        ;; Otherwise, just set the decays to nil so that they'll
        ;; get recomputed next time the activation is needed.
        
        (cond ((equalp c1-refs (mapcar 'first c1-decays))
               ;; the ref must not have been updated yet
               ;; Can just compute the activation
               ;; based on the existing references 
               ;; and decays for the new decay
               
               (let ((act (+ (compute-spacing-effect-activation chunk1)
                             (chunk-permanent-noise chunk1))))
                 (cons (list current-time
                             (+ (* (spacing-effect-scale module) 
                                   (exp-coerced act))
                                (spacing-effect-intercept module)))
                       c1-decays)))
              
              ((and (= (car c1-refs) current-time)
                    (equalp (mapcar 'first c1-decays) (cdr c1-refs)))
               
               ;; There's one extra ref at the current time so refs were
               ;; presumably updated first.
               ;; Temporarily remove the extra ref to compute the
               ;; current decay value and then put it back
               
               (setf (chunk-reference-list chunk1) (cdr c1-refs))
               
               (let ((act (+ (compute-spacing-effect-activation chunk1)
                             (chunk-permanent-noise chunk1))))
                 
                 (setf (chunk-reference-list chunk1) c1-refs)
                 
                 (cons (list current-time
                             (+ (* (spacing-effect-scale module) 
                                   (exp-coerced act))
                                (spacing-effect-intercept module)))
                       c1-decays)))
              (t
               ;; unexpected situation
               ;; just clear the decays so they get recomputed
               nil))))))
    
    
(suppress-extension-warnings)   

(extend-chunks decays :default-value nil 
               :copy-function copy-list
               :merge-function add-decay-value)

(unsuppress-extension-warnings)


(defun spacing-effect-add-chunk (c)
  (let ((module (get-module spacing-effect))
        (c1-refs (chunk-reference-list c))
        (c1-decays (chunk-decays c)))
    (bt:with-recursive-lock-held ((spacing-effect-lock module))
      (if (and
           (spacing-effect-enabled module)
           (null c1-decays)
           (= 1 (length c1-refs)))
          (setf (chunk-decays c) (list (list (first c1-refs) (spacing-effect-intercept module))))
        ;; Mechanism is off or something is wrong, so set it to nil so they get recomputed
        (setf (chunk-decays c) nil)))))

(defun compute-spacing-effect-activation (chunk)
  (let ((module (get-module spacing-effect))
        (ct (mp-time-ms))
        (value 0.0))
    
    (bt:with-recursive-lock-held ((spacing-effect-lock module))
      (let* ((refs (chunk-reference-list chunk))
             (decay-list (chunk-decays chunk))
             (decay-times (mapcar 'first decay-list))
             (decays (mapcar 'second decay-list)))
        
        
        (if (equalp refs decay-times) ;;; the decays still match the references
            (progn
              (mapcar (lambda (reference decay)
                        (incf value 
                              (expt-coerced (max .05 (ms->seconds (- ct reference)))
                                            (- decay))))
                refs
                decays)
              
              (log-coerced value))
        
          ;; Compute the decay list and try again.
          ;; Slower, but it generally shouldn't have to do this
          ;; since the merging should maintain the list correctly,
          ;; but if someone sets references directly that can
          ;; get them out of sync.
          
          (let* ((references (reverse refs))
                 (decays (list (spacing-effect-intercept module)))
                 (new-references (list (pop references))))
            
            (dolist (reference references)
              (let ((value 0.0))
                
                (mapcar (lambda (r decay)
                          (incf value 
                                (expt-coerced (max .05 (ms->seconds (- reference r)))
                                              (- decay))))
                  new-references
                  decays)
                (push (+ (* (spacing-effect-scale module) 
                            (exp-coerced (+ (log-coerced value) (chunk-permanent-noise chunk))))
                         (spacing-effect-intercept module))
                      decays)
                (push reference new-references)))
            
            (setf (chunk-decays chunk) (mapcar 'list new-references decays))
            
            (compute-spacing-effect-activation chunk)))))))
  
  
(defun spacing-effect-params (module param)
  (bt:with-recursive-lock-held ((spacing-effect-lock module))
    (cond ((consp param)
           (case (car param)
             (:ol
              (when (and (cdr param)
                         (spacing-effect-enabled module))
                (model-warning "Cannot turn on :ol when :eblse enabled")
                (no-output (sgp :ol nil))))
             (:bll 
              (when (spacing-effect-enabled module)
                (cond ((and (numberp (cdr param)) (not (= (cdr param) 12.34)))
                       (model-warning "Changing :bll has no effect when :eblse is enabled")
                       (no-output (sgp :bll 12.34)))
                      ((not (numberp (cdr param)))
                       (model-warning "Cannot turn off :bll while :eblse is enabled")
                       (no-output (sgp :bll 12.34))))
                ))
             (:bl-hook 
              (when (and (spacing-effect-enabled module)
                         (not (equal (cdr param) 'compute-spacing-effect-activation)))
                (model-warning "Cannot change the :bll-hook when :eblse enabled")
                (no-output (sgp :bl-hook compute-spacing-effect-activation)))
              )
             (:eblse 
              ;; Try to clean up if it's disabled after having been enabled
              (when (and (null (cdr param))
                         (spacing-effect-enabled module))
                (print-warning "Turning off the spacing-effect extension after enabling it not recommended.")
                (print-warning "The :ol and :bll parameters may need to also be changed.")
                
                (when (eq (get-parameter-value :bl-hook) 'compute-spacing-effect-activation)
                  (set-parameter-value :bl-hook nil))
                
                (when (find 'spacing-effect-add-chunk (get-parameter-value :chunk-add-hook))
                  (set-parameter-value :chunk-add-hook (list :remove 'spacing-effect-add-chunk))))
                
              
              (setf (spacing-effect-enabled module) (cdr param))
              
              (when (cdr param)
                (set-parameter-value :ol nil)
                (set-parameter-value :bll 12.34)
                (set-parameter-value :bl-hook 'compute-spacing-effect-activation)
                (set-parameter-value :chunk-add-hook 'spacing-effect-add-chunk))
              
              (cdr param))
             
             (:se-intercept (setf (spacing-effect-intercept module) (cdr param)))
             (:se-scale (setf (spacing-effect-scale module) (cdr param)))))
          (t 
           (case param
             
             (:eblse (spacing-effect-enabled module))
             (:se-intercept (spacing-effect-intercept module))
             (:se-scale (spacing-effect-scale module)))))))
  

(defun reset-spacing-effect-module (module)
  (bt:with-recursive-lock-held ((spacing-effect-lock module))
    (setf (spacing-effect-enabled module) nil)))

(defun create-spacing-module (name) 
  (declare (ignore name))
  (make-spacing-effect))

(define-module-fct 'spacing-effect 
    nil
  (list (define-parameter :eblse :owner t :default-value nil :valid-test 'tornil
          :documentation "Enable base level spacing effect - turning this on replaces the base level equation with one sensitive to spacing effects"
          :warning "T or nil")
        (define-parameter :se-intercept :owner t :default-value .5 :valid-test 'numberp
          :warning "a number"
          :documentation "Spacing effect intercept parameter (a)")
        (define-parameter :se-scale :owner t :default-value 0 :valid-test 'numberp
          :warning "a number"
          :documentation "Spacing effect scale parameter (c)")
        (define-parameter :ol :owner nil)
        (define-parameter :bl-hook :owner nil)
        (define-parameter :bll :owner nil))
  
  :creation 'create-spacing-module
  :reset 'reset-spacing-effect-module
  :params 'spacing-effect-params
  :version "3.0" 
  :documentation 
  "Module to add the option of the Pavlik & Anderson spacing effect equation for base level activation"
  )


(defun test-spacing-effect-1 ()
  "Test the equation against the example in the paper for a sequence of retrievals"
  (clear-all)
  (define-model foo)
  (sgp :esc t :eblse t :v t :act t :se-intercept 0.177 :se-scale .217)
  (add-dm (g isa chunk))
  (run-until-time 126)
  ;; fake a retrieval to get the times specific for the reference
  (compute-activation (get-module declarative) 'g nil)
  (set-buffer-chunk 'retrieval 'g)
  (clear-buffer 'retrieval)
  
  (run-until-time 252)
  ;; fake a retrieval to get the times specific for the reference
  (compute-activation (get-module declarative) 'g nil)
  (set-buffer-chunk 'retrieval 'g)
  (clear-buffer 'retrieval)
  
  (run-until-time 4844)
  ;; fake a retrieval to get the times specific for the reference
  (compute-activation (get-module declarative) 'g nil)
  (set-buffer-chunk 'retrieval 'g)
  (clear-buffer 'retrieval)
  
  (run-until-time 5877)
  ;; fake a retrieval to get the times specific for the reference
  (compute-activation (get-module declarative) 'g nil)
  (model-output "~s" (mapcar 'second (chunk-decays 'g)))
  )




(defun test-spacing-effect-2 ()
  "Test the equation using a pre-specified reference list for a chunk"
  
  (clear-all)
  (define-model foo)
  (sgp :esc t :eblse t :v t :act t :se-intercept 0.177 :se-scale .217)
  (add-dm (g isa chunk))
  (sdp g :references (4844 252 126 0))
  (run-until-time 5877)
  (compute-activation (get-module declarative) 'g nil)
  (model-output "~s" (mapcar 'second (chunk-decays 'g)))
  )


(defun test-spacing-effect-3 ()
  "Compare the default with the spacing to the original equation - should match"
  (clear-all)
  (define-model foo)
  (sgp :esc t :v t :act t :bll .5 :ol nil)
  (add-dm (g isa chunk))
  (sdp g :references (4844 252 126 0))
  (run-until-time 5877)
  (compute-activation (get-module declarative) 'g nil)
  
  (clear-all)
  (define-model foo)
  (sgp :esc t :eblse t :v t :act t)
  (add-dm (g isa chunk))
  (sdp g :references (4844 252 126 0))
  (run-until-time 5877)
  (compute-activation (get-module declarative) 'g nil)
  (model-output "~s" (mapcar 'second (chunk-decays 'g)))
)
  


(defun test-spacing-effect-4 ()
  "The example situation with a model that makes requests between references and has two chunks with the same histories"
  (clear-all)
  (define-model foo
      (sgp :esc t :eblse t :v t :se-intercept 0.177 :se-scale .217 :lf 0 :rt -10 :mp 10)
    (add-dm (a color blue) (b value green)(c color red)(d value blue))
    (declare-buffer-usage imaginal visual-location :all)
    (p p1 
       ?goal>
       buffer empty
       ==>
       +goal>
       value 1
       +retrieval>
       color blue)
    (p p2
       =goal>
       value 1
       =retrieval>
       ?imaginal>
       buffer empty
       state free
       ==>
       =retrieval>
       +imaginal>
       value green)
    (p p3
       =goal>
       value 1
       =retrieval>
       =imaginal>
       ==>
       =goal>
       value 2)
    (spp p3 :at 125.7)
    
    (p p4
       =goal>
       value 2
       ?retrieval>
       buffer empty
       state free
       ==>
       +retrieval>
       color blue)
    (spp p4 :at 10)
    (p p5
       =goal>
       value 2
       =retrieval>
       ?imaginal>
       state free
       buffer empty
       ==>
       =retrieval>
       +imaginal>
       value green)
    (p p6
       =goal>
       value 2
       =retrieval>
       =imaginal>
       ==>
       =goal>
       value 3)
    (spp p6 :at 115.75)
    
    
    
    (p p7
       =goal>
       value 3
       ?retrieval>
       buffer empty
       state free
       ==>
       +retrieval>
       color blue)
    (spp p7 :at 1000)
    (p p8
       =goal>
       value 3
       =retrieval>
       ?imaginal>
       state free
       buffer empty
       ==>
       =retrieval>
       +imaginal>
       value green)
    (p p9
       =goal>
       value 3
       =retrieval>
       =imaginal>
       ==>
       =goal>
       value 4)
    (spp p9 :at 3591.75)
    (p p10
       =goal>
       value 4
       ?retrieval>
       buffer empty
       state free
       ==>
       +retrieval>
       color red)
    (spp p10 :at 500)
    (p p11
       =goal>
       value 4
       =retrieval>
       ==>
       =goal>
       value 5))
    
  (run-until-time 5877)
    
  (sdp)
  (model-output "chunk a: ~s~%chunk b: ~s~%chunk c: ~s~%chunk d: ~s~%"
                (mapcar 'second (chunk-decays 'a))
                (mapcar 'second (chunk-decays 'b))
                (mapcar 'second (chunk-decays 'c))
                (mapcar 'second (chunk-decays 'd))))


  
  
#|
CG-USER(130): (test-spacing-effect-1)
     0.000   PROCEDURAL             CONFLICT-RESOLUTION
   126.000   ------                 Stopped because time limit reached
Computing activation for chunk G
Computing base-level
base-level hook returns: -0.8560219
Adding transient noise 0.0
Adding permanent noise 0.0
Chunk G has an activation of: -0.8560219
   252.000   ------                 Stopped because time limit reached
Computing activation for chunk G
Computing base-level
base-level hook returns: -0.43415272
Adding transient noise 0.0
Adding permanent noise 0.0
Chunk G has an activation of: -0.43415272
  4844.000   ------                 Stopped because time limit reached
Computing activation for chunk G
Computing base-level
base-level hook returns: -0.9314301
Adding transient noise 0.0
Adding permanent noise 0.0
Chunk G has an activation of: -0.9314301
  5877.000   ------                 Stopped because time limit reached
Computing activation for chunk G
Computing base-level
base-level hook returns: -0.61873615
Adding transient noise 0.0
Adding permanent noise 0.0
Chunk G has an activation of: -0.61873615
(0.26249582 0.31757548 0.2691922 0.177)
CG-USER(131): (test-spacing-effect-2)
     0.000   PROCEDURAL             CONFLICT-RESOLUTION 
  5877.000   PROCEDURAL             CONFLICT-RESOLUTION 
  5877.000   ------                 Stopped because time limit reached 
Computing activation for chunk G
Computing base-level
base-level hook returns: -0.61873615
Adding transient noise 0.0
Adding permanent noise 0.0
Chunk G has an activation of: -0.61873615

(0.26249582 0.31757548 0.2691922 0.177)

CG-USER(140): (test-spacing-effect-3)
     0.000   PROCEDURAL             CONFLICT-RESOLUTION
  5877.000   ------                 Stopped because time limit reached
Computing activation for chunk G
Computing base-level
Starting with blc: 0.0
Computing base-level from 4 references (4844.000 252.000 126.000 0.000)
  creation time: 0.000 decay: 0.5  Optimized-learning: NIL
base-level value: -2.649625
Total base-level: -2.649625
Adding transient noise 0.0
Adding permanent noise 0.0
Chunk G has an activation of: -2.649625
     0.000   PROCEDURAL             CONFLICT-RESOLUTION
  5877.000   ------                 Stopped because time limit reached
Computing activation for chunk G
Computing base-level
base-level hook returns: -2.649625
Adding transient noise 0.0
Adding permanent noise 0.0
Chunk G has an activation of: -2.649625
(0.5 0.5 0.5 0.5)

CG-USER(17): (test-spacing-effect-4)
     0.000   PROCEDURAL             CONFLICT-RESOLUTION
     0.050   PROCEDURAL             PRODUCTION-FIRED P1
     0.050   PROCEDURAL             CLEAR-BUFFER GOAL
     0.050   PROCEDURAL             CLEAR-BUFFER RETRIEVAL
     0.050   GOAL                   SET-BUFFER-CHUNK-FROM-SPEC GOAL 
     0.050   DECLARATIVE            start-retrieval
     0.050   DECLARATIVE            RETRIEVED-CHUNK A
     0.050   DECLARATIVE            SET-BUFFER-CHUNK RETRIEVAL A
     0.050   PROCEDURAL             CONFLICT-RESOLUTION
     0.100   PROCEDURAL             PRODUCTION-FIRED P2
     0.100   PROCEDURAL             CLEAR-BUFFER IMAGINAL
     0.100   PROCEDURAL             CONFLICT-RESOLUTION
     0.300   IMAGINAL               SET-BUFFER-CHUNK-FROM-SPEC IMAGINAL 
     0.300   PROCEDURAL             CONFLICT-RESOLUTION
   126.000   PROCEDURAL             PRODUCTION-FIRED P3
   126.000   PROCEDURAL             CLEAR-BUFFER RETRIEVAL
   126.000   PROCEDURAL             CLEAR-BUFFER IMAGINAL
   126.000   PROCEDURAL             CONFLICT-RESOLUTION
   136.000   PROCEDURAL             PRODUCTION-FIRED P4
   136.000   PROCEDURAL             CLEAR-BUFFER RETRIEVAL
   136.000   DECLARATIVE            start-retrieval
   136.000   DECLARATIVE            RETRIEVED-CHUNK A
   136.000   DECLARATIVE            SET-BUFFER-CHUNK RETRIEVAL A
   136.000   PROCEDURAL             CONFLICT-RESOLUTION
   136.050   PROCEDURAL             PRODUCTION-FIRED P5
   136.050   PROCEDURAL             CLEAR-BUFFER IMAGINAL
   136.050   PROCEDURAL             CONFLICT-RESOLUTION
   136.250   IMAGINAL               SET-BUFFER-CHUNK-FROM-SPEC IMAGINAL 
   136.250   PROCEDURAL             CONFLICT-RESOLUTION
   252.000   PROCEDURAL             PRODUCTION-FIRED P6
   252.000   PROCEDURAL             CLEAR-BUFFER RETRIEVAL
   252.000   PROCEDURAL             CLEAR-BUFFER IMAGINAL
   252.000   PROCEDURAL             CONFLICT-RESOLUTION
  1252.000   PROCEDURAL             PRODUCTION-FIRED P7
  1252.000   PROCEDURAL             CLEAR-BUFFER RETRIEVAL
  1252.000   DECLARATIVE            start-retrieval
  1252.000   DECLARATIVE            RETRIEVED-CHUNK A
  1252.000   DECLARATIVE            SET-BUFFER-CHUNK RETRIEVAL A
  1252.000   PROCEDURAL             CONFLICT-RESOLUTION
  1252.050   PROCEDURAL             PRODUCTION-FIRED P8
  1252.050   PROCEDURAL             CLEAR-BUFFER IMAGINAL
  1252.050   PROCEDURAL             CONFLICT-RESOLUTION
  1252.250   IMAGINAL               SET-BUFFER-CHUNK-FROM-SPEC IMAGINAL 
  1252.250   PROCEDURAL             CONFLICT-RESOLUTION
  4844.000   PROCEDURAL             PRODUCTION-FIRED P9
  4844.000   PROCEDURAL             CLEAR-BUFFER RETRIEVAL
  4844.000   PROCEDURAL             CLEAR-BUFFER IMAGINAL
  4844.000   PROCEDURAL             CONFLICT-RESOLUTION
  5344.000   PROCEDURAL             PRODUCTION-FIRED P10
  5344.000   PROCEDURAL             CLEAR-BUFFER RETRIEVAL
  5344.000   DECLARATIVE            start-retrieval
  5344.000   DECLARATIVE            RETRIEVED-CHUNK C
  5344.000   DECLARATIVE            SET-BUFFER-CHUNK RETRIEVAL C
  5344.000   PROCEDURAL             CONFLICT-RESOLUTION
  5344.050   PROCEDURAL             PRODUCTION-FIRED P11
  5344.050   PROCEDURAL             CLEAR-BUFFER RETRIEVAL
  5344.050   PROCEDURAL             CONFLICT-RESOLUTION
  5877.000   ------                 Stopped because time limit reached
Declarative parameters for chunk D:
 :Activation -1.536
 :Permanent-Noise  0.000
 :Base-Level -1.536
 :Creation-Time 0.000
 :Reference-List (0.000)
 :Similarities ((D 0.0))
Declarative parameters for chunk B:
 :Activation -0.619
 :Permanent-Noise  0.000
 :Base-Level -0.619
 :Creation-Time 0.000
 :Reference-List (4844.000 252.000 126.000 0.000)
 :Similarities ((B 0.0))
Declarative parameters for chunk C:
 :Activation -0.778
 :Permanent-Noise  0.000
 :Base-Level -0.778
 :Creation-Time 0.000
 :Reference-List (5344.050 0.000)
 :Similarities ((C 0.0))
 :Last-Retrieval-Activation -1.519
 :Last-Retrieval-Time 5344.000
Declarative parameters for chunk A:
 :Activation -0.619
 :Permanent-Noise  0.000
 :Base-Level -0.619
 :Creation-Time 0.000
 :Reference-List (4844.000 252.000 126.000 0.000)
 :Similarities ((A 0.0))
 :Last-Retrieval-Activation -10.543
 :Last-Retrieval-Time 5344.000
chunk a: (0.26249582 0.31757548 0.2691922 0.177)
chunk b: (0.26249582 0.31757548 0.2691922 0.177)
chunk c: (0.22449267 0.177)
chunk d: (0.177)

|#


(provide "spacing-effect")

                         
#|
This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
|#
