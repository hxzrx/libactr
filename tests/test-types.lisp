;;;; tests/test-types.lisp — type/data-model tests (Task 2)
(in-package :libactr/test)
(in-suite :libactr)

;; Smoke test: loading the libactr/test system succeeds and the :libactr package exists.
(test smoke-package-exists-after-load
  (is (find-package :libactr)))

;;; --- Brief Step 1: chunk + chunk-type-def ---

(test make-chunk-and-access
  (let ((c (libactr:make-chunk :isa 'add :slots '((arg1 . 5) (arg2 . 2)))))
    (is (eq (libactr:chunk-isa c) 'add))
    (is (equal (libactr:chunk-slots c) '((arg1 . 5) (arg2 . 2))))
    (is (eql (cdr (assoc 'arg1 (libactr:chunk-slots c))) 5))))

(test make-chunk-type-def
  (let ((ct (libactr:make-chunk-type-def :name 'number :slots '(number next) :parent nil)))
    (is (eq (libactr:chunk-type-def-name ct) 'number))
    (is (equal (libactr:chunk-type-def-slots ct) '(number next)))))

;;; --- Brief Step 5: buffer-state ---

(test buffer-state-basic
  (let ((s (libactr:make-buffer-state))
        (c (libactr:make-chunk :isa 'add :slots '((sum . 5)))))
    (is (null (libactr:buffer-chunk s 'goal)))
    (setf (libactr:buffer-chunk s 'goal) c)
    (is (eq (libactr:buffer-chunk s 'goal) c))))

;;; --- Additional struct round-trip tests (constructor → accessor) ---
;;; These exercise the forward-looking structs (slot-test, buffer-pattern,
;;; action, production, model-definition) so typos are caught now, not in
;;; Tasks 3-5. Accessors for these are not yet exported from :libactr, so we
;;; reach them via the double-colon internal reader.

(test slot-test-roundtrip
  (let ((st (libactr::make-slot-test 'arg1 :literal 5)))
    (is (eq  (libactr::slot-test-slot    st) 'arg1))
    (is (eq  (libactr::slot-test-kind    st) :literal))
    (is (eql (libactr::slot-test-operand st) 5))))

(test buffer-pattern-roundtrip
  (let ((bp (libactr::make-buffer-pattern 'goal := 'add
                                       (list (libactr::make-slot-test 'arg1 :literal 5)))))
    (is (eq  (libactr::buffer-pattern-buffer     bp) 'goal))
    (is (eq  (libactr::buffer-pattern-modifier   bp) :=))
    (is (eq  (libactr::buffer-pattern-type-name  bp) 'add))
    (is (listp (libactr::buffer-pattern-slot-tests bp)))))

(test action-roundtrip
  (let ((a (libactr::make-action := 'goal '((sum . 7)))))
    (is (eq  (libactr::action-modifier a) :=))
    (is (eq  (libactr::action-buffer   a) 'goal))
    (is (equal (libactr::action-spec   a) '((sum . 7))))))

(test production-roundtrip
  (let ((p (libactr::make-production
            'add-rule
            (list (libactr::make-buffer-pattern 'goal := 'add nil))
            (list (libactr::make-action := 'goal '((sum . 7))))
            'kc-add
            :correct)))
    (is (eq  (libactr::production-name p) 'add-rule))
    (is (eq  (libactr::production-kc   p) 'kc-add))
    (is (eq  (libactr::production-kind p) :correct))
    (is (listp (libactr::production-lhs p)))
    (is (listp (libactr::production-rhs p)))))

(test model-definition-roundtrip
  (let ((dm (libactr:make-model-definition
             :chunk-types  (libactr:make-buffer-state) ; hash placeholder
             :chunks       (libactr:make-buffer-state)
             :productions  nil
             :initial-goal nil
             :params       '(:esc t))))
    (is (hash-table-p (libactr:model-definition-chunk-types dm)))
    (is (null (libactr:model-definition-productions dm)))
    (is (null (libactr:model-definition-initial-goal dm)))
    (is (equal (libactr::model-definition-params dm) '(:esc t)))))

;;; --- Phase 3: production feedback + new data-model structs ---

(test make-production-accepts-optional-feedback
  "make-production takes an optional 6th feedback arg; 5-arg calls default to nil."
  (is (null (production-feedback (make-production 'p nil nil nil :correct))))
  (is (equal "hint"
             (production-feedback (make-production 'p nil nil nil :buggy "hint")))))

(test step-intent-and-events-construct
  "New Phase 3 structs construct and read back."
  (let ((intent (make-step-intent :assignments '((goal sum seven)))))
    (is (equal '((goal sum seven)) (step-intent-assignments intent)))
    (is (null (step-intent-action-type intent))))
  (let ((ev (make-kc-event :kc 'add :correct-p t :production 'terminate-addition
                           :kind :correct)))
    (is (eq :correct (kc-event-kind ev)))
    (is (eq t (kc-event-correct-p ev))))
  (let ((r (make-trace-result :status :on-path :feedback nil)))
    (is (eq :on-path (trace-result-status r)))
    (is (null (trace-result-events r)))))
