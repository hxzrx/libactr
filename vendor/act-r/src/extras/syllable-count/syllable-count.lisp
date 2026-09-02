;;;  -*- mode: LISP; Syntax: COMMON-LISP;  Base: 10 -*-
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 
;;; Author      : Dan Bothell
;;; Copyright   : (c) 2025 Dan Bothell
;;; Availability: Covered by the GNU LGPL, see LGPL.txt
;;; Address     : Department of Psychology 
;;;             : Carnegie Mellon University
;;;             : Pittsburgh, PA 15213-3890
;;;             : db30@andrew.cmu.edu
;;; 
;;; 
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 
;;; Filename    : syllable-count.lisp
;;; Version     : 1.0a1
;;; 
;;; Description : Add a table of real syllable counts to use with the speech
;;;             : module's get-articulation-time.
;;; 
;;; Bugs        : 
;;;
;;; To do       : 
;;; 
;;; ----- History -----
;;; 2025.03.03 Dan
;;;             : * Initial creation.
;;; 2025.05.16 Dan
;;;             : * Moved the defstruct to the top to avoid warnings in SBCL.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; General Docs:
;;; 
;;; Improves the timing of speech acts by using actual syllable counts from
;;; a dictionary of English words instead of just counting the length of a 
;;; model's speech string and dividing it by :char-per-syllable.
;;;
;;; The timing is now determined as follows:
;;;
;;;  If register-articulation-time was used to specify a time for the string
;;;  then use that time (as before).
;;;
;;;  Otherwise it is :syllable-rate times the number of syllables for the word
;;;  in the string.
;;;  
;;;  If the word is found in the table of ~117k words, use that syllable
;;;  count, and if not then use the default calculation of string length divided
;;;  by :char-per-syllable.
;;;     
;;; Additionally, there is the option to split the string at spaces into 
;;; separate words.  If enabled, then the string will be segmented at spaces to
;;; form separate words, and each word will have its time computed separately.
;;; The total time will then be the sum of the times for each word plus an
;;; additional syllable for each word break (sequence of spaces) between the 
;;; words times the syllable rate.
;;;
;;; The dictionary that was used to get the counts is the CMU Pronouncing
;;; Dictionary.  The licence file is in the syllable-count directory and the
;;; software is avaiable from: 
;;; http://www.speech.cs.cmu.edu/cgi-bin/cmudict
;;; or 
;;; https://github.com/Alexir/CMUdict
;;;
;;; The specific dictionary file used was downloaded from here:
;;; http://svn.code.sf.net/p/cmusphinx/code/trunk/cmudict/cmudict-0.7b
;;; and the parse-cmudict-for-syllables.lisp file was used to generate the file
;;; with syllable counts that creates the lookup table.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Public API:
;;;
;;; Two new parameters:
;;; 
;;; :use-syllable-table 
;;;    If set to t (the default) then use the syllable count from the dictionary
;;;    instead of just char-per-syllable to compute the duration of the text.
;;;    
;;; :split-vocal-strings 
;;;    If set to t (the default is nil) then split the string into separate 
;;;    words at spaces (multiple sequential spaces are considered as a single
;;;    separator).  Then, the duration will be computed using the sum of the 
;;;    syllable counts for each word plus one for each word break.
;;;
;;; The function register-syllable-count which is also available remotely as 
;;; "register-syllable-count".
;;;
;;; register-syllable-count takes two parameters:
;;;   word - a string which specifies a word (which is not case sensitive)
;;;   syllables - an integer indicating how many syllables that word has
;;;
;;;  This will add or replace the current setting for that word in the syllable
;;;  lookup table.   The lookup table is a global resource, and not specific to
;;;  any model -- changing it will affect all models.
;;;  It returns the word if the table was successfully updated or nil if there
;;;  was an invalid parameter provided.
;;;
;;; get-syllable-count takes two parameters:
;;;   word - a string which specifies a word (which is not case sensitive)
;;; 
;;;  This will return the number of syllables for that word if it is in the 
;;;  lookup table or nil if it is not in the table or not a valid word.
;;; 
;;;  remove-syllable-count takes one parameters:
;;;    word - a string which specifies a word (which is not case sensitive)
;;; 
;;;  This will remove the setting for that word in the syllable lookup table.
;;;  The lookup table is a global resource, and not specific to any model -- 
;;;  changing it will affect all models (unlike register-articulation-time).
;;; 
;;;  It returns the word if it was successfully removed from the table or nil
;;;  if there was an invalid parameter provided or the word was not in the table.
;;; 
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Design Choices:
;;; 
;;; Create the hash-table as a global at load/require time and use an arround
;;; method for get-art-time to add the use the new calculation when set.
;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 
;;; The code
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

#+:packaged-actr (in-package :act-r)
#+(and :clean-actr (not :packaged-actr) :ALLEGRO-IDE) (in-package :cg-user)
#-(or (not :clean-actr) :packaged-actr :ALLEGRO-IDE) (in-package :cl-user)


