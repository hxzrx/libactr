;;;; src/types.lisp — mtt data model (Task 2)
(in-package :mtt)

;; chunk-type 定义:name + 合并后的全部槽 + 父类型名
(defstruct (chunk-type-def (:constructor make-chunk-type-def% (name slots parent)))
  (name    nil :type symbol)
  (slots   nil :type list)   ; list of slot symbols (own + inherited)
  (parent  nil :type (or null symbol)))

(defun make-chunk-type-def (&key name slots parent)
  (make-chunk-type-def% name slots parent))

;; chunk 实例:类型名 + 槽值 alist(slot-symbol . value)
(defstruct (chunk (:constructor make-chunk% (isa slots)))
  (isa    nil :type symbol)
  (slots  nil :type list))

(defun make-chunk (&key isa slots)
  (make-chunk% isa slots))

;; buffer 状态:hash table buffer-name(symbol) -> chunk 或 nil(空)
(defun make-buffer-state ()
  (make-hash-table :test 'eq))

(defun buffer-chunk (state buffer-name)
  (gethash buffer-name state))

(defun (setf buffer-chunk) (new-value state buffer-name)
  (setf (gethash buffer-name state) new-value))

(defun set-buffer-chunk (state buffer-name chunk)
  "Imperative setter: store CHUNK in STATE's BUFFER-NAME buffer.
Wraps (setf buffer-chunk) for the exported API."
  (setf (buffer-chunk state buffer-name) chunk))

;; 带类型的槽测试
;; kind: :literal(等于字面值) | :variable(绑定变量) | :negation(不等于某值,值可为字面或已绑定变量)
(defstruct (slot-test (:constructor make-slot-test (slot kind operand)))
  (slot    nil :type symbol)
  (kind    nil :type (member :literal :variable :negation))
  (operand nil))  ; :literal→字面值; :variable→变量名(symbol); :negation→(kind . value) 内层

;; 编译后的 LHS buffer pattern
(defstruct (buffer-pattern (:constructor make-buffer-pattern (buffer modifier type-name slot-tests)))
  (buffer     nil :type symbol)          ; goal / retrieval / imaginal ...
  (modifier   nil :type (member := :?))  ; = 匹配内容; ? 测状态
  (type-name  nil :type (or null symbol)); ISA 类型(nil=不测类型)
  (slot-tests nil :type list))

;; RHS 动作
(defstruct (action (:constructor make-action (modifier buffer spec)))
  (modifier nil :type (member := :+ :- :!))  ; =改/+请求/-清空/!特殊
  (buffer   nil :type symbol)
  (spec     nil :type list))                  ; ((slot . value)...) 或请求/output 形式

;; 产生式
(defstruct (production (:constructor make-production (name lhs rhs kc kind &optional (feedback nil))))
  (name nil :type symbol)
  (lhs  nil :type list)   ; list of buffer-pattern
  (rhs  nil :type list)   ; list of action
  (kc   nil :type symbol)
  (kind :correct :type (member :correct :buggy))
  (feedback nil))

;; model-definition(只读共享产物)
(defstruct (model-definition (:constructor make-model-definition% (chunk-types chunks productions initial-goal params)))
  (chunk-types   nil)   ; hash symbol -> chunk-type-def
  (chunks        nil)   ; hash symbol -> chunk  (declarative memory)
  (productions   nil)   ; list of production
  (initial-goal  nil)   ; chunk
  (params        nil))  ; alist of sgp params (信息性)

(defun make-model-definition (&key chunk-types chunks productions initial-goal params)
  (make-model-definition% chunk-types chunks productions initial-goal params))

;; step-intent: 领域无关的学生输入(对 buffer 的提议 delta)
(defstruct step-intent
  (assignments nil)   ; list of (buffer slot value);value 为字面量
  (action-type nil)   ; 可选适配器标签;默认策略不用,留给未来策略
  (prime nil))        ; Phase 6: list of (buffer-name . chunk) to install in
                      ; buffer-state BEFORE tracing this step (domain-neutral
                      ; pre-step buffer setup; e.g. retrieval priming). nil = none.

;; kc-event: 每步 KC 触发,供期 6 knowledge tracing(纯数据)
(defstruct kc-event
  (kc nil)            ; production-kc,或无 kc 时取 production-name
  (correct-p nil)     ; on-path correct → t;off-path/buggy/unclassified → nil
  (production nil)    ; 命中产生式(correct 或 buggy),或 nil
  (kind :correct))    ; :correct | :buggy | :unclassified

;; trace-result: trace-step 单一返回对象(Approach A:内含推进后状态)
(defstruct trace-result
  (status :off-path)        ; :on-path | :off-path-buggy | :off-path
  (production nil)
  (bindings nil)
  (feedback nil)
  (events nil)              ; list of kc-event
  (next-state nil)
  (next-path nil)
  (alternatives nil))
