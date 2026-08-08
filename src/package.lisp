;;;; package.lisp — mtt package
(defpackage :mtt
  (:use :cl)
  (:nicknames :model-tracing)
  (:export ;; types
           #:make-chunk #:chunk-p #:chunk-isa #:chunk-slots
           #:make-chunk-type-def #:chunk-type-def-p
           #:chunk-type-def-name #:chunk-type-def-slots #:chunk-type-def-parent
           #:make-model-definition #:model-definition-p
           #:model-definition-chunk-types #:model-definition-chunks
           #:model-definition-productions #:model-definition-initial-goal
           ;; production accessors (reader/compiler/matcher clients inspect these)
           #:production-p #:production-name
           #:production-lhs #:production-rhs
           #:production-kind #:production-kc
           ;; reader
           #:read-model-file
           ;; compiler
           #:compile-model
           ;; matcher
           #:matching-productions #:match-production
           #:buffer-state #:make-buffer-state #:buffer-chunk #:set-buffer-chunk))

(in-package :mtt)
