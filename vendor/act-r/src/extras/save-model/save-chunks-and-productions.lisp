;;;  -*- mode: LISP; Syntax: COMMON-LISP;  Base: 10 -*-
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 
;;; Author      : Dan Bothell
;;; Copyright   : (c) 2010 Dan Bothell
;;; Availability: Covered by the GNU LGPL, see LGPL.txt
;;; Address     : Department of Psychology 
;;;             : Carnegie Mellon University
;;;             : Pittsburgh, PA 15213-3890
;;;             : db30@andrew.cmu.edu
;;; 
;;; 
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 
;;; Filename    : save-chunks-and-productions.lisp
;;; Version     : 4.0a1
;;; 
;;; Description : Saves a model's declarative and procedural components to a file
;;;             : which can be loaded later as a model.
;;; 
;;; Bugs        : 
;;;
;;; To do       : 
;;; 
;;; ----- History -----
;;; 2010.06.11 Dan
;;;             : * First pass at a version of this for inclusion with the sources.
;;; 2013.05.31 Dan [1.0a2]
;;;             : * Adding support for static chunk-types.  For now it's just 
;;;             :   going to write out the entire subtree for a static instead
;;;             :   of trying to figure out which were user defined and which
;;;             :   were automatic.
;;;             : * Realized that the sort based on subtype status isn't right
;;;             :   since it doesn't work for unrelated types because sort may
;;;             :   not test every pair together.
;;; 2014.06.17 Dan [2.0a1]
;;;             : * Update to work with the typeless chunk mechanisms.
;;; 2014.06.26 Dan
;;;             : * More fixes to work right with the new chunk mechanism.
;;;             : * Actually create and write out a setting for any chunks that
;;;             :   are in buffers now.
;;; 2015.03.23 Dan [3.0a1]
;;;             : * Create the default chunk-type list at load time in the context
;;;             :   of a dummy meta-process so that it has the possibility of
;;;             :   working to save a model in a multi-model situation within a
;;;             :   with-model.
;;;             : * Since I've got a dummy model at that point set the critical
;;;             :   parameter default values based on that model instead of to
;;;             :   fixed values.
;;;             : * Remove some of the ACT-R 6.1 specific code that dealt with
;;;             :   backwards compatibility.
;;;             : * Save chunk-type slot default values if they exist.
;;; 2015.03.24 Dan
;;;             : * Fixed a bug in the *default-chunk-type* definition for
;;;             :   how it was setting the *critical-params*.
;;; 2018.03.27 Dan
;;;             : * Updated to work with 7.x, but without any extra safety 
;;;             :   code (not running, locking output, etc.).
;;; 2018.03.28 Dan
;;;             : * Also create any non-dm chunks which aren't "default" chunks.
;;;             :   To make that work, define all the chunks, then use add-chunk-
;;;             :   into-dm to add them to dm.  That's not the 'right' way to
;;;             :   do things since that's not a documented function but for now
;;;             :   it's the right way to handle things.
;;; 2018.08.24  Dan
;;;             : * Use the new user command add-dm-chunks instead of the internal
;;;             :   add-chunk-into-dm.
;;; 2019.03.21 Dan [3.1a]
;;;             : * Updating because of changes in the internal representations of
;;;             :   chunks and chunk-types.
;;; 2021.10.18 Dan
;;;             : * Changed call to buffers to model-buffers instead.
;;; 2023.02.16 Dan [4.0a1]
;;;             : * Leave save-chunks-and-productions to work as before for
;;;             :   backwards compatibility, but add a new function called 
;;;             :   save-model-file that is possibly more useful:
;;;             :   - Use keyword parameters instead of optional since there are
;;;             :     more than one now.
;;;             :   - Add a parameter to control whether the seed is commented
;;;             :     or not.
;;;             :   - Add four parameters to provide hooks to write additional 
;;;             :     information into the model file: after the seed before
;;;             :     the chunk-types, after the chunk-types and before chunks,
;;;             :     after the chunks and before productions, after the 
;;;             :     productions.
;;;             :   - Add a parameter to indicate buffers for which the current
;;;             :     chunk should not be restored (it will still be created as
;;;             :     a chunk in the model).
;;; 2023.06.29 Dan
;;;             : * Use translate-logical-pathname explicitly on the file names
;;;             :   provided to save because if it's done 'automatically' with
;;;             :   the opening of the file with :supersede it may not work 
;;;             :   correctly in SBCL.
;;; 2024.05.17 Dan
;;;             : * Sort the chunk and buffer-name lists so that the model is
;;;             :   consistent between Lisps.
;;; 2024.08.22 Dan
;;;             : * Added another keyword parameter to save-model-file called
;;;             :   skip-clear-all which if true will not put a clear-all call
;;;             :   at the top of the file.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; General Docs:
;;; 
;;; Add a new command which allows a model's current declarative memory, set of
;;; productions, general parameters related to declarative and procedural, the
;;; appropriate chunk and proceduction parameters, and all the chunks currently
;;; in buffers to be written out to a model file.
;;; 
;;; That does not capture all of the current state because it does not record 
;;; internal information from any module (nothing from the perceptual or motor 
;;; modules is recorded nor are things like finsts in declarative), events 
;;; currently on the meta-process queue are not saved in any way, nor are any 
;;; extra commands or settings which are in the original model (other than sgp 
;;; settings for some declarative and procedural settings).  
;;; 
;;; So the assumptions are that the model is "stopped" (no ongoing actions) before 
;;; saving the state and it's up to the modeler to then add any other settings 
;;; or commands which are also needed for the model to run.
;;; 
;;; In terms of declarative parameters there is one exception worth noting as
;;; to what is saved -- the Sji values are not written out.  That is because
;;; the assumption is that they are dynamic based on the fans of the items.  Thus,
;;; when the new model is loaded it will restore those automatically and they
;;; will continue to change as new chunks are added to DM.  However, if they had
;;; been written out as explicit parameter settings then those values would be
;;; fixed and the chunks would no longer adapt as new chunks were added to DM.
;;; If explicit values are set in the model those would have to be manually
;;; added to the saved model file.
;;;
;;; 
;;; Here's a list of the general parameters which are written out if the current
;;; value differs from the default value: 
#|

