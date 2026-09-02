;;;; preamble.lisp — Infrastructure for ACT-R 7 ASDF system
;;;; Extracted from actr7.x/load-act-r.lisp for single-threaded mode.
;;;; This file MUST be loaded first (via :serial t in support.asd).

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Feature Flags
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  (pushnew :act-r *features*)
  (pushnew :single-threaded-act-r *features*)
  (pushnew :packaged-actr *features*)
  (pushnew :standalone *features*))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Package Definition
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :act-r)
    (defpackage :act-r
      (:use :cl)
      (:nicknames :actr)
      (:export
       ;; Model management
       #:define-model #:define-model-fct #:current-model
       #:delete-model #:with-model #:with-model-fct
       #:reset #:clear-all #:reload
       ;; Running
       #:run #:run-full-time #:run-until-condition
       #:run-until-time #:run-n-events #:run-step
       ;; Chunk types & chunks
       #:chunk-type #:chunk-type-fct #:chunk-type-p
       #:get-chunk-type #:get-chunk #:chunk-p
       #:pprint-chunk-type #:pprint-a-chunk
       #:printed-chunk #:chunks
       ;; Scheduling
       #:schedule-event #:schedule-event-relative
       #:schedule-event-now
       ;; Modules / buffers
       #:define-module #:define-module-fct
       #:buffer #:buffer-chunk
       ;; Goal
       #:goal-focus #:goal-focus-fct
       ;; System parameters
       #:sgp #:sgp-fct #:ssp #:ssp-fct
       ;; Printing
       #:print-warning
       ;; Version
       #:written-for-act-r-version))))

(in-package :act-r)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; define-constant (SBCL-friendly defconstant)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defmacro define-constant (name value &optional doc)
  `(defconstant ,name (if (boundp ',name) (symbol-value ',name) ,value)
     ,@(when doc (list doc))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Logical Pathname Setup
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; preamble.lisp lives in act-r/src/support/
;; ACT-R:     -> act-r/src/    (so ACT-R:support;foo resolves)
;; ACT-R-support: -> act-r/src/support/
;;
;; When ASDF loads the compiled preamble, *load-truename* points to
;; the ASDF cache, not the source tree.  We detect this by checking
;; whether the path contains ".cache" and fall back to using the
;; ASDF system's source directory.

(let* ((raw-truename *load-truename*)
       (use-asdf-source
         (or (null raw-truename)
             ;; True when *load-truename* lives inside the ASDF FASL cache
             ;; (applying output-translations leaves its directory unchanged).
             ;; Replaces the ".cache" substring test, which fails on Windows
             ;; where the cache dir is "cache" (no leading dot) and would
             ;; break under any non-default cache layout.
             (when raw-truename
               (flet ((dir-of (p)
                        (make-pathname :name nil :type nil :version nil
                                       :defaults p)))
                 (uiop:pathname-equal
                   (dir-of (asdf:apply-output-translations raw-truename))
                   (dir-of raw-truename))))))
       (support-dir
         (if use-asdf-source
             ;; Use ASDF to find the real source directory.
             ;; system-source-directory returns the dir containing the .asd,
             ;; so we append src/support/ to get the support directory.
             (let ((sys-dir (asdf:system-source-directory
                              (asdf:registered-system "act-r/support"))))
               (if sys-dir
                   (merge-pathnames "src/support/" sys-dir)
                   ;; Last resort: try to compute from the asd file location
                   (let ((asd-path (asdf:system-source-file
                                     (asdf:registered-system "act-r/support"))))
                     (if asd-path
                         (merge-pathnames "src/support/" asd-path)
                         (error "Cannot determine ACT-R support source directory")))))
             ;; Direct loading (not via ASDF cache): use *load-truename*.
             ;; Preserve host AND device: on Windows the drive letter ("C")
             ;; lives in pathname-device, not pathname-directory; omitting it
             ;; makes the logical-pathname translation drop the drive entirely.
             (make-pathname :host (pathname-host raw-truename)
                            :device (pathname-device raw-truename)
                            :directory (pathname-directory raw-truename))))
       (src-dir (make-pathname
                  :directory (butlast (pathname-directory support-dir)))))
  (setf (logical-pathname-translations "ACT-R")
    `(("**;*.*" ,(namestring (merge-pathnames "**/*.*" src-dir)))))
  (setf (logical-pathname-translations "ACT-R-support")
    `(("**;*.*" ,(namestring (merge-pathnames "**/*.*" support-dir)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; ASDF Path Resolution
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun resolve-path (system relative-path)
  "Return the absolute pathname for RELATIVE-PATH within ASDF SYSTEM."
  (asdf:system-relative-pathname system relative-path))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; File Extension Helpers
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar *.lisp-pathname* (make-pathname :type "lisp"))

(defvar *.fasl-pathname*
  (let ((type (pathname-type (compile-file-pathname "dummy.lisp"))))
    (if (and type (not (string-equal type "lisp")))
        (make-pathname :type type)
        (make-pathname :type "fasl"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Compile & Load Utilities
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar *skip-recompiling* nil)

(defun compile-and-load (pathname &optional force)
  (when (stringp pathname)
    (setf pathname (translate-logical-pathname pathname)))
  (when (pathname-type pathname)
    (if (string-equal (pathname-type pathname) "lisp")
        (setf pathname (make-pathname :host (pathname-host pathname)
                                      :directory (pathname-directory pathname)
                                      :device (pathname-device pathname)
                                      :name (pathname-name pathname)))
        (error "To compile a file it must have a .lisp extension")))
  (let* ((srcpath (merge-pathnames pathname *.lisp-pathname*))
         (binpath (merge-pathnames pathname *.fasl-pathname*)))
    (unless (probe-file srcpath)
      (error "File ~S does not exist" srcpath))
    (if *skip-recompiling*
        (unless (probe-file binpath)
          (error "File ~s does not exist but *skip-recompiling* is set." binpath))
        (when (or force
                  (member :actr-recompile *features*)
                  (not (probe-file binpath))
                  (> (file-write-date srcpath) (file-write-date binpath)))
          (compile-file srcpath :output-file binpath)))
    (load binpath)))

(defmacro finish-format (stream string &rest args)
  `(prog1
     (format ,stream ,string ,@args)
     (finish-output ,stream)))

(defun smart-load (this-files-dir file &optional (error? nil))
  (let* ((true-dir (translate-logical-pathname this-files-dir))
         (srcpath (merge-pathnames
                   (merge-pathnames file *.lisp-pathname*)
                   true-dir)))
    (if (not (probe-file srcpath))
        (if error?
            (error "File ~S does not exist" srcpath)
            (finish-format *error-output* "File ~S does not exist" srcpath))
        (compile-and-load srcpath))))

(defun actr-load (file)
  (let ((path (translate-logical-pathname file)))
    (if (not (probe-file path))
        (finish-format *error-output* "#|Warning: File ~S does not exist.|#~%" path)
        (load path))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Module Tracking
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar *act-r-modules* nil)
(defvar *current-load-mode* :single)
(defvar *requiring-extra* nil)

(defun requiring-extra ()
  *requiring-extra*)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; require-compiled Macro
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defmacro require-compiled (code-module &optional pathname)
  `(eval-when (:load-toplevel :execute)
     (unless (member ,code-module *modules* :test #'string=)
       (push ,code-module *act-r-modules*)
       (let ((pn (if (null ,pathname)
                     (concatenate 'string "ACT-R-support:" (string-downcase ,code-module) ".lisp")
                     ,pathname)))
         (if *skip-recompiling*
             (compile-and-load (translate-logical-pathname pn))
             (let* ((previous (ignore-errors
                               (with-open-file (f (translate-logical-pathname "ACT-R-support:require-mode.lisp")
                                                 :direction :input)
                                 (read f))))
                    (previous-mode (cdr (assoc ,code-module previous :test 'string=)))
                    (need-to-compile (not (eq previous-mode *current-load-mode*)))
                    (result (compile-and-load (translate-logical-pathname pn) need-to-compile)))
               (when result
                 (if previous-mode
                     (setf (cdr (assoc ,code-module previous :test 'string=)) *current-load-mode*)
                     (push (cons ,code-module *current-load-mode*) previous))
                 (ignore-errors
                   (with-open-file (f (translate-logical-pathname "ACT-R-support:require-mode.lisp")
                                      :direction :output :if-does-not-exist :create :if-exists :supersede)
                     (write previous :stream f))))
               result))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; require-extra Macro
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defmacro require-extra (name)
  `(eval-when (:load-toplevel :execute)
     (unless (member ,name *modules* :test #'string=)
       (cond
         ((mp-models)
          (print-warning "Cannot require an extra when there is a current model."))
         ((not (probe-file (translate-logical-pathname (format nil "ACT-R:extras;~a;" ,name))))
          (print-warning "Directory for extra ~a not found." ,name))
         ((not (probe-file (translate-logical-pathname (format nil "ACT-R:extras;~a;~a.lisp" ,name ,name))))
          (print-warning "Load file for extra ~a not found." ,name))
         (t
          (unwind-protect
            (progn
              (setf *requiring-extra* t)
              (when (find-package :dummy-usocket)
                (when (find-package :usocket)
                  (rename-package :usocket :backup-usocket))
                (rename-package :dummy-usocket :usocket))
              (when (find-package :dummy-json)
                (when (find-package :json)
                  (rename-package :json :backup-json))
                (rename-package :dummy-json :json (list :cl-json)))
              (when (find-package :dummy-bordeaux)
                (when (find-package :bordeaux-threads)
                  (rename-package :bordeaux-threads :backup-bordeaux))
                (rename-package :dummy-bordeaux :bordeaux-threads (list :bt)))
              (if *skip-recompiling*
                  (compile-and-load (translate-logical-pathname
                                    (format nil "ACT-R:extras;~a;~a.lisp" ,name ,name)))
                  (let* ((previous (ignore-errors
                                    (with-open-file (f (translate-logical-pathname "ACT-R-support:extra-mode.lisp")
                                                       :direction :input)
                                      (read f))))
                         (previous-mode (cdr (assoc ,name previous :test 'string=)))
                         (need-to-compile (not (eq previous-mode *current-load-mode*)))
                         (result (compile-and-load (translate-logical-pathname
                                                   (format nil "ACT-R:extras;~a;~a.lisp" ,name ,name))
                                                  need-to-compile)))
                    (when result
                      (if previous-mode
                          (setf (cdr (assoc ,name previous :test 'string=)) *current-load-mode*)
                          (push (cons ,name *current-load-mode*) previous))
                      (ignore-errors
                        (with-open-file (f (translate-logical-pathname "ACT-R-support:extra-mode.lisp")
                                           :direction :output :if-does-not-exist :create
                                           :if-exists :supersede)
                          (write previous :stream f))))
                    result)))
            (progn
              (pushnew ,name *act-r-modules*)
              (setf *requiring-extra* nil)
              (when (find-package :usocket)
                (rename-package :usocket :dummy-usocket)
                (when (find-package :backup-usocket)
                  (rename-package :backup-usocket :usocket)))
              (when (find-package :json)
                (rename-package :json :dummy-json)
                (when (find-package :backup-json)
                  (rename-package :backup-json :json (list :cl-json))))
              (when (find-package :bordeaux-threads)
                (rename-package :bordeaux-threads :dummy-bordeaux)
                (when (find-package :backup-bordeaux)
                  (rename-package :backup-bordeaux :bordeaux-threads (list :bt))))))
            (if (member ,name *modules* :test #'string=)
                t
                (print-warning "Extra ~a was loaded but did not have a provide." ,name))))))))
