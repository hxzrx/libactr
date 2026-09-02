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
;;; Filename    : parse-cmudict-for-syllables.lisp
;;; Version     : 1.0
;;; 
;;; Description : Get syllable counts for words from the cmudict file.
;;; 
;;; Bugs        : 
;;;
;;; To do       : 
;;; 
;;; ----- History -----
;;; 2025.04.22 Dan 
;;;             : * Be safer about parsing the file because there are non-ASCII
;;;             :   characters in the dictionary file that won't be read by the
;;;             :   default encoding in some Lisps.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; General Docs:
;;; 
;;; Parses the cmudict-0.7b file that's included in the .zip to get syllable
;;; counts from the pronunciations and write out the counts.lisp file with the
;;; results.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Public API:
;;;
;;; None.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Design Choices:
;;; 
;;; Only use the all alphanumeric words and the first pronunciation when there
;;; is more than one.
;;;
;;; For ACL and LW skip words that have non-ASCII characters and for SBCL use  
;;; :utf-8 encoding with a replacement character (as shown in the SBCL manual).
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 
;;; The code
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

#+:packaged-actr (in-package :act-r)
#+(and :clean-actr (not :packaged-actr) :ALLEGRO-IDE) (in-package :cg-user)
#-(or (not :clean-actr) :packaged-actr :ALLEGRO-IDE) (in-package :cl-user)

(defun parse-dict-file ()
  (let (items)
    (with-open-file (f (translate-logical-pathname "ACT-R:extras;syllable-count;cmudict-0.7b") 
                       :direction :input :external-format (if (find :sbcl *features*) '(:utf-8 :replacement #\*) :default))
      (loop
        (let ((l (read-line f nil :done)))
          (when (eq l :done)
            (return))
          (unless (string= ";;;" (subseq l 0 3)) ;; skip the comments
            (let* ((word-end (position #\space l))
                   (word (subseq l 0 word-end))
                   (rest (subseq l word-end)))
              
              ;; Skipping anything with symbols in it, and
              ;; just taking the first pronunciation when
              ;; there are multiple ones (which happens automatically 
              ;; due to the skipping of symbols).
              
              (when (and (every 'alphanumericp word) (if (or (find :ALLEGRO *features*) 
                                                             (find :LISPWORKS *features*)) 
                                                         (every (lambda (x) (< (char-code x) 128)) word)
                                                       t))
                (push-last (cons word (count-if 'digit-char-p rest))
                           items)))))))
    (with-open-file (f (translate-logical-pathname "ACT-R:extras;syllable-count;counts.lisp") :direction :output :if-does-not-exist :create)
      (write items :stream f))))



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
