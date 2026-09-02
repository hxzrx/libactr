;;;; version-init.lisp — Version system parameters for ACT-R 7 ASDF system
;;;; Extracted from actr7.x/load-act-r.lisp lines 733-833.
;;;; This file must load AFTER version-string.lisp (which defines the
;;;; *actr-version-string* etc. globals) and AFTER system-parameters.lisp
;;;; (which provides create-system-parameter).

(in-package :act-r)

(let ((set-version-info 4))
  (defun version-info-ignored (val)
    (declare (ignore val))
    (if (zerop set-version-info)
        nil
      (decf set-version-info))))

(defun fixed-version-parameter-value (val)
  (lambda (a b)
    (declare (ignore a b))
    val))

(create-system-parameter :act-r-version :valid-test 'version-info-ignored
                         :default-value *actr-version-string* :warning "unmodified"
                         :documentation "The full software version"
                         :handler (fixed-version-parameter-value *actr-version-string*))

(create-system-parameter :act-r-architecture-version :valid-test 'version-info-ignored
                         :default-value (read-from-string *actr-architecture-version*) :warning "unmodified"
                         :documentation "The ACT-R architecture version"
                         :handler (fixed-version-parameter-value (read-from-string *actr-architecture-version*)))

(create-system-parameter :act-r-major-version :valid-test 'version-info-ignored
                         :default-value (read-from-string *actr-major-version-string*) :warning "unmodified"
                         :documentation "The major software version"
                         :handler (fixed-version-parameter-value (read-from-string *actr-major-version-string*)))

(create-system-parameter :act-r-minor-version :valid-test 'version-info-ignored
                         :default-value (if *actr-minor-version-string* (read-from-string *actr-minor-version-string*) 0) :warning "unmodified"
                         :documentation "The minor software version"
                         :handler (fixed-version-parameter-value (if *actr-minor-version-string* (read-from-string *actr-minor-version-string*) 0)))

(defun valid-version-test-string (val)
  (if (eq val t)
      t
    (when (stringp val)
      (awhen (position #\- val)
             (setf val (subseq val 0 it)))
      (and
       (every (lambda (x) (find x '(#\. #\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9))) val)
       (<= (count #\. val) 2)
       (> (length val) 0)))))

(let ((last-result t))
  (defun check-act-r-version-string (set-or-get val)
    (if set-or-get
        (setf last-result (if (stringp val)
                              (let* ((ver (subseq val 0 (position #\- val)))
                                     (version-numbers (read-from-string (format nil "(~a)" (substitute #\space #\. ver)))))
                                (case (length version-numbers)
                                  (1 (= (first version-numbers) (car (ssp :act-r-architecture-version))))
                                  (2 (and (= (first version-numbers) (car (ssp :act-r-architecture-version)))
                                          (= (second version-numbers) (car (ssp :act-r-major-version)))))
                                  (3 (and (= (first version-numbers) (car (ssp :act-r-architecture-version)))
                                          (= (second version-numbers) (car (ssp :act-r-major-version)))
                                          (<= (third version-numbers) (car (ssp :act-r-minor-version)))))
                                  (t nil))) ;; just to be safe, but the valid test should avoid this...
                            val))
      last-result)))



(create-system-parameter :check-act-r-version :valid-test 'valid-version-test-string
                         :default-value t :warning "a valid version string of the form A{.B{.C}} where A, B, and C are integers followed by optional data after a dash"
                         :documentation "Test a version string against the current version for t or nil result"
                         :handler 'check-act-r-version-string)



(defun written-for-act-r-version (version &optional description)
  (if (stringp version)
      (let ((strip-tag (subseq version 0 (position #\- version))))
        (if (valid-version-test-string strip-tag)
            (let ((given-version-numbers (read-from-string (format nil "(~a)" (substitute #\space #\. strip-tag))))
                  (current-version-numbers (mapcar (lambda (x) (car (ssp-fct (list x))))
                                             (list :act-r-architecture-version
                                                   :act-r-major-version
                                                   :act-r-minor-version))))
              (cond ((not (= (first given-version-numbers) (first current-version-numbers)))
                     (print-warning "Current ACT-R architecture ~d is not the same as ~d specified in ~a~@[ for ~a~]"
                                    (first current-version-numbers) (first given-version-numbers) version description))
                    ((and (second given-version-numbers)
                          (not (= (second given-version-numbers) (second current-version-numbers))))
                     (if (> (second given-version-numbers) (second current-version-numbers))
                         (print-warning "Current ACT-R major version ~d is older than major version ~d specified in ~a~@[ for ~a~].~%           Some features may not be implemented."
                                        (second current-version-numbers) (second given-version-numbers) version description)
                       (print-warning "Current ACT-R major version ~d is newer than major version ~d specified in ~a~@[ for ~a~].~%           It may not be backward compatible."
                                      (second current-version-numbers) (second given-version-numbers) version description)))
                    ((and (third given-version-numbers)
                          (> (third given-version-numbers) (third current-version-numbers)))
                     (print-warning "Current ACT-R minor version ~d is older than minor version ~d specified in ~a~@[ for ~a~].~%           Some features may not be implemented."
                                    (third current-version-numbers) (third given-version-numbers) version description))
                    (t t)))
          (progn
            (print-warning "Invalid version specified in written-for-act-r-version: ~s.  Version must be an ACT-R version string." version)
            :invalid-value)))
    (progn
      (print-warning "Invalid version specified in written-for-act-r-version: ~s.  Version must be an ACT-R version string." version)
      :invalid-value)))


(add-act-r-command "written-for-act-r-version" 'written-for-act-r-version "Check a given version number against the current version for compatibility. Params: version-string {checking-info}")
