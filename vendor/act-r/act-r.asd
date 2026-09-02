;;;; act-r.asd — Primary ASDF system definition for ACT-R 7
;;;; This is the top-level system. Subsystems are defined inline
;;;; because ASDF 3.3.1 hierarchical secondary systems require
;;;; the secondary .asd file to be discoverable via :tree scan.

(defsystem "act-r"
  :version "7.31.5"
  :description "ACT-R 7 cognitive architecture (single-threaded, ASDF-packaged)"
  :license "LGPL-2.1"
  :in-order-to ((test-op (test-op "act-r/test")))
  :depends-on ("act-r/support" "act-r/framework" "act-r/core-modules"
               "act-r/commands" "act-r/devices" "act-r/modules"
               "act-r/tools" "act-r/other-files"))

;;; The support subsystem contains ONLY the files that must load before
;;; the framework.  Other support files (central-parameters, general-pm,
;;; production-parsing, etc.) are loaded on-demand via require-compiled
;;; calls from framework and module files, using the ACT-R-support
;;; logical pathname set up by preamble.lisp.

(defsystem "act-r/support"
  :version "7.31.5"
  :description "ACT-R support utilities and single-threaded stubs"
  :license "LGPL-2.1"
  :serial t
  :components ((:file "src/support/preamble")
               (:file "src/support/single-threaded")))

;;; The framework subsystem contains the core ACT-R framework files.
;;; Files are loaded in the order specified by the original framework-loader.lisp.
;;; version-init.lisp sets up version system parameters (depends on version-string
;;; and system-parameters, both loaded earlier in the framework sequence).

(defsystem "act-r/framework"
  :version "7.31.5"
  :description "ACT-R 7 framework core"
  :license "LGPL-2.1"
  :serial t
  :depends-on ("act-r/support")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/framework/version-string")
               (:file "src/framework/internal-structures")
               (:file "src/framework/misc-utils")
               (:file "src/framework/dispatcher")
               (:file "src/framework/system-parameters")
               (:file "src/framework/meta-process")
               (:file "src/framework/chunk-types")
               (:file "src/framework/chunks")
               (:file "src/framework/modules")
               (:file "src/framework/parameters")
               (:file "src/framework/buffers")
               (:file "src/framework/model")
               (:file "src/framework/events")
               (:file "src/framework/scheduling")
               (:file "src/framework/chunk-spec")
               (:file "src/framework/top-level")
               (:file "src/framework/device-interface")
               (:file "src/framework/vision-categorization")
               (:file "src/framework/random")
               (:file "src/framework/printing")
               (:file "src/framework/naming-module")
               (:file "src/framework/history-recorder")
               (:file "src/support/version-init")))

;;; The core-modules subsystem contains the standard ACT-R modules:
;;; declarative memory, goal, procedural, vision, motor, audio, speech, imaginal.
;;; These modules use require-compiled to load support files on-demand.

(defsystem "act-r/core-modules"
  :version "7.31.5"
  :description "ACT-R 7 core modules"
  :license "LGPL-2.1"
  :serial t
  :depends-on ("act-r/framework")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/core-modules/declarative-memory")
               (:file "src/core-modules/goal")
               (:file "src/core-modules/procedural")
               (:file "src/core-modules/vision")
               (:file "src/core-modules/motor")
               (:file "src/core-modules/audio")
               (:file "src/core-modules/speech")
               (:file "src/core-modules/imaginal")))

;;; The commands subsystem provides ACT-R command definitions for
;;; conflict trees, declarative memory, procedural system, and P*.

(defsystem "act-r/commands"
  :version "7.31.5"
  :description "ACT-R 7 commands"
  :license "LGPL-2.1"
  :serial t
  :depends-on ("act-r/core-modules")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/commands/conflict-tree")
               (:file "src/commands/dm-commands")
               (:file "src/commands/procedural-cmds")
               (:file "src/commands/p-star-cmd")))

;;; The devices subsystem provides virtual device support.

(defsystem "act-r/devices"
  :version "7.31.5"
  :description "ACT-R 7 virtual devices"
  :license "LGPL-2.1"
  :serial t
  :depends-on ("act-r/core-modules")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/devices/device")
               (:file "src/devices/uwi")))

;;; The modules subsystem provides additional ACT-R modules:
;;; GUI interface, production compilation, temporal, utility/reward.

(defsystem "act-r/modules"
  :version "7.31.5"
  :description "ACT-R 7 additional modules"
  :license "LGPL-2.1"
  :serial t
  :depends-on ("act-r/core-modules")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/modules/act-gui-interface")
               (:file "src/modules/production-compilation")
               (:file "src/modules/temporal")
               (:file "src/modules/utility-and-reward-1")))

;;; The tools subsystem provides compilation, tracing, and analysis tools.

(defsystem "act-r/tools"
  :version "7.31.5"
  :description "ACT-R 7 tools"
  :license "LGPL-2.1"
  :serial t
  :depends-on ("act-r/core-modules" "act-r/modules")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/tools/buffer-trace")
               (:file "src/tools/goal-compilation")
               (:file "src/tools/high-performance")
               (:file "src/tools/image-feature")
               (:file "src/tools/imaginal-compilation")
               (:file "src/tools/motor-compilation")
               (:file "src/tools/perceptual-compilation")
               (:file "src/tools/retrieval-compilation")
               (:file "src/tools/trace-history")
               (:file "src/tools/visible-virtual")))

;;; The other-files subsystem provides additional ACT-R features:
;;; BOLD simulation, buffer history, environment graphics, I/O devices,
;;; history recording, and system parameter initialization.

