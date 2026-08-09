;;;; src/oracle.lisp — act-r dual-track oracle adapter (dev-time only)
;;;
;;; The oracle loads a real ACT-R model and reports which productions match a
;;; given buffer state, serving as ground truth for Task 7's comparison against
;;; mtt's own matcher.  It is read-only scaffolding over ACT-R's inherently
;;; stateful globals — NOT part of the shipped, multi-user-safe engine.
;;;
;;; KEY ACT-R API FINDINGS (verified live against tutorial/unit1/addition.lisp,
;;; SBCL 2.6.7, act-r ASDF build):
;;;
;;;   1. Model files use bare symbols (clear-all, define-model, p, add-dm, ...).
;;;      They must be loaded with *PACKAGE* bound to :ACT-R, exactly as upstream
;;;      model-tester.cl:287 does (`(in-package :act-r)`).  Loading in another
;;;      package leaves the commands unbound or makes define-model-fct's runtime
;;;      evaluator reject the model ("isa unbound", "Model X not defined").
;;;
;;;   2. Because the model is loaded in :ACT-R, EVERY model-defined symbol
;;;      (production names, chunk-type names, slot names, chunk names, buffer
;;;      names) is interned in :ACT-R.  A quoted symbol from any other package
;;;      is a DIFFERENT symbol and silently fails ACT-R's eql lookups
;;;      ("invalid buffer name GOAL", "does not name a production", empty
;;;      conflict-set).  The oracle interns every name into :ACT-R via AR before
;;;      handing it to ACT-R, and exposes only package-neutral keywords across
;;;      its public boundary.
;;;
;;;   3. Buffers/modules are not instantiated until (RESET).  buffer-read on
;;;      goal returns NIL with an "invalid buffer" warning before reset.
;;;      oracle-load-model therefore resets once after defining the model.
;;;
;;;   4. OUTPUT CAPTURE DOES NOT WORK: ACT-R's `command-output` macro routes
;;;      through the printing module's command dispatch
;;;      (evaluate-act-r-command "command-output" -> act-r-output-stream),
;;;      NOT through *standard-output*.  `(with-output-to-string (s)
;;;      (whynot ...))` captures zero characters (verified: CAPTURE-LEN=0), so
;;;      the brief's capture-and-grep approach is unusable here.
;;;
;;;   5. Instead, WHYNOT-FCT (and PMATCHES) RETURN the conflict-set — the list
;;;      of fully-matching production names — as their primary value.  Membership
;;;      in that list is the match predicate.  Verified on addition.lisp:
;;;        goal (arg1=five arg2=two sum=nil)            -> (INITIALIZE-ADDITION)
;;;        goal (count=two arg2=two sum=seven) + retrieval (number seven)
;;;                                                    -> (TERMINATE-ADDITION)
;;;
;;;   6. (SPP) returns production-parameter records; we use the unambiguous
;;;      ALL-PRODUCTIONS (procedural-cmds.lisp:436) for the name list.
;;;
;;; We reference ACT-R symbols with double-colon (act-r::) because most of the
;;; functions we need (no-output, spp, pmatches, whynot-fct, add-dm-fct,
;;; set-buffer-chunk) are package-internal; double-colon works for both internal
;;; and external symbols and avoids any CL/ACT-R use-package conflicts.

