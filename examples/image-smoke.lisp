;;;; examples/image-smoke.lisp — portable uiop:dump-image smoke (Phase 4).
;;;; Proves a compiled model-definition can be baked into a dumped image and the
;;;; restarted image can run a cognitive-session against it. De-risks Phase 5
;;;; deployment. NOT core (separate mtt/image system). The *smoke-model* cache
;;;; is example/smoke code, not the mtt core — it does not violate the core's
;;;; zero-global-mutable-state hard constraint.
(defpackage :mtt/image
  (:use :cl)
  (:export #:dump-smoke-core #:run-smoke-check))
(in-package :mtt/image)

(defvar *smoke-model* nil
  "Holds the pre-loaded model in the dumped image. Baked into the core on dump,
   restored on restart. Example/smoke code, not core.")

(defun ensure-smoke-model ()
  "Load+compile the addition model, caching it in *smoke-model*. Model symbols
   intern into THIS package (same discipline as addition-tutor) so ISA/slot
   matching works regardless of caller package."
  (or *smoke-model*
      (setq *smoke-model*
            (let ((*package* (find-package :mtt/image)))
              (mtt:compile-model
               (mtt:read-model-file
                (asdf:system-relative-pathname "act-r" "tutorial/unit1/addition.lisp")))))))

(defun dump-smoke-core (core-path)
  "Ensure the model is loaded, then dump a core image via uiop:dump-image
   (portable). The dumper process terminates (save-lisp-and-die semantics)."
  (ensure-smoke-model)
  (uiop:dump-image core-path))

(defun run-smoke-check ()
  "Entry point run in the RESTORED core: start a session on the pre-loaded model,
   trace an on-path 'start', print IMAGE-SMOKE-OK/FAIL, and exit with status."
  (let ((ok (eq :on-path
                (mtt:trace-result-status
                 (mtt:step-session
                  (mtt:start-session (ensure-smoke-model) :smoke :p)
                  (mtt:make-step-intent
                   :assignments '((goal sum five) (goal count zero))))))))
    (format t "~&IMAGE-SMOKE-~:[FAIL~;OK~]~%" ok)
    (finish-output)
    (uiop:quit (if ok 0 1))))
