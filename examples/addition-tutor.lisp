;;;; examples/addition-tutor.lisp — fuller addition model-tracing tutor (Phase 3 demo).
;;;; A CONSUMER of the mtt core (independent system). Demonstrates the interface
;;;; mapping seam end-to-end: student action -> step-intent -> trace-step -> feedback.
;;;; Not part of the shipped core; content-level validation only.
(defpackage :mtt/addition-tutor
  (:use :cl)
  (:nicknames :addition-tutor)
  (:export #:make-tutor #:tutor-step #:demonstrate))
(in-package :mtt/addition-tutor)

;; --- buggy library (mtt-authored, each with feedback) -------------------------
;;
;; Two illustrative buggy rules for addition counting.  They are appended to the
;; read-in addition model so the off-path diagnosis can recognize the
;; corresponding misconceptions and surface their feedback.

(defun buggy-rules ()
  "Two illustrative buggy rules for addition counting."
  (list
   (mtt:make-production
    'buggy-start-count-at-one
    (list (mtt:make-buffer-pattern
           'goal := 'add
           (list (mtt:make-slot-test 'sum :literal nil))))
    (list (mtt:make-action := 'goal '((count . one))))
    nil :buggy "Count on from zero — your sum already holds the first number.")
   (mtt:make-production
    'buggy-wrong-next
    (list (mtt:make-buffer-pattern
           'goal := 'add
           (list (mtt:make-slot-test 'sum :variable '=sum))))
    ;; RHS expresses a non-adjacent next total; matches a student who jumps.
    (list (mtt:make-action := 'goal '((sum . skipped))))
    nil :buggy "That's not the next number — count up by one.")))

(defun load-tutor-model ()
  "Read+compile addition, append the buggy library.
The reader interns the model file's symbols into *PACKAGE* (documented in
src/reader.lisp).  Bind *PACKAGE* to this adapter's package so the model's
symbols (add, sum, count, five, ...) land in the SAME package as this file's
literal symbols — otherwise ISA / slot matching silently fails across packages
when demonstrate is invoked from an arbitrary caller package (e.g. CL-USER)."
  (let ((*package* (find-package :mtt/addition-tutor)))
    (let ((md (mtt:compile-model
               (mtt:read-model-file
                (asdf:system-relative-pathname "act-r" "tutorial/unit1/addition.lisp")))))
      (setf (mtt:model-definition-productions md)
            (append (mtt:model-definition-productions md) (buggy-rules)))
      md)))

;; --- dm helper: prime retrieval from the model's declarative memory -----------

;; chunk-slot-val helper (chunk slots are an alist).  Local to the adapter: it
;; must NOT be prefixed `mtt:` — it is not a core symbol.
(defun chunk-slot-val (chunk slot)
  (cdr (assoc slot (mtt:chunk-slots chunk))))

(defun dm-next (md number-val)
  "Look up the NEXT slot of the dm number chunk whose NUMBER slot = NUMBER-VAL.
Returns the next number symbol, or nil. This is a minimal dm lookup (NOT
retrieval simulation): the adapter uses it to set up the cognitive state (the
retrieval buffer) that trace-step traces against."
  (let ((chunks (mtt:model-definition-chunks md)))
    (loop :for name :being :the :hash-keys :of chunks :using (hash-value ch)
          :when (equal (chunk-slot-val ch 'number) number-val)
            :do (return (chunk-slot-val ch 'next)))))

;; --- the tutor session --------------------------------------------------------
;; A per-instance session object (local state, mutated by tutor-step).  This is
;; the demo's session wrapper — equivalent to the future cognitive-session
;; (Phase 4) — and is NOT the global mutable state the core forbids.  No
;; defvar/defparameter lives in this file.

(defstruct (tutor (:constructor %make-tutor))
  (model nil)
  (state nil)
  (path nil))

(defun make-tutor (arg1 arg2)
  "New addition tutor for ARG1 + ARG2 (number symbols)."
  (let* ((md (load-tutor-model))
         (state (mtt:make-buffer-state)))
    (setf (mtt:buffer-chunk state 'goal)
          (mtt:make-chunk :isa 'add :slots `((arg1 . ,arg1) (arg2 . ,arg2) (sum . nil))))
    (%make-tutor :model md :state state)))

(defun prime-num (tutor val)
  "Prime the retrieval buffer with the dm number-chunk for VAL (number . val,
next . (dm-next val)) so a production that retrieves number=VAL can match.
The core does not simulate retrieval (spec 4.5); the adapter sets up the state."
  (let ((md (tutor-model tutor)))
    (setf (mtt:buffer-chunk (tutor-state tutor) 'retrieval)
          (mtt:make-chunk :isa 'number
                          :slots `((number . ,val)
                                   (next . ,(dm-next md val)))))))

(defun trace-and-advance (tutor intent)
  "Run trace-step against the (already-primed) session state; on on-path, advance
the session state/path. Returns the trace-result. Caller is responsible for
priming retrieval beforehand."
  (let ((r (mtt:trace-step (tutor-model tutor) (tutor-state tutor)
                           (tutor-path tutor) intent)))
    (when (eq (mtt:trace-result-status r) :on-path)
      (setf (tutor-state tutor) (mtt:trace-result-next-state r))
      (setf (tutor-path tutor) (mtt:trace-result-next-path r)))
    r))

(defun advance-count! (tutor)
  "Fire the model's internal increment-count step that accompanies each new total.
In the ACT-R addition model every increment-sum is followed by an increment-count
(the count is the model's bookkeeping for how many have been added); the student
only ever reports the running total.  We trace that count increment as a hidden
on-path step so the goal's count reaches arg2, which terminate-addition requires.
Primes retrieval=number(count), traces count -> (dm-next count), advances."
  (let* ((goal (mtt:buffer-chunk (tutor-state tutor) 'goal))
         (count (chunk-slot-val goal 'count))
         (newcount (dm-next (tutor-model tutor) count)))
    (prime-num tutor count)
    (trace-and-advance tutor (mtt:make-step-intent :assignments `((goal count ,newcount))))))

(defun render-step (action result)
  "Print one traced step's diagnosis."
  (format t "~&[~A] ~A via ~A~@[ — ~A~]  (KC ~A)~%"
          action
          (ecase (mtt:trace-result-status result)
            (:on-path "on-path")
            (:off-path-buggy "off-path (buggy)")
            (:off-path "off-path (unclassified)"))
          (or (and (mtt:trace-result-production result)
                   (mtt:production-name (mtt:trace-result-production result)))
              "—")
          (mtt:trace-result-feedback result)
          (or (and (mtt:trace-result-events result)
                   (mtt:kc-event-kc (first (mtt:trace-result-events result))))
              "—")))

(defun tutor-step (tutor action intent)
  "Trace one student step and render nothing (the caller renders).  For
:next-total, also fires the model's internal increment-count (see advance-count!)
so the goal's count reaches arg2 and terminate-addition can later match.  Returns
the student-visible trace-result (initialize / increment-sum / terminate step)."
  (ecase action
    (:start
     ;; initialize-addition needs no retrieval (its LHS has no =retrieval> test).
     (trace-and-advance tutor intent))
    (:next-total
     ;; Student reports a new total -> increment-sum fires (retrieval = current sum).
     (prime-num tutor (chunk-slot-val (mtt:buffer-chunk (tutor-state tutor) 'goal) 'sum))
     (let ((r (trace-and-advance tutor intent)))
       (when (eq (mtt:trace-result-status r) :on-path)
         (advance-count! tutor))
       r))
    (:submit
     ;; terminate-addition: retrieval must hold the answer's number chunk.
     (prime-num tutor (chunk-slot-val (mtt:buffer-chunk (tutor-state tutor) 'goal) 'sum))
     (trace-and-advance tutor intent))
    (:buggy
     ;; No priming: let the off-path diagnosis query the buggy library.
     (trace-and-advance tutor intent))))

;; --- student-action -> step-intent mapping ------------------------------------
;; Hardcoded number symbols are for demo readability only; a real adapter would
;; derive these from the tutor's arg1/arg2 and the running count.

(defun intent/start ()           (mtt:make-step-intent :assignments '((goal sum five) (goal count zero))))
(defun intent/next-total (n)     (mtt:make-step-intent :assignments `((goal sum ,n))))
(defun intent/submit (answer)    (mtt:make-step-intent :assignments `((goal count nil) (goal sum ,answer))))
(defun intent/buggy-count-one () (mtt:make-step-intent :assignments '((goal count one))))

(defun demonstrate ()
  "Run a scripted on-path + off-path-buggy demonstration of 5 + 2."
  (let ((tut (make-tutor 'five 'two)))
    (format t "~&=== addition tutor demo: 5 + 2 ===~%")
    (render-step :start      (tutor-step tut :start      (intent/start)))
    (render-step :next-total (tutor-step tut :next-total (intent/next-total 'six)))
    (render-step :next-total (tutor-step tut :next-total (intent/next-total 'seven)))
    (render-step :submit     (tutor-step tut :submit     (intent/submit 'seven)))
    ;; a buggy turn in a fresh tutor
    (let ((tut2 (make-tutor 'five 'two)))
      (render-step :buggy (tutor-step tut2 :buggy (intent/buggy-count-one))))
    tut))
