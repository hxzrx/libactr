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
           #:production-p #:production-name #:make-production
           #:production-lhs #:production-rhs
           #:production-kind #:production-kc
           ;; reader
           #:read-model-file
           ;; compiler
           #:compile-model
           ;; matcher
           #:matching-productions #:match-production #:model-matching-productions
           #:make-buffer-state #:buffer-chunk #:set-buffer-chunk
           ;; Phase 3: production feedback
           #:production-feedback
           ;; Phase 3: step-intent / kc-event / trace-result
           #:step-intent #:make-step-intent #:step-intent-p
           #:step-intent-assignments #:step-intent-action-type #:step-intent-prime
           #:kc-event #:make-kc-event #:kc-event-p
           #:kc-event-kc #:kc-event-correct-p #:kc-event-production #:kc-event-kind
           #:trace-result #:make-trace-result #:trace-result-p
           #:trace-result-status #:trace-result-production #:trace-result-bindings
           #:trace-result-feedback #:trace-result-events
           #:trace-result-next-state #:trace-result-next-path #:trace-result-alternatives
           ;; 已有但此前未导出 —— 期 3 适配器/buggy 库需程序化构造产生式,故公开
           #:chunk-slot
           #:make-buffer-pattern #:buffer-pattern-buffer #:buffer-pattern-modifier
           #:buffer-pattern-type-name #:buffer-pattern-slot-tests
           #:make-slot-test #:slot-test-slot #:slot-test-kind #:slot-test-operand
           #:make-action #:action-modifier #:action-buffer #:action-spec
           ;; Phase 3: tracer
           #:apply-rhs
           #:covers-p
           #:path-continuity-strategy
           #:trace-step
           ;; Phase 4: event log
           #:log-event #:make-log-event #:log-event-p #:copy-log-event
           #:log-event-seq #:log-event-timestamp
           #:log-event-student-id #:log-event-session-id #:log-event-problem-id
           #:log-event-kc-event #:log-event-intent-summary #:log-event-result-summary
           #:make-event-log #:event-log-p
           #:log-append #:log-all-events #:log-events-since #:log-last-seq
           #:disconnect-log
           #:serialize-event-log #:deserialize-event-log
           ;; Phase 4: cognitive-session
           #:cognitive-session #:cognitive-session-p
           #:session-model #:session-state #:session-path #:session-log
           #:session-student-id #:session-problem-id #:session-model-id #:session-id
           #:session-step-count #:session-status
           #:start-session #:step-session #:end-session
           #:session-last-checkpoint
           ;; Phase 4: checkpoint/restore
           #:checkpoint-session #:restore-from-checkpoint
           ;; Phase 5: student-session
           #:student-session #:student-session-p
           #:student-session-student-id #:student-session-log
           #:student-session-sessions #:student-session-status
           #:start-student-session #:end-student-session
           #:register-cognitive-session
           #:compute-mastery
           ;; Phase 6: knowledge tracing (Bayesian 4-parameter BKT)
           ;; Phase 7: per-KC override (overrides slot + kt-params-for)
           #:kt-params #:kt-params-p #:make-kt-params
           #:kt-params-l0 #:kt-params-transit #:kt-params-guess #:kt-params-slip
           #:kt-params-overrides
           #:kt-update #:kt-posterior #:kt-params-for
           ;; Phase 5: Redis durable event-log backend (mtt/redis-store system)
           #:redis-event-log #:redis-event-log-p
           #:make-redis-event-log #:redis-event-log-connection
           #:redis-event-log-key #:redis-event-log-host #:redis-event-log-port
           ;; Phase 5: domain-adapter protocol (mtt/server system; lives in :mtt
           ;; because adapters reference it alongside step-intent / trace-result).
           #:domain-adapter
           #:prepare-session #:adapt-action #:step-done?
           ;; Phase 8: authoring support (core utility; base class in mtt/server)
           #:apply-kc-map
           ;; Phase 8: reusable adapter base (mtt/server; symbols live in :mtt)
           #:standard-domain-adapter
           #:adapter-model-package #:adapter-terminal-production
           #:adapter-intern #:adapter-goal-slot #:adapter-fact
           #:adapter-set-goal #:adapter-prime-pair #:adapter-primed-intent
           ;; Phase 12: minimal bug-DSL (core half; runtime half in mtt/server)
           #:bug-spec #:make-bug-spec #:bug-spec-p
           #:bug-spec-name #:bug-spec-kind #:bug-spec-kc #:bug-spec-feedback
           #:bug-spec-goal-type #:bug-spec-goal-guard #:bug-spec-answers
           #:bug-spec-fact-slots #:bug-spec-when
           #:bug-answer-env #:eval-bug-form
           #:bug-production #:detect-bug))

(in-package :mtt)
