;;;  -*- mode: LISP; Syntax: COMMON-LISP;  Base: 10 -*-
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 
;;; Author      : Dan Bothell
;;; Copyright   : (c) 2019 Dan Bothell
;;; Availability: Covered by the GNU LGPL, see LGPL.txt
;;; Address     : Department of Psychology 
;;;             : Carnegie Mellon University
;;;             : Pittsburgh, PA 15213-3890
;;;             : db30@andrew.cmu.edu
;;; 
;;; 
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 
;;; Filename    : single-threaded.lisp
;;; Version     : 4.0
;;; 
;;; Description : No-op all the quicklisp loaded package actions.
;;; 
;;; Bugs        : 
;;;
;;; To do       : 
;;; 
;;; ----- History -----
;;; 2019.04.09 Dan
;;;             : * Created this to provide a fast single threaded version.
;;; 2019.04.17 Dan
;;;             : * Didn't add the acquire/release-recursive-lock functions.
;;; 2019.05.29 Dan [2.0]
;;;             : * Actually define the packages and all the Quicklisp library
;;;             :   functions used in the code so I can skip Quicklisp for the
;;;             :   single-threaded version.
;;; 2019.05.30 Dan
;;;             : * Remove the jsown package and stub.
;;; 2019.11.12 Dan
;;;             : * The stubs for acquire-lock and acquire-recursive-lock need
;;;             :   to return t otherwise it looks like a failure.
;;; 2024.07.02 Dan [3.0]
;;;             : * Only create the stubs if the packages don't already exist
;;;             :   by checking for the package names (I'd prefer a feature
;;;             :   test, but usocket doesn't seem to have one and don't want
;;;             :   to use different mechanisms based on package).
;;; 2024.09.12 Dan [4.0]
;;;             : * To be safe with respect to loading quicklisp libraries 
;;;             :   always create the dummy package and rename the original
;;;             :   if it exists and restore it after.  Also rename the dummies
;;;             :   when done so that they can be switched back in when
;;;             :   require-extra is used.
;;;             : * If cl-json isn't loaded, then it needs to be better about
;;;             :   how it handles encoding/decoding so that the history tools
;;;             :   still work since they can still be used in a Lisp only 
;;;             :   mode.  So, just return the original Lisp from encoding and
;;;             :   similarly decoding does nothing to the data passed to it.
;;; 2024.09.18 Dan
;;;             : * Don't use split-sequence in usocket to avoid any potential
;;;             :   problems with it having been loaded on its own.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; General Docs:
;;; 
;;; Allows the ACT-R code to compile and run properly while ignoring all of the
;;; locking actions and other Quicklisp library code.  This of course means that
;;; the code is no longer thread safe.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Public API:
;;;
;;; None.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Design Choices:
;;; 
;;; [originally]
;;; Just make the lock based actions no-ops by redefining the functions and
;;; macros from the :bordeaux-threads package with dummies.
;;;
;;; Create dummy stubs for all the other functions referenced in the code.
;;;
;;; [4.0]
;;; 
;;; To be safer with the dummy packages define the functions as macros before
;;; loading the ACT-R code, and then rename them afterwards for use during
;;; require-extra.
;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 
;;; The code
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


#+:packaged-actr (in-package :act-r)
#+(and :clean-actr (not :packaged-actr) :ALLEGRO-IDE) (in-package :cg-user)
#-(or (not :clean-actr) :packaged-actr :ALLEGRO-IDE) (in-package :cl-user)


;; Make sure not to start the dispatcher

(pushnew :standalone *features*)

;; define the packages which would come from Quicklisp loads
;; if they don't already exist.


(eval-when (:compile-toplevel :load-toplevel :execute)
  (progn
    (if (find-package :bordeaux-threads)
        (unless (find :dummy-bordeaux *features*)
          (format t "~&Overriding the existing Bordeaux threads package while loading ACT-R.~%")
          (pushnew :restore-bordeaux *features*)
          (rename-package :bordeaux-threads :backup-bordeaux)
          (defpackage :bordeaux-threads
            (:nicknames :bt)
            (:use :cl)
            (:export
             :make-lock
             :with-lock-held
             :make-recursive-lock
             :with-recursive-lock-held
             :make-condition-variable
             :condition-notify
             :condition-wait
             :make-thread
             :threadp
             :thread-alive-p
             :destroy-thread
             :thread-yield
             :start-multiprocessing))
          (pushnew :dummy-bordeaux *features*))
      (progn
        (defpackage :bordeaux-threads
          (:nicknames :bt)
          (:use :cl)
          (:export
           :make-lock
           :with-lock-held
           :make-recursive-lock
           :with-recursive-lock-held
           :make-condition-variable
           :condition-notify
           :condition-wait
           :make-thread
           :threadp
           :thread-alive-p
           :destroy-thread
           :thread-yield
           :start-multiprocessing))
        (pushnew :dummy-bordeaux *features*)))))

  
