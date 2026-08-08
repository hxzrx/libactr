;;;; tests/test-types.lisp — type/data-model tests (Task 2)
(in-package :mtt/test)
(in-suite :mtt)

;; Smoke test: loading the mtt/test system succeeds and the :mtt package exists.
(test smoke-package-exists-after-load
  (is (find-package :mtt)))

;;; --- Brief Step 1: chunk + chunk-type-def ---

(test make-chunk-and-access
  (let ((c (mtt:make-chunk :isa 'add :slots '((arg1 . 5) (arg2 . 2)))))
    (is (eq (mtt:chunk-isa c) 'add))
    (is (equal (mtt:chunk-slots c) '((arg1 . 5) (arg2 . 2))))
    (is (eql (cdr (assoc 'arg1 (mtt:chunk-slots c))) 5))))

(test make-chunk-type-def
  (let ((ct (mtt:make-chunk-type-def :name 'number :slots '(number next) :parent nil)))
    (is (eq (mtt:chunk-type-def-name ct) 'number))
    (is (equal (mtt:chunk-type-def-slots ct) '(number next)))))

;;; --- Brief Step 5: buffer-state ---

(test buffer-state-basic
  (let ((s (mtt:make-buffer-state))
        (c (mtt:make-chunk :isa 'add :slots '((sum . 5)))))
    (is (null (mtt:buffer-chunk s 'goal)))
    (setf (mtt:buffer-chunk s 'goal) c)
    (is (eq (mtt:buffer-chunk s 'goal) c))))

;;; --- Additional struct round-trip tests (constructor → accessor) ---
;;; These exercise the forward-looking structs (slot-test, buffer-pattern,
;;; action, production, model-definition) so typos are caught now, not in
;;; Tasks 3-5. Accessors for these are not yet exported from :mtt, so we
;;; reach them via the double-colon internal reader.

(test slot-test-roundtrip
  (let ((st (mtt::make-slot-test 'arg1 :literal 5)))
    (is (eq  (mtt::slot-test-slot    st) 'arg1))
    (is (eq  (mtt::slot-test-kind    st) :literal))
    (is (eql (mtt::slot-test-operand st) 5))))

(test buffer-pattern-roundtrip
  (let ((bp (mtt::make-buffer-pattern 'goal := 'add
                                       (list (mtt::make-slot-test 'arg1 :literal 5)))))
    (is (eq  (mtt::buffer-pattern-buffer     bp) 'goal))
    (is (eq  (mtt::buffer-pattern-modifier   bp) :=))
    (is (eq  (mtt::buffer-pattern-type-name  bp) 'add))
    (is (listp (mtt::buffer-pattern-slot-tests bp)))))

(test action-roundtrip
  (let ((a (mtt::make-action := 'goal '((sum . 7)))))
    (is (eq  (mtt::action-modifier a) :=))
    (is (eq  (mtt::action-buffer   a) 'goal))
    (is (equal (mtt::action-spec   a) '((sum . 7))))))

(test production-roundtrip
  (let ((p (mtt::make-production
            'add-rule
            (list (mtt::make-buffer-pattern 'goal := 'add nil))
            (list (mtt::make-action := 'goal '((sum . 7))))
            'kc-add
            :correct)))
    (is (eq  (mtt::production-name p) 'add-rule))
    (is (eq  (mtt::production-kc   p) 'kc-add))
    (is (eq  (mtt::production-kind p) :correct))
    (is (listp (mtt::production-lhs p)))
    (is (listp (mtt::production-rhs p)))))

(test model-definition-roundtrip
  (let ((dm (mtt:make-model-definition
             :chunk-types  (mtt:make-buffer-state) ; hash placeholder
             :chunks       (mtt:make-buffer-state)
             :productions  nil
             :initial-goal nil
             :params       '(:esc t))))
    (is (hash-table-p (mtt:model-definition-chunk-types dm)))
    (is (null (mtt:model-definition-productions dm)))
    (is (null (mtt:model-definition-initial-goal dm)))
    (is (equal (mtt::model-definition-params dm) '(:esc t)))))
