;;;; support.asd — kept for reference / alternative loading.
;;;; The canonical definition of "act-r/support" is in act-r.asd.
;;;; This file is NOT used by the main system.

(defsystem "act-r/support"
  :version "7.31.5"
  :description "ACT-R support utilities and single-threaded stubs"
  :license "LGPL-2.1"
  :serial t
  :components ((:file "preamble")
               (:file "single-threaded")))