(defmacro bordeaux-threads::with-lock-held ((place) &body body)
  (declare (ignore place))
  `(progn
     ,@body))

(defmacro bordeaux-threads::with-recursive-lock-held ((place &key timeout) &body body)
  (declare (ignore place timeout))
  `(progn
     ,@body))

(defmacro bordeaux-threads::make-lock (&optional x) (declare (ignore x)) nil)
(defmacro bordeaux-threads::make-recursive-lock (&optional x) (declare (ignore x)) nil)
(defmacro bordeaux-threads::make-condition-variable (&rest x) (declare (ignore x)) nil)
(defmacro bordeaux-threads::make-thread (&rest x) (declare (ignore x)) t)

(defmacro bordeaux-threads::condition-notify (&rest x) (declare (ignore x)) `(progn t))
(defmacro bordeaux-threads::condition-wait (&rest x) (declare (ignore x)) `(progn t))

(defmacro bordeaux-threads::threadp (&rest x) (declare (ignore x)) t)
(defmacro bordeaux-threads::thread-alive-p (&rest x) (declare (ignore x)) t)
(defmacro bordeaux-threads::destroy-thread (&rest x) (declare (ignore x)) `(progn t))
(defmacro bordeaux-threads::thread-yield (&rest x) (declare (ignore x)) `(progn t))
(defmacro bordeaux-threads::start-multiprocessing (&rest x) (declare (ignore x)) `(progn t))




(eval-when (:compile-toplevel :load-toplevel :execute)
  (progn
    (if (find-package :usocket)
        (unless (find :dummy-usocket *features*)
          (format t "~&Overriding the existing Usocket package while loading ACT-R.~%")
          (pushnew :restore-usocket *features*)
          (rename-package :usocket :backup-usocket)
          (defpackage :usocket
            (:use :cl)
            (:export 
             :socket-stream
             :socket-close
             :socket-listen
             :socket-accept
             :ip=))
          (pushnew :dummy-usocket *features*))
      (progn
        (defpackage :usocket
          (:use :cl)
          (:export 
           :socket-stream
           :socket-close
           :socket-listen
           :socket-accept
           :ip=))
        (pushnew :dummy-usocket *features*)))))

(defmacro usocket::socket-stream (&rest x) (declare (ignore x)) nil)
(defmacro usocket::socket-close (&rest x) (declare (ignore x)) t)
(defmacro usocket::socket-listen (&rest x) (declare (ignore x)) t)
(defmacro usocket::socket-accept (&rest x) (declare (ignore x)) t)
(defmacro usocket::ip= (&rest x) (declare (ignore x)) t)
    
(defmacro usocket::get-peer-port (&rest x) (declare (ignore x)) 0)
(defmacro usocket::get-peer-address (&rest x) (declare (ignore x)) #(127 0 0 1))
(defmacro usocket::get-hosts-by-name (&rest x) (declare (ignore x)) nil)
(defmacro usocket::get-host-name (&rest x) (declare (ignore x)) nil)
(defmacro usocket::vector-quad-to-dotted-quad (&rest x) (declare (ignore x)) nil)
(defmacro usocket::usocket-p (&rest x) (declare (ignore x)) t)
    
(define-condition usocket::address-in-use-error () ())
    
    
(eval-when (:compile-toplevel :load-toplevel :execute)
  (progn
    (if (find-package :json)
        (unless (find :dummy-json *features*)
          (format t "~&Overriding the existing Json package while loading ACT-R.~%")
          (format t "~&~%***~%The ACT-R history tools will not use JSON encoding in single-threaded model.~%***~%")
          (pushnew :restore-json *features*)
          (rename-package :json :backup-json)
          (defpackage :json
            (:nicknames :cl-json)
            (:use :cl)
            (:export
             :encode-json-to-string
             :decode-json-from-string))
          (pushnew :dummy-json *features*))
      (progn
        (format t "~&The history tools will not use JSON encoding in single-threaded model.~%")
        (defpackage :json
            (:nicknames :cl-json)
            (:use :cl)
            (:export
             :encode-json-to-string
             :decode-json-from-string))
        (pushnew :dummy-json *features*)))))

    
(defmacro json::encode-json-to-string (s)  `(progn ,s))
;; Identity JSON for local single-threaded mode: the history framework
;; encodes data to pass to a processor and decodes the result back.  Since
;; encode-json-to-string is a pass-through (returns the data, not a string),
;; decode must also pass through — otherwise the round-trip drops everything
;; to nil (which silently emptied BOLD / module-demand buffer columns, since
;; parse-trace-lists-for-bold decodes the buffer-trace via this function).
(defmacro json::decode-json-from-string (s)  `(progn ,s))
(defmacro json::write-json-string (s stream) (declare (ignore s stream)) `(progn nil))

(defparameter json::*json-output* nil) 
(defparameter json::+json-lisp-symbol-tokens+ nil)
(defparameter json::*lisp-identifier-name-to-json* nil)


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
