;;;; package.lisp — libactr package
;;;; The export surface, tiered (Phase 13 Task 12). The SYMBOL SET is frozen —
;;;; this regrouping is annotation only (no adds/removes); tiers state who
;;;; should use each group and what stability it promises.
(defpackage :libactr
  (:use :cl)
  (:nicknames :model-tracing)
  (:export
   ;; ===== 稳定契约:核心引擎(types/reader/compiler/matcher/tracer) =====
   ;; 最内层 API:模型数据结构 + read/compile/match/trace。库消费者(含 act-r
   ;; 双轨 oracle 与领域适配器)依赖这一组;语义冻结,任何变更须 dual-track
   ;; 全绿佐证。纯函数契约(显式穿线 state,零全局)。
   ;; types: chunk / chunk-type-def / model-definition / production
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
   ;; reader / compiler
   #:read-model-file
   #:compile-model
   ;; matcher + buffer-state
   #:matching-productions #:match-production #:model-matching-productions
   #:make-buffer-state #:buffer-chunk #:set-buffer-chunk
   ;; Phase 3: production feedback
   #:production-feedback
   ;; Phase 3: tracer data types (step-intent / kc-event / trace-result)
   #:step-intent #:make-step-intent #:step-intent-p
   #:step-intent-assignments #:step-intent-action-type #:step-intent-prime
   #:kc-event #:make-kc-event #:kc-event-p
   #:kc-event-kc #:kc-event-correct-p #:kc-event-production #:kc-event-kind
   #:trace-result #:make-trace-result #:trace-result-p
   #:trace-result-status #:trace-result-production #:trace-result-bindings
   #:trace-result-feedback #:trace-result-events
   #:trace-result-next-state #:trace-result-next-path #:trace-result-alternatives
   ;; 程序化构造产生式的原料(期 3 起适配器/buggy 库依赖;构造子 + 访问器)
   #:chunk-slot
   #:make-buffer-pattern #:buffer-pattern-buffer #:buffer-pattern-modifier
   #:buffer-pattern-type-name #:buffer-pattern-slot-tests
   #:make-slot-test #:slot-test-slot #:slot-test-kind #:slot-test-operand
   #:make-action #:action-modifier #:action-buffer #:action-spec
   ;; tracer 入口与策略
   #:apply-rhs
   #:covers-p
   #:path-continuity-strategy
   #:trace-step
   ;; ===== 稳定契约:会话与持久(session/event-log/checkpoint/kt/student-session) =====
   ;; 核心引擎之上的运行时层:单会话认知推进、权威事件日志(掌握度的唯一
   ;; 真相源)、检查点/恢复、BKT 参数与更新、跨题学生实体。仍零全局可变
   ;; 状态(一切可变态在实例上);锁不进这层(服务层职责)。
   ;; event-log:log-event 记录 + 内存 event-log + 后端协议 seam
   #:log-event #:make-log-event #:log-event-p #:copy-log-event
   #:log-event-seq #:log-event-timestamp
   #:log-event-student-id #:log-event-session-id #:log-event-problem-id
   #:log-event-kc-event #:log-event-intent-summary #:log-event-result-summary
   #:make-event-log #:event-log-p
   #:log-append #:log-all-events #:log-events-since #:log-last-seq
   #:disconnect-log
   #:serialize-event-log #:deserialize-event-log
   ;; cognitive-session(Phase 4)
   #:cognitive-session #:cognitive-session-p
   #:session-model #:session-state #:session-path #:session-log
   #:session-student-id #:session-problem-id #:session-model-id #:session-id
   #:session-step-count #:session-status
   #:start-session #:step-session #:end-session
   #:session-last-checkpoint
   ;; checkpoint/restore(Phase 4)
   #:checkpoint-session #:restore-from-checkpoint
   ;; student-session(Phase 5):跨题实体,一生一条共享事件日志
   #:student-session #:student-session-p
   #:student-session-student-id #:student-session-log
   #:student-session-sessions #:student-session-status
   #:start-student-session #:end-student-session
   #:register-cognitive-session
   #:compute-mastery
   ;; knowledge tracing(Phase 6 四参数 BKT;Phase 7 per-KC override)
   #:kt-params #:kt-params-p #:make-kt-params
   #:kt-params-l0 #:kt-params-transit #:kt-params-guess #:kt-params-slip
   #:kt-params-overrides
   #:kt-update #:kt-posterior #:kt-params-for
   ;; ===== 稳定契约:authoring 层(apply-kc-map/bug-DSL/validate-bug-spec/符号 codec) =====
   ;; 面向领域作者:声明式 KC 归因、最小 bug-DSL(一处声明 → 产生式/检测/
   ;; prime 三件套)、spec 校验器、符号-tag codec。纯函数,零全局注册表
   ;; (谓词/环境名由调用方传入)。
   ;; Phase 8: 声明式 KC 归因
   #:apply-kc-map
   ;; Phase 13: symbol-tagging codec (summaries wire + cluster checkpoints)
   #:tag-symbols #:untag-symbols
   ;; Phase 12: 最小 bug-DSL —— 核心纯函数半边(运行时半边见服务层组)
   #:bug-spec #:make-bug-spec #:bug-spec-p
   #:bug-spec-name #:bug-spec-kind #:bug-spec-kc #:bug-spec-feedback
   #:bug-spec-goal-type #:bug-spec-goal-guard #:bug-spec-answers
   #:bug-spec-fact-slots #:bug-spec-when
   #:bug-answer-env #:eval-bug-form
   #:bug-production #:detect-bug
   ;; Phase 13: authoring validator (spec §6)
   #:validate-bug-spec
   ;; ===== 服务层接口(libactr/server 与 libactr/redis-store 系统;adapter 协议 + redis 后端) =====
   ;; 引擎之上的部署形态:领域适配器协议与可复用基座、bug-DSL 运行时半边、
   ;; 统一 400 条件、Redis 持久事件日志后端。符号仍住在 :libactr(适配器与
   ;; step-intent/trace-result 并用);行为随 libactr/server 系统加载。
   ;; Phase 14 — server-layer additions: kc->json (C4), student-events-key
   ;; (C3), server-drop-session (A1 zombie convergence / admin eviction).
   ;; These three live in :libactr/server's own defpackage (src/server.lisp,
   ;; 23 → 26 exports there), NOT here: :libactr's export count stays 178
   ;; (grep-verified #: entries in this file — phase 14 added no :libactr symbols).
   ;; adapter 协议(引擎/领域唯一 seam:3 泛函 + tag 基类)
   #:domain-adapter
   #:prepare-session #:adapt-action #:step-done?
   ;; Phase 8: 可复用适配器基座(配置 slot + plumbing 助手 + 默认 step-done?)
   #:standard-domain-adapter
   #:adapter-model-package #:adapter-terminal-production
   #:adapter-intern #:adapter-goal-slot #:adapter-fact
   #:adapter-set-goal #:adapter-prime-pair #:adapter-primed-intent
   ;; Phase 12: bug-DSL 运行时半边(prime fact + hidden intent 从同一 spec 派生)
   #:bug-goal-env #:bug-intent
   ;; 统一 malformed-input 条件(适配器 signal;HTTP 层映射 400)
   #:bad-tutor-request #:bad-tutor-request-message #:signal-bad-request
   ;; Phase 5: Redis durable event-log backend (libactr/redis-store system)
   #:redis-event-log #:redis-event-log-p
   #:make-redis-event-log #:redis-event-log-connection
   #:redis-event-log-key #:redis-event-log-host #:redis-event-log-port))

(in-package :libactr)
