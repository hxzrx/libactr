;;;; src/reader.lisp — ACT-R model file reader (Task 3)
;;;
;;; Parses an ACT-R model file (Common Lisp S-expressions) into a
;;; model-definition.  Productions are stored as RAW patterns: each LHS/RHS
;;; element is a list (buffer modifier raw-slot-tests) where raw-slot-tests is
;;; a list of (slot kind value) triples with kind in {:raw :raw-neg}.  Type
;;; classification (literal/variable) and inheritance merging are deferred to
;;; the compiler (Task 4); the reader only captures raw structure.
;;;
;;; Key input facts (verified against tutorial/unit1/addition.lisp):
;;;   * A production body, once READ, is a FLAT symbol list.
;;;   * Buffer markers are single symbols ending in #\> (=goal> +retrieval>
;;;     -goal> ?buf>); their first char is the modifier.
;;;   * "==>" is a single symbol naming the LHS/RHS separator.
;;;   * Slot tests are KEY VALUE pairs: ISA ADD, ARG1 =NUM1, SUM NIL.
;;;   * Negation is THREE tokens:  - arg2 =count   (lone "-" then slot then
;;;     value).  The attached form "-arg2 =count" is also accepted.
;;;   * Special RHS actions !output!/!eval!/!bind! are single symbols wrapped
;;;     in #\! ... #\! with a non-slot argument; they must not be absorbed into
;;;     the preceding buffer pattern.
;;;
;;; Package handling: READ interns the file's symbols into *PACKAGE* (the
;;; caller's package).  Dispatch keys are matched by NAME so the reader works
;;; regardless of which package the caller is in; data symbols (chunk names,
;;; slot names, buffer names) follow *PACKAGE*.  This matches ACT-R's own
;;; convention and lets callers compare returned symbols against their own
;;; package-local literals.
(in-package :mtt)

;; ------------------------------------------------------------------ helpers

(defun sym= (sym name)
  "True when SYM is a symbol whose name equals NAME (string, uppercase)."
  (and (symbolp sym) (string= (symbol-name sym) name)))