(defpackage :mtt/oracle
  (:use :cl)
  (:nicknames :model-tracing/oracle)
  (:export #:oracle-load-model
           #:oracle-production-names
           #:oracle-set-goal-from-chunk
           #:oracle-set-retrieval-from-chunk
           #:oracle-set-buffer-from-chunk
           #:oracle-matches-p
           #:oracle-fire-and-read-slots))

(in-package :mtt/oracle)

;;;-----------------------------------------------------------------------------
;;; Internals
;;;---------------------------------------------------------------------------

(declaim (inline ar))
(defun ar (name)
  "Coerce NAME (symbol/keyword/string) to the equivalent symbol interned in
:ACT-R.  This is the crux of talking to ACT-R: model symbols live in :ACT-R,
so every name we pass in must be re-homed there.  NIL passes through unchanged."
  (typecase name
    (null nil)
    (symbol (intern (symbol-name name) :act-r))
    (string (intern (string-upcase name) :act-r))
    (t name)))

(defun production-names-as-keywords ()
  "Return the current model's production names as package-neutral keywords."
  (mapcar (lambda (s) (intern (symbol-name s) :keyword))
          (act-r::no-output (act-r::all-productions))))

(defun conflict-set ()
  "Return the current conflict-set (list of matching ACT-R production-name
symbols).  pmatches computes it via the same pmatches-internal that whynot
uses and returns the matching production names directly as its value; no-output
suppresses the incidental command-output printing of instantiations."
  (act-r::no-output (act-r::pmatches)))

(defun build-chunk-spec (mtt-chunk)
  "Translate an mtt:chunk into an ACT-R chunk-definition list suitable for
add-dm-fct: (ISA <type> <slot> <value> ...), with every name interned into
:ACT-R.  The chunk is left unnamed so ACT-R mints a unique name."
  (let ((isa (mtt:chunk-isa mtt-chunk))
        (slots (mtt:chunk-slots mtt-chunk)))
    (nconc (list (ar 'isa) (ar isa))
           (loop for (slot . value) in slots
                 nconc (list (ar slot) (ar value))))))

(defun %set-buffer-from-chunk (buffer-name mtt-chunk)
  "Add MTT-CHUNK to ACT-R declarative memory and copy it into BUFFER-NAME
synchronously via set-buffer-chunk.  Returns the chunk name."
  (let ((chunk-name (first (act-r::no-output
                             (act-r::add-dm-fct (list (build-chunk-spec mtt-chunk)))))))
    (act-r::set-buffer-chunk (ar buffer-name) chunk-name)
    chunk-name))

(defun %cancel-pending-goal-focus ()
  "A model file's (goal-focus ...) schedules a :max-priority set-buffer-chunk
into the goal buffer at time 0 (plus a clear-delayed-goal maintenance event),
both queued by the GOAL module during RESET.  These fire at the start of the
next (run ...) and OVERWRITE any goal an oracle caller placed via
set-buffer-chunk, which defeats oracle verification of arbitrary mid-path
states whose goal differs from the model's goal-focus chunk (e.g. addition's
increment-sum state: sum=five count=zero).  Cancel those pending GOAL-module
events and clear the goal module's delayed slot so the oracle has stable manual
control of the goal buffer.  Necessary for mid-path oracle verification;
harmless for the initial goal-focus state (Layer 1), where the oracle sets the
same chunk the goal-focus would have.  Verified on SBCL 2.6.7 / act-r ASDF."
  (let ((mp (act-r::current-mp)))
    (dolist (e (act-r::mp-scheduled-events mp))
      (when (eq (act-r::act-r-event-module e) (ar 'goal))
        (act-r::delete-event (act-r::act-r-event-num e)))))
  (let ((gmod (act-r::get-module-fct (ar 'goal))))
    (when gmod
      (setf (act-r::goal-module-delayed gmod) nil))))

;;;-----------------------------------------------------------------------------
;;; Public interface
;;;---------------------------------------------------------------------------

(defun oracle-load-model (pathname)
  "Ensure ACT-R is loaded, clear state, define the model in PATHNAME, reset so
buffers/modules exist, and return the model's production names as keywords."
  (asdf:load-system "act-r")            ; idempotent once loaded
  ;; Define the model with *PACKAGE* = :ACT-R so its bare symbols resolve.
  (let ((*package* (find-package :act-r)))
    (act-r::clear-all)
    (load pathname))
  (act-r::reset)
  (%cancel-pending-goal-focus)
  (production-names-as-keywords))

(defun oracle-production-names ()
  "Return the current model's production names as keywords (re-query, no reset)."
  (production-names-as-keywords))

(defun oracle-set-buffer-from-chunk (buffer-name mtt-chunk)
  "Place MTT-CHUNK into ACT-R buffer BUFFER-NAME (e.g. :goal, :retrieval).
BUFFER-NAME may be a symbol/keyword/string in any package."
  (%set-buffer-from-chunk buffer-name mtt-chunk))

(defun oracle-set-goal-from-chunk (mtt-chunk)
  "Set ACT-R's goal buffer from an mtt:chunk."
  (%set-buffer-from-chunk 'goal mtt-chunk))

(defun oracle-set-retrieval-from-chunk (mtt-chunk)
  "Set ACT-R's retrieval buffer from an mtt:chunk."
  (%set-buffer-from-chunk 'retrieval mtt-chunk))

(defun oracle-matches-p (production-name)
  "Return true iff PRODUCTION-NAME matches the current ACT-R buffer state.
PRODUCTION-NAME may be a symbol/keyword/string in any package; it is interned
into :ACT-R before the conflict-set membership test."
  (let ((pname (ar production-name)))
    (not (null (member pname (conflict-set) :test #'eq)))))

(defun oracle-fire-and-read-slots (mtt-goal-chunk slot-names &optional mtt-retrieval-chunk)
  "Set ACT-R goal (+ retrieval if given), run to fire the single matching
production (timed run — verified sufficient for single-matcher states; tutorial
models match one production per state), then return an alist of
(SLOT-NAME-KEYWORD . VALUE-KEYWORD) for the goal's SLOT-NAME symbols.
SLOT-NAMES are mtt-side symbols; they are re-homed to :ACT-R for the read and
returned as package-neutral keywords. Values likewise keywordized (nil passes
through). Verified mechanism: set-state → run → buffer-read + chunk-slot-value-fct."
  (oracle-set-goal-from-chunk mtt-goal-chunk)
  (when mtt-retrieval-chunk
    (oracle-set-retrieval-from-chunk mtt-retrieval-chunk))
  (act-r::no-output (act-r::run 0.05))
  (let ((g (act-r::buffer-read 'act-r::goal)))
    (when g
      (mapcar (lambda (s)
                (let ((v (act-r::chunk-slot-value-fct g (ar s))))
                  (cons (intern (symbol-name s) :keyword)
                        (typecase v
                          (null nil)
                          (symbol (intern (symbol-name v) :keyword))
                          (t v)))))
              slot-names))))