(defstruct speech-extension split table (lock (bt:make-recursive-lock)))

(defvar *syllable-count-table*
    (let ((ht (make-hash-table :test 'equalp))
          (counts (with-open-file (f (translate-logical-pathname "ACT-R:extras;syllable-count;counts.lisp") :direction :input)
                    (read f))))
      (dolist (x counts ht)
        (setf (gethash (car x) ht) (cdr x)))))

(defvar *syllable-table-lock* (bt:make-recursive-lock))

(defun split-speech-string (string)
  (do* ((str string (subseq str (1+ pos)))
        (pos (position #\space string) (position #\space str))
        (l (list (subseq str 0 pos)) (nconc l (list (subseq str 0 pos)))))
       ((null pos) (remove "" l :test 'string=))))

(defmethod get-art-time :around ((spch-mod speech-module) (text string) &optional time-in-ms)
  (let* ((basic-time (call-next-method))
         (time
          (if (gethash text (art-time-ht spch-mod)) ;; always use the user's value
              basic-time
            ;; if the module doesn't exist for some reason don't print the
            ;; warning and just let it fall back to the basic-time
            (let ((ext-mod (suppress-warnings (get-module :speech-extension))))
              (when ext-mod 
                (bt:with-recursive-lock-held ((speech-extension-lock ext-mod))
                  (when (or (speech-extension-split ext-mod)
                            (speech-extension-table ext-mod))
                    (bt:with-recursive-lock-held (*syllable-table-lock*)
                      (let* ((words (if (speech-extension-split ext-mod)
                                        (split-speech-string text)
                                      (list text))))
                        (if (= (length words) 1)
                            (awhen (and (speech-extension-table ext-mod)
                                        (gethash (car words) *syllable-count-table*))
                                   (* it (s-rate spch-mod)))
                          
                          (+ (* (s-rate spch-mod) (1- (length words))) ;; the spaces between
                             
                             ;; the times for the individual words
                             (reduce '+
                                     (mapcar (lambda (x)
                                               (get-art-time spch-mod x t))
                                       words)))))))))))))
    (if time 
        (if time-in-ms
            time
          (ms->seconds time))
      basic-time)))


(defun register-syllable-count (string syllables)
  (if (not (stringp string))
      (print-warning "Register-syllable-count passed a non-string word: ~s" string)
    (if (not (and (integerp syllables) (> syllables 0)))
        (print-warning "Register-syllable-count passed an invalid number of syllables: ~s" syllables)
      (bt:with-recursive-lock-held (*syllable-table-lock*)
        (setf (gethash string *syllable-count-table*) syllables)
        string))))

(add-act-r-command "register-syllable-count" 'register-syllable-count "Add the syllable count for a word to the lookup table used when :use-syllable-table is true. Params: word syllables")


(defun get-syllable-count (string)
  (if (not (stringp string))
      (print-warning "Get-syllable-count passed a non-string word: ~s" string)
    (bt:with-recursive-lock-held (*syllable-table-lock*)
      ; just want the result
      (values (gethash string *syllable-count-table*)))))

(add-act-r-command "get-syllable-count" 'get-syllable-count "Return the syllable count for a word in the lookup table. Params: word")


(defun remove-syllable-count (string)
  (if (not (stringp string))
      (print-warning "Remove-syllable-count passed a non-string word: ~s" string)
    (bt:with-recursive-lock-held (*syllable-table-lock*)
      (when (remhash string *syllable-count-table*)
        string))))

(add-act-r-command "remove-syllable-count" 'remove-syllable-count "Remove the syllable count for a word in the lookup table used when :use-syllable-table is true. Params: word")


(defun make-speech-extension-module (name)
  (declare (ignore name))
  (make-speech-extension))

(defun speech-extension-params (module param)
  (bt:with-recursive-lock-held ((speech-extension-lock module))
    (if (consp param)
        (case (car param)
          (:split-vocal-strings
           (setf (speech-extension-split module) (cdr param)))
          (:use-syllable-table
           (setf (speech-extension-table module) (cdr param))))
      (case param
        (:split-vocal-strings
           (speech-extension-split module))
        (:use-syllable-table
           (speech-extension-table module))))))

(define-module-fct :speech-extension nil
  (list (define-parameter :split-vocal-strings 
          :valid-test 'tornil :default-value nil :warning "t or nil"
          :documentation "Treat a vocal request string as a single word or split into words at spaces.")
        (define-parameter :use-syllable-table 
          :valid-test 'tornil :default-value t :warning "t or nil"
          :documentation "Use a dictionary to get a word's syllable count or just use :char-per-syllable."))
  :creation 'make-speech-extension-module
  :params 'speech-extension-params
  :required '(:audio :speech)
  :version "1.0a1"
  :documentation "Adds a table of English word syllable counts and the option of splitting a vocal/aural string into separate words.")


(provide "syllable-count")
    
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