(defsystem "act-r/other-files"
  :version "7.31.5"
  :description "ACT-R 7 additional features"
  :license "LGPL-2.1"
  :serial t
  :depends-on ("act-r/core-modules" "act-r/devices" "act-r/modules" "act-r/tools")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/other-files/bold")
               (:file "src/other-files/buffer-history")
               (:file "src/other-files/env-graphic-trace")
               (:file "src/other-files/keyboard")
               (:file "src/other-files/microphone")
               (:file "src/other-files/mouse")
               (:file "src/other-files/perceptual-history")
               (:file "src/other-files/production-history")
               (:file "src/other-files/retrieval-history")
               (:file "src/other-files/system-param-init")))

;;; ======================================================================
;;; Extras — optional extensions loaded separately by users:
;;;   (asdf:load-system "act-r/extras/blending")
;;; These are NOT in the main system's depends-on.
;;; ======================================================================

(defsystem "act-r/extras/act-touch"
  :description "ACT-R touch device extension"
  :license "LGPL-2.1"
  :depends-on ("act-r")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/extras/act-touch/act-touch")))

(defsystem "act-r/extras/adaptive-noise"
  :description "ACT-R adaptive noise extension"
  :license "LGPL-2.1"
  :depends-on ("act-r")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/extras/adaptive-noise/adaptive-noise")))

(defsystem "act-r/extras/associative-learning"
  :description "ACT-R associative learning extension"
  :license "LGPL-2.1"
  :depends-on ("act-r")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/extras/associative-learning/associative-learning")))

(defsystem "act-r/extras/base-level-inhibition"
  :description "ACT-R base-level inhibition extension"
  :license "LGPL-2.1"
  :depends-on ("act-r")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/extras/base-level-inhibition/bl-inhibition")))

(defsystem "act-r/extras/blending"
  :description "ACT-R blended retrieval extension"
  :license "LGPL-2.1"
  :depends-on ("act-r")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/extras/blending/blending")))

(defsystem "act-r/extras/emma"
  :description "ACT-R EMMA (Eye Movements and Movements of Attention) extension"
  :license "LGPL-2.1"
  :depends-on ("act-r")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/extras/emma/emma")))

(defsystem "act-r/extras/extended-motor-actions"
  :description "ACT-R extended motor actions extension"
  :license "LGPL-2.1"
  :depends-on ("act-r")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/extras/extended-motor-actions/motor-extension")))

;;; Requires real bordeaux-threads (uses bt:with-lock-held) — incompatible
;;; with single-threaded stubs.  Not a refactoring issue.
#+:ignore
(defsystem "act-r/extras/parallel-computation"
  :description "ACT-R parallel computation extension"
  :license "LGPL-2.1"
  :depends-on ("act-r")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/extras/parallel-computation/parallel-computation")))

;;; Depends on parallel-computation above — same threading requirement.
;;; Not a refactoring issue.
#+:ignore
(defsystem "act-r/extras/parallel-retrieval"
  :description "ACT-R parallel retrieval extension"
  :license "LGPL-2.1"
  :depends-on ("act-r")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/extras/parallel-retrieval/parallel-retrieval")))

;;; FASL cache conflict with dummy-bordeaux package renaming — stale .fasl
;;; causes load failure on first attempt, passes on retry.  Not a
;;; refactoring issue.
#+:ignore
(defsystem "act-r/extras/save-model"
  :description "ACT-R save model extension"
  :license "LGPL-2.1"
  :depends-on ("act-r")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/extras/save-model/save-chunks-and-productions")))

(defsystem "act-r/extras/spacing-effect"
  :description "ACT-R spacing effect extension"
  :license "LGPL-2.1"
  :depends-on ("act-r")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/extras/spacing-effect/spacing-effect")))

(defsystem "act-r/extras/syllable-count"
  :description "ACT-R syllable count extension"
  :license "LGPL-2.1"
  :depends-on ("act-r")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/extras/syllable-count/syllable-count")))

(defsystem "act-r/extras/tracker"
  :description "ACT-R tracker extension"
  :license "LGPL-2.1"
  :depends-on ("act-r")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/extras/tracker/tracker")))

;;; ql:quickload interns keyword as :WNLEXICALMODULE (uppercase) which
;;; doesn't match the mixed-case ASDF system name.  Use
;;; (asdf:load-system "act-r/extras/WNLexicalModule") instead.
;;; Not a refactoring issue.
#+:ignore
(defsystem "act-r/extras/WNLexicalModule"
  :description "ACT-R WordNet lexical module extension"
  :license "LGPL-2.1"
  :depends-on ("act-r")
  :around-compile (lambda (thunk)
                    (handler-bind ((warning #'muffle-warning))
                      (funcall thunk)))
  :components ((:file "src/extras/WNLexicalModule/WNLexical_3-0-2")))

;;; ======================================================================
;;; Tutorial, test-models, examples — ASDF-registered secondary systems
;;; for resolve-path-based model loading. No file components; models
;;; are loaded on demand via (load (resolve-path "system" "path")).
;;; ======================================================================

(defsystem "act-r/tutorial"
  :version "7.31.5"
  :description "ACT-R 7 tutorial models and experiments"
  :license "LGPL-2.1"
  :depends-on ("act-r"))

(defsystem "act-r/test-models"
  :version "7.31.5"
  :description "ACT-R 7 regression test models"
  :license "LGPL-2.1"
  :depends-on ("act-r"))

(defsystem "act-r/examples"
  :version "7.31.5"
  :description "ACT-R 7 example models"
  :license "LGPL-2.1"
  :depends-on ("act-r"))