DECLARATIVE module
--------
:MD     
:RT     
:LE     
:MS     
:MP     
:PAS    
:MAS    
:ANS    
:BLC    
:LF     
:BLL    
--------------------------------
CENTRAL-PARAMETERS module
--------------------------------
:ESC    
:ER     
:OL     
--------------------------------
UTILITY module
--------------------------------
:IU     
:UL     
:ALPHA  
:UT     
:NU     
:EGS    
--------------------------------
PRODUCTION-COMPILATION module
--------------------------------
:EPL    
:TT     
--------------------------------
PROCEDURAL module
-------------------------------
:DAT    
:PPM    
|#

;;; It will also write out the current :seed parameter in a comment so that it
;;; could be used to reproduce the same "future" after the save point as the 
;;; model which was saved i.e. if you run a model, save it, then run it some more
;;; uncommenting the seed in the saved version then loading that and running it
;;; will produce the same results as if you had continued to run it instead of
;;; saving (assuming that there is no other state that matters like pending actions
;;; already on the event queue, internal state of modules like previously prepared
;;; motor features or recorded finsts, and the task/environment is also consistent
;;; and deterministic when re-run from the saved starting point).
;;; 
;;; The appropriate declarative parameters among the following will be written out based 
;;; on the :mp, :bll, and :ol settings using sdp:
;;; 
;;; :creation-time
;;; :reference-count
;;; :reference-list
;;; :similarities
;;; 
;;; When writing out the creation-time and reference-list the times will be
;;; adjusted to a zero reference since the model time will be back to 0 when
;;; reloaded.  If one wants to avoid the re-referencing of those times then
;;; the optional parameter to save-chunks-and-productions needs to be specified
;;; as nil.
;;; 
;;; For productions the :u and :at values will always be written out.  A non-nil 
;;; :reward will be saved if utility learning is enabled.  If production 
;;; compilation is enabled then an additional production parameter which is not
;;; part of spp will be set to indicate which productions were learned.  The
;;; reason for that last setting is because the utility learning differs for
;;; productions which were "original" vs learned and without the setting all
;;; the productions loaded would be marked as originals.
;;; 
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Public API:
;;;
;;; save-chunks-and-productions
;;;
;;; (defun save-chunks-and-productions (file-name &optional (zero-ref t))
;;;
;;; This function takes one required parameter which is a string that names
;;; a file to create and write the saved model definition to.  If the optional
;;; parameter is specified as nil then the current reference times for the
;;; declarative parameters are written out exactly as they are.  If it is not
;;; provided or has any non-nil value then those times will be adjusted so that
;;; they correspond to a current time of 0.0s (the default time when the model
;;; is later loaded).
;;;
;;; The save-chunks-and-productions function is included for backward
;;; compatibility, but it is depricated and the new (as of v4.0a1) save-model-file
;;; function should be used instead.
;;;
;;;
;;;
;;; save-model-file
;;; 
;;; (defun save-model-file (file-name &key (zero-ref t)
;;;                                   (comment-seed t)
;;;                                   skip-clear-all
;;;                                   skip-buffers
;;;                                   pre-chunk-type-hook
;;;                                   pre-chunk-hook
;;;                                   pre-production-hook
;;;                                   end-hook)
;;;
;;; The save-model-file writes out the model file in the same way as the
;;; save-chunks-and-productions function described above, but with some more
;;; options to adjust what gets written.
;;;
;;; The comment-seed parameter can be used to control whether the setting of the 
;;; :seed parameter written to the file is commented out or not.  The default
;;; is t (comment the setting).
;;;
;;; The skip-clear-all parameter is a generalized boolean that controls whether
;;; a call to clear-all is written to the top of the saved file.  If it is nil
;;; (the default) then the clear-all will be written.  Any other value will 
;;; result in no clear-all call at the top of the file.
;;;
;;; The skip-buffers parameter can be specified as a list of buffer names, and
;;; any buffer in that list will not have a line in the model to set its content
;;; if it had any at the time of saving.  Note however that if there was a chunk
;;; in the buffer that chunk will still be created in the model since it could
;;; be referenced elsewhere.
;;;
;;; The four hook parameters can be used to write additional code into the model
;;; definition at the points indicated by the hook's name.  The parameters can
;;; be specified as any valid command identifier and should output the code
;;; using the command-output command so that it is written into the file 
;;; appropriately.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Design Choices:
;;; 
;;; Only writing out those things that are "publically" accessible.  Not going
;;; deep into any module or looking at model components which aren't part of the
;;; declarative and procedural systems.
;;;
;;; This should capture most of what people are looking for in a "save model"
;;; type action.  Of course it's probably also lacking in something for anyone
;;; that wants to use it.  Hopefully the new hooks to write additional code into
;;; the file will help with that.
;;; 
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 
;;; The code
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

#+:packaged-actr (in-package :act-r)
#+(and :clean-actr (not :packaged-actr) :ALLEGRO-IDE) (in-package :cg-user)
#-(or (not :clean-actr) :packaged-actr :ALLEGRO-IDE) (in-package :cl-user)

(defvar *critical-params* '(:MD :RT :LE :MS :MP :PAS :MAS :ANS :BLC :LF 
                            :BLL :ESC :ER :OL :IU :UL :ALPHA :UT :NU 
                            :EGS :EPL :TT :DAT :PPM))

(defvar *default-chunk-types*
    (let ((name (do ((n (new-symbol "dummy") (new-symbol "dummy")))
                    ((not (find n (mp-models))) n))))
      (prog2
        (define-model-fct name nil)
          (with-model-eval name
            (setf *critical-params*
              (mapcar (lambda (x) (list x (car (no-output (sgp-fct (list x)))))) *critical-params*))
            (all-chunk-type-names))
        (delete-model-fct name))))

(defvar *default-chunks*
    (let ((name (do ((n (new-symbol "dummy") (new-symbol "dummy")))
                    ((not (find n (mp-models))) n))))
      (prog2
        (define-model-fct name nil)
          (with-model-eval name
            (chunks))
        (delete-model-fct name))))

(defun pprint-save-chunk (chunk-name)
  (let ((chunk (get-chunk chunk-name)))
    (when chunk
      (command-output
       (format nil "  (~S~%~@[~S~%~]    ISA CHUNK~%~{~{     ~s  ~s~}~^~%~})"
         chunk-name
         (act-r-chunk-documentation chunk)
         (mapcar (lambda (slot) 
                   (list (act-r-slot-name (car slot)) (cdr slot)))
           (sort (copy-tree (act-r-chunk-slot-value-lists chunk)) #'< :key (lambda (x) (act-r-slot-index (car x))))))))))
    
(defun save-chunks-and-productions (file-name &optional (zero-ref t))
  (save-model-file file-name :zero-ref zero-ref))
  
(defun save-model-file (file-name &key (zero-ref t)
                                  (comment-seed t)
                                  skip-clear-all
                                  skip-buffers
                                  pre-chunk-type-hook
                                  pre-chunk-hook
                                  pre-production-hook
                                  end-hook)
  
  (let* ((dm-chunks (sort (no-output (dm)) 'string< :key 'symbol-name))
         (other-chunks (sort (set-difference (set-difference (chunks) *default-chunks*) dm-chunks)'string< :key 'symbol-name))
         (productions (no-output (pp)))
         (cmdt (car (no-output (sgp :cmdt)))))
    
    (unwind-protect 
        (progn
          
          ;;; Use the command trace to write things out since it will 
          ;;; handle the opening of the file and pprint-chunks and pp will then work
          ;;; "automatically".
          
          (sgp-fct (list :cmdt (translate-logical-pathname file-name)))
          
          ;;; Write out a comment indicating what and when
          
          (multiple-value-bind (sec min hour date month year) (get-decoded-time)
            (command-output ";;; Saved version of model ~s at run time ~f on ~d/~d/~d ~d:~2,'0d:~2,'0d"
                            (current-model) (mp-time) year month date hour min sec))
          
          ;;; add a clear-all if not being skipped
          
          (unless skip-clear-all
            (command-output "~%(clear-all)"))
          
          ;;; write this as a model so it could theoretically just be loaded
          
          (command-output "~%(define-model ~s-saved" (current-model))
          
          ;;; Start with the general parameters
          
          (command-output "~%(sgp ")
          
          (dolist (param *critical-params*)
            (unless (equalp (second param) (car (no-output (sgp-fct (list (first param))))))
              (command-output "~s ~s" (first param) (car (no-output (sgp-fct (list (first param))))))))
          
          (command-output ")")
          
          ;;; Write out the current seed 
          (if comment-seed
              (command-output "~%;;; (sgp :seed ~s)~%" (no-output (car (sgp :seed))))
            (command-output "~%(sgp :seed ~s)~%" (no-output (car (sgp :seed)))))
          
          (awhen pre-chunk-type-hook (dispatch-apply it))
          
          ;;; Determine which chunk-types are added in the model and write them
          ;;; out (the order from all-chunk-type-names is safe for any inherited types).
          ;;; Use the underlying chunk-type structure to make things easier.
          
          (let ((model-types (mapcar 'get-chunk-type (remove-if (lambda (x) (find x *default-chunk-types*)) (all-chunk-type-names)))))
            
            (dolist (ct model-types)
              (aif (act-r-chunk-type-parents ct)
                   (command-output "(chunk-type (~a ~{(:include ~a)~}) ~@[~s~]" (act-r-chunk-type-name ct) it (act-r-chunk-type-documentation ct))
                   (command-output "(chunk-type ~a ~@[~s~]" (act-r-chunk-type-name ct) (act-r-chunk-type-documentation ct)))
              
              (let* ((defaults (chunk-spec-slot-spec (act-r-chunk-type-initial-spec ct)))
                     (default-slot-names (mapcar 'second defaults)))
                
                (dolist (slot (act-r-chunk-type-slots ct))
                  (if (find slot default-slot-names)
                      (command-output "  (~s ~s)" slot (third (find slot defaults :key 'second)))
                    (command-output "  ~s" slot))))
              
              (command-output ")")))
          
          (awhen pre-chunk-hook (dispatch-apply it))
          
          ;; Now write out all of the chunks doing the non-dm chunks first, but 
          ;; either way probably will have issues...
          
          (command-output "(define-chunks ")
          
          (dolist (x (append other-chunks dm-chunks))
            (pprint-save-chunk x))
          
          (command-output ")")

          
          (command-output "(add-dm-chunks")
          
          (dolist (x dm-chunks)
            (command-output "   ~a" x))
          
          
          (command-output ")")
          (command-output "")
          
          ;;; If declarative options are enabled write out the necessary parameters
          
          (let ((esc (no-output (car (sgp :esc))))
                (mp (no-output (car (sgp :mp))))
                (bll (no-output (car (sgp :bll))))
                (ol (no-output (car (sgp :ol))))
                (params nil))
            
            (when (and esc (or mp bll))
              
              (when mp (push :similarities params))
              
              (cond ((null bll)
                     ;;; no extra params needed
                     )
                    ((null ol)
                     ;;; need creation and list
                     (push :reference-list params)
                     (push :creation-time params))
                    ((numberp ol)
                     (push :reference-list params)
                     (push :reference-count params)
                     (push :creation-time params))
                    (t ;;; :ol is t
                     (push :reference-count params)
                     (push :creation-time params)))
              
              (dolist (c dm-chunks)
                (command-output "(sdp ~a" c)
                (dolist (param params)
                  (let ((val (caar (no-output (sdp-fct (list c param))))))
                    (case param
                      (:similarities 
                       (command-output "  ~s (~{~s~})" param val))
                      (:creation-time
                       (command-output "  ~s ~f" param (if zero-ref (- val (mp-time)) val)))
                      (:reference-count
                       (command-output "  ~s ~d" param val))
                      (:reference-list
                       (command-output "  ~s (~{~F~^ ~})" param (if zero-ref (mapcar (lambda (x) (- x (mp-time))) val) val))))))
                (command-output ")"))))
          
          (command-output "")
          (command-output "")
          
          (awhen pre-production-hook (dispatch-apply it))
          
          ;; write out productions
          
          (pp)
      
          (command-output "")
          (command-output "")
      
          ;;; Write out the production parameters
      
          (let ((params (no-output (spp :name :u :at :reward)))
                (ul (car (no-output (sgp :ul)))))
        
            ;;; always :u and :at then :reward if utility learning is enabled
            
            (dolist (x params)
              (command-output "(spp ~a :u ~f :at ~f~@[ :reward ~s~])" (first x) (second x) (third x) (and ul (fourth x))))
            
            ;;; If utility learning and production compilation are on save which
            ;;; productions were learned along the way
            
            (when (and ul (car (no-output (sgp :epl))))
              (dolist (x productions)
                (unless (production-user-created x)
                  (command-output "(setf (production-user-created '~a) nil)" x)))))
          
          ;;; If there's a chunk in a buffer create that chunk and put it into
          ;;; the buffer, using goal-focus for the goal buffer.
          
          (dolist (buffer (sort (model-buffers) #'string< :key 'symbol-name))
            (unless (find buffer skip-buffers)
              (awhen (buffer-read buffer)
                   (command-output "")
                   (command-output "")
      
                   (if (eq buffer 'goal)
                       (command-output "(goal-focus ~s)" it)
                     (command-output "(set-buffer-chunk '~s '~s)" buffer it)))))
          
          (awhen end-hook (dispatch-apply it))
          
          ;;; write out the closing of the model
          
          (command-output ")"))
      
      ;;; set the command trace back to where it was
      
      (sgp-fct (list :cmdt cmdt)))))

(add-act-r-command "save-model-file" 'save-model-file 
                   "Write the current model's information into a file that can be loaded as a model. Params: file { < zero-ref, comment-seed, skip-buffers, pre-chunk-type-hook, pre-chunk-hook, pre-production-hook, end-hook > }.")
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