(defun buffer-marker-p (sym)
  "True when SYM is a buffer-test marker: a symbol whose name ends in #\>."
  (and (symbolp sym)
       (let ((s (symbol-name sym)))
         (and (plusp (length s))
              (char= (char s (1- (length s))) #\>)))))

(defun special-action-marker-p (sym)
  "True when SYM is a special RHS action like !output! / !eval! / !bind!."
  (and (symbolp sym)
       (let ((s (symbol-name sym)))
         (and (>= (length s) 2)
              (char= (char s 0) #\!)
              (char= (char s (1- (length s))) #\!)))))

(defun segment-marker-p (sym)
  "A token that opens a new pattern segment (buffer marker or special action)."
  (or (buffer-marker-p sym)
      (special-action-marker-p sym)))

(defun arrow-p (sym)
  "True when SYM is the LHS/RHS separator symbol `==>`."
  (sym= sym "==>"))

;; ----------------------------------------------------- top-level dispatch

(defun read-model-file (pathname)
  "Read an ACT-R model file -> a fresh model-definition (no shared state).
   Symbols are interned in *PACKAGE* (the caller's package); dispatch keys are
   matched by name, so the caller's package governs the data symbols returned."
  (with-open-file (f pathname)
    (let ((forms (loop :for form := (read f nil :eof)
                       :until (eq form :eof)
                       :collect form))
          (ct (make-hash-table :test 'eq))
          (dm (make-hash-table :test 'eq))
          (productions nil)
          (initial-goal nil)
          (params nil))
      (dolist (form forms)
        ;; Only forms inside (define-model name ...) carry model content.
        (when (and (consp form) (sym= (car form) "DEFINE-MODEL"))
          (dolist (inner (cddr form))
            (when (consp inner)
              (let ((head (symbol-name (car inner))))
                (cond
                  ((string= head "CHUNK-TYPE")
                   (parse-chunk-type (cdr inner) ct))
                  ((string= head "ADD-DM")
                   (dolist (c (parse-dm (cdr inner)))
                     (setf (gethash (car c) dm) (cdr c))))
                  ((string= head "P")
                   (push (parse-production (cdr inner)) productions))
                  ((string= head "GOAL-FOCUS")
                   (setf initial-goal (parse-goal-focus (cdr inner) dm)))
                  ((string= head "SGP")
                   (setf params (cdr inner)))
                  (t nil)))))))
      (make-model-definition :chunk-types ct :chunks dm
                             :productions (nreverse productions)
                             :initial-goal initial-goal
                             :params params))))

;; ------------------------------------------------- chunk-type / dm / goal

(defun extract-parent (head)
  "HEAD is (name > parent).  Return the parent symbol by locating '>' by name
   (package-agnostic), or nil."
  (let ((pos (position-if (lambda (s) (sym= s ">")) head)))
    (when pos (nth (1+ pos) head))))

(defun parse-chunk-type (body ct-table)
  "Record a chunk-type definition.
   body shapes:
     (name slot1 slot2 ...)                ; no parent
     ((name > parent) slot1 slot2 ...)     ; with parent (inheritance is merged
                                           ; by the compiler, which sees the
                                           ; full table; here we store own
                                           ; slots + parent only)."
  (let* ((head      (first body))
         (wrappedp  (consp head))
         (name      (if wrappedp (first head) head))
         (parent    (when wrappedp (extract-parent head)))
         (own-slots (rest body)))
    (setf (gethash name ct-table)
          (make-chunk-type-def :name name
                               :slots own-slots
                               :parent parent))))

(defun parse-dm (body)
  "Parse an add-dm body into (name . chunk) pairs.
   Each entry is (name isa type slot val slot val ...)."
  (loop :for entry :in body
        :when (and (consp entry) (sym= (second entry) "ISA"))
          :collect (let* ((name (first entry))
                          (type (third entry))
                          (pairs (loop :for (k v) :on (cdddr entry) :by #'cddr
                                       :when k :collect (cons k v))))
                     (cons name (make-chunk :isa type :slots pairs)))))

(defun parse-goal-focus (body dm-table)
  "Parse a goal-focus body into a chunk.
   Inline form: ((isa add arg1 five arg2 two)).
   Named form:  (first-goal) -> looked up in the declarative memory table."
  (let ((entry (first body)))
    (cond
      ((and (consp entry) (sym= (first entry) "ISA"))
       (make-chunk :isa (second entry)
                   :slots (loop :for (k v) :on (cddr entry) :by #'cddr
                                :when k :collect (cons k v))))
      ((symbolp entry)
       (gethash entry dm-table))
      (t nil))))

;; --------------------------------------------------------- productions

(defun parse-production (body)
  "Parse a flat production body into a production with RAW LHS/RHS patterns.
   body = (name . tokens...) where tokens is the flat buffer-test stream."
  (let ((name (first body))
        (tokens (rest body)))
    (multiple-value-bind (lhs-tokens rhs-tokens)
        (split-at-arrow tokens)
      (make-production name
                       (parse-patterns lhs-tokens)
                       (parse-patterns rhs-tokens)
                       nil :correct))))

(defun split-at-arrow (tokens)
  "Split a flat token list at the first ==>: values lhs-tokens, rhs-tokens."
  (let ((pos (position-if #'arrow-p tokens)))
    (if pos
        (values (subseq tokens 0 pos) (subseq tokens (1+ pos)))
        (values tokens nil))))

(defun parse-patterns (tokens)
  "Segment a flat token list at buffer markers / special actions, returning
   a list of raw patterns, one per segment."
  (loop :with segments := nil :and cur := nil
        :for tk :in tokens
        :if (segment-marker-p tk)
          :do (when cur (push (nreverse cur) segments))
              (setf cur (list tk))
        :else
          :do (push tk cur)
        :finally (when cur (push (nreverse cur) segments))
                 (return (mapcar #'parse-one-pattern (nreverse segments)))))

(defun parse-one-pattern (segment)
  "Turn one segment into a raw pattern (buffer modifier raw-slot-tests) or
   (action-name :! raw-args) for special actions."
  (let* ((marker (first segment))
         (mname  (symbol-name marker))
         (rest   (rest segment)))
    (cond
      ((special-action-marker-p marker)
       (let ((action-name (intern (subseq mname 1 (1- (length mname))))))
         (list action-name :! rest)))
      (t
       (let ((modifier (case (char mname 0)
                         (#\= :=) (#\+ :+) (#\- :-) (#\? :?) (t :=)))
             (buffer   (intern (subseq mname 1 (1- (length mname))))))
         (list buffer modifier (parse-slot-tests rest)))))))

(defun parse-slot-tests (tokens)
  "Walk a flat slot-test token list into (slot kind value) triples.
   Accepted forms:
     (isa add)        -> (isa :raw add)          ; positive test
     (-arg2 =count)   -> (arg2 :raw-neg =count)  ; attached negation
     (- arg2 =count)  -> (arg2 :raw-neg =count)  ; split negation (ACT-R default)"
  (let ((out nil)
        (neg-next nil))
    (loop :with ts := tokens
          :while ts
          :for k := (first ts)
          :do (cond
                ;; Lone "-" negates the following slot test.
                ((sym= k "-")
                 (setf neg-next t)
                 (setf ts (rest ts)))
                (t
                 (let* ((attached-neg (and (symbolp k)
                                           (> (length (symbol-name k)) 1)
                                           (char= (char (symbol-name k) 0) #\-)))
                        (slot  (if attached-neg
                                   (intern (subseq (symbol-name k) 1))
                                   k))
                        (value (second ts)))
                   (push (list slot
                               (if (or neg-next attached-neg) :raw-neg :raw)
                               value)
                         out)
                   (setf neg-next nil)
                   (setf ts (rest (rest ts)))))))
    (nreverse out)))
