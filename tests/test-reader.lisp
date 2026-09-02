;;;; tests/test-reader.lisp — reader tests (Task 3)
;;;; Binding contract: the four tests below come verbatim from the task brief.
;;;; Additional tests lock in spec intent for edge cases verified against the
;;;; real tutorial file (split-negation tokens, multiple buffer patterns,
;;;; special !output! actions, production count).
(in-package :libactr/test)
(in-suite :libactr)

(defparameter *addition-model*
  (asdf:system-relative-pathname "act-r" "tutorial/unit1/addition.lisp"))

;;; ---------- Binding tests (brief Steps 1 & 7) ----------

(test reader-parses-chunk-types
  (let ((md (libactr:read-model-file *addition-model*)))
    (is (libactr:model-definition-p md))
    (let ((ct (gethash 'number (libactr:model-definition-chunk-types md))))
      (is (libactr:chunk-type-def-p ct))
      (is (equal (libactr:chunk-type-def-slots ct) '(number next))))))

(test reader-parses-dm
  (let ((md (libactr:read-model-file *addition-model*)))
    (let ((one (gethash 'one (libactr:model-definition-chunks md))))
      (is (libactr:chunk-p one))
      (is (eq (libactr:chunk-isa one) 'number))
      (is (equal (libactr:chunk-slots one) '((number . one) (next . two)))))))

(test reader-parses-initial-goal
  (let ((md (libactr:read-model-file *addition-model*)))
    (is (libactr:chunk-p (libactr:model-definition-initial-goal md)))
    (is (eq (libactr:chunk-isa (libactr:model-definition-initial-goal md)) 'add))))

(test reader-parses-production-structure
  (let* ((md (libactr:read-model-file *addition-model*))
         (prod (find 'initialize-addition (libactr:model-definition-productions md)
                     :key #'libactr:production-name)))
    (is-true prod)
    ;; lhs at least one goal pattern (raw form: (buffer modifier raw-slot-tests))
    (is (some (lambda (p) (eq (first p) 'goal)) (libactr:production-lhs prod)))))

;;; ---------- Additional tests: spec intent & verified edge cases ----------

(test reader-reads-all-productions
  ;; addition.lisp defines exactly four productions.
  (let ((names (mapcar #'libactr:production-name
                       (libactr:model-definition-productions
                        (libactr:read-model-file *addition-model*)))))
    (is (= 4 (length names)))
    (is (equal (sort (copy-list names) #'string<)
               '(increment-count increment-sum initialize-addition
                 terminate-addition)))))

(defun find-production (md name)
  (find name (libactr:model-definition-productions md) :key #'libactr:production-name))

(defun find-pattern (patterns buffer)
  (find buffer patterns :key #'first))

(test reader-raw-pattern-shape
  ;; initialize-addition LHS goal pattern must be a raw triple
  ;; (buffer modifier raw-slot-tests) with :raw-kind slot pairs; type
  ;; classification is the compiler's job (Task 4).
  (let* ((md (libactr:read-model-file *addition-model*))
         (prod (find-production md 'initialize-addition))
         (goal-pat (find-pattern (libactr:production-lhs prod) 'goal)))
    (is-true goal-pat)
    (is (eq (second goal-pat) :=))
    (is (assoc 'isa (third goal-pat) :test #'eq))
    (is (equal (assoc 'sum (third goal-pat) :test #'eq) '(sum :raw nil)))))

(test reader-captures-rhs-retrieval-request
  ;; initialize-addition RHS issues a +retrieval> request — a second raw pattern.
  (let* ((md (libactr:read-model-file *addition-model*))
         (prod (find-production md 'initialize-addition))
         (rhs (libactr:production-rhs prod))
         (req (find-pattern rhs 'retrieval)))
    (is (find-pattern rhs 'goal))
    (is-true req)
    (is (eq (second req) :+))
    (is (equal (assoc 'isa (third req) :test #'eq) '(isa :raw number)))))

(test reader-parses-split-negation
  ;; ACT-R writes slot negation as three tokens:  - arg2 =count
  ;; (verified via raw read of tutorial/unit1/addition.lisp). The reader must
  ;; record this as (arg2 :raw-neg =count), NOT mis-pair the lone "-".
  (let* ((md (libactr:read-model-file *addition-model*))
         (prod (find-production md 'increment-sum))
         (goal-pat (find-pattern (libactr:production-lhs prod) 'goal))
         (slots (third goal-pat)))
    (is-true goal-pat)
    (is (equal (assoc 'arg2 slots :test #'eq) '(arg2 :raw-neg =count)))
    ;; the other slots must still parse as positive tests
    (is (equal (assoc 'count slots :test #'eq) '(count :raw =count)))))

(test reader-captures-special-output-action
  ;; terminate-addition RHS uses  !output! (=answer)  — a special action that is
  ;; neither a buffer marker nor a slot test. It must be captured as its own raw
  ;; pattern (output :! ...) rather than corrupting the preceding =goal> pattern.
  (let* ((md (libactr:read-model-file *addition-model*))
         (prod (find-production md 'terminate-addition))
         (rhs (libactr:production-rhs prod))
         (out (find-pattern rhs 'output))
         (goal-pat (find-pattern rhs 'goal)))
    (is-true out)
    (is (eq (second out) :!))
    ;; goal pattern must remain clean (no stray !output! slot test absorbed)
    (is-true goal-pat)
    (is (not (assoc 'output (third goal-pat) :test #'eq)))))

(test reader-parses-sgp-params
  ;; (sgp :esc t :lf .05) recorded as a flat pair list.
  (is (equal (libactr::model-definition-params
              (libactr:read-model-file *addition-model*))
             '(:esc t :lf 0.05))))

;;; --- Phase 3: :feedback annotation parsing ---

(test reader-parses-feedback-annotation
  "A (:feedback <string>) form inside a production body is captured into
   production-feedback; standard ACT-R files (addition) leave it nil."
  (let ((tmp (pathname "/tmp/libactr-feedback-test.lisp")))
    (with-open-file (f tmp :direction :output :if-exists :supersede)
      (print '(clear-all) f)
      (print '(define-model fb
                (chunk-type ct slot)
                (P my-prod
                   =goal> ISA ct slot x
                   ==>
                   =goal> slot y
                   (:feedback "wrong!"))) f))
    (unwind-protect
        (let ((prod (first (model-definition-productions (read-model-file tmp)))))
          (is (eq 'my-prod (production-name prod)))
          (is (equal "wrong!" (production-feedback prod))))
      (delete-file tmp)))
  ;; addition.lisp has no feedback annotations → all nil
  (let ((md (read-model-file
              (asdf:system-relative-pathname "act-r" "tutorial/unit1/addition.lisp"))))
    (is (every #'null (mapcar #'production-feedback
                              (model-definition-productions md))))))
