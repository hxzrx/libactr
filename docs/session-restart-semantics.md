# 会话重启语义（调查报告，只调查不实现）

2026-10-08 · libactr 0.5.0 · 背景：CogAssistant（DESIGN.md D4/D5）以 Python 编排器
作为 HTTP 瘦客户端驱动 libactr 练习会话。本报告回答「tutor-server 进程重启后，
进行中的会话怎么样」，并就「是否把 checkpoint/restore 提升为 HTTP API」给出建议。
决策输入供 CogAssistant P7 裁决。

## 1. 重启后各层的真实表现

进程内可变状态全部随进程消失——cognitive-session（buffer state / step-count /
path）、session-handle、student-session、mastery 增量缓存、students/sessions/
models 注册表都在 tutor-server 实例的堆里，无处重建。直接后果：

- 旧 session_id 的 `POST /engine/v1/session/step` → **404** "unknown session_id"。
- **直连 worker** 的 `GET /engine/v1/student/mastery` → **404** "unknown student_id"，
  直到该学生再次 start：server-student-mastery 查的是内存 students 表，发现不了
  Redis 里的历史。**经集群代理则无此问题**——proxy 的 mastery 是 location-free 的，
  直连 Redis 事件日志现算，worker 重启后立即可用。
- 同一 student_id 再次 `POST /engine/v1/session/start`：重启后不存在 active
  session，幂等分支不命中 → 正确地**新建** session；ensure-student 以同一 Redis
  key（`libactr:student:<id>:events`）挂回**同一份历史事件日志**，掌握度在首次
  调用时全量重放——P(L) 从全部历史续算（与重放前 bit-identical by construction，
  redis-store 套件有 replay 全等测试背书）。

## 2. 持久化与恢复能力的边界

| 东西 | 持久吗 | 边界 |
|---|---|---|
| 事件日志（:redis-config 部署） | ✅ Redis + AOF | 纯内存部署（未传 :redis-config）重启丢一切，含掌握度历史 |
| 掌握度（P(L)） | ✅ 派生量 | compute-mastery 是事件日志的确定性折叠，无独立持久化需求；增量缓存重启后自动全量重建 |
| 解题中状态（buffers/path/step-count） | ⚠️ 仅集群内 | checkpoint-session 产出纯数据快照，但只有 cluster scan tick（默认 2s）把它写进 Redis `ckpt:<sid>`；非集群部署连 end-session 的最终 checkpoint 也只存内存 slot，不落盘 |
| checkpoint/restore 机制 | ⚠️ 集群内部专用 | restore-from-checkpoint 只被 takeover（cluster-adopt-session）调用，未暴露 HTTP；单 worker 集群重启同样无人接管 |

集群接管是当前唯一支持的「同 sid 透明续接」，其语义即恢复边界：恢复的是**最近
一次 checkpoint** 的解题状态，checkpoint 之后的步骤从解题状态中丢弃（学员重做该
窗口，≤ scan-interval）；事件日志保留全部事件（掌握度无损）。全集群同时重启时
没有活着的接管者——worker 重启后其 scan tick 的反向索引对账会清掉不再本地的旧
sid 路由，旧 sid 经代理最终 404；Redis 里残留的 `ckpt:<sid>` 没有任何恢复路径
会去读它（这正是 HTTP restore API 将来要填的洞）。

## 3. Python 客户端今天最合理的做法

1. **把重启当作「会话丢失、学习历史保留」**：收到 step 404（或经
   `/engine/v1/health` 观察到重启——active_sessions 归零）后，用**同一
   student_id** 重新 start、重新驱动当前题。P(L) 从 Redis 历史续算，客户端无需
   任何补偿逻辑。
2. **不要复用旧 sid**，也不必强求 mid-problem 精确续位。
3. 若业务必须同 sid 无感续接：部署 libactr/cluster（≥2 worker + proxy），
   kill-worker e2e 已验证接管透明续接（事件 seq 连续、mastery 完整）。注意
   单 worker 集群重启仍丢会话；接管有 ≤ scan-interval 的窗口与 checkpoint 后
   的重做窗口。

## 4. 是否值得把 checkpoint/restore 提升为 HTTP API —— 建议：**现在不做**

- **收益小**：单题会话是秒到分钟级粒度，重启最多损失一道题的中间步骤；医疗
  场景真正在意的学习历史连续性已由事件日志 + 确定性重放保证。「同 student_id
  重开」本就是被一等公民支持的恢复路径（start 的幂等语义在重启后正确地开新
  会话而非复活旧会话）。
- **成本与风险不小**：0.3.0 起维护模式、公开面冻结；HTTP 化意味着新公开语义
  而非薄封装——需要补非集群部署的 checkpoint 持久化（当前没有 store）、按 sid
  注入注册表的恢复入口（cluster-adopt-session 是集群内模型，内含路由翻转与
  claim，不能直接外露）、以及「事件已越过 checkpoint 的 last-seq 边界」处理
  （takeover 的五元组 marker 正是为这个微妙处设计的）。
- **重开议题的触发条件**：(a) 练习演化为多题长旅程、重做代价变高；(b) 产品
  需要「暂停/恢复」跨部署形态；(c) CogAssistant P7 裁决 mid-exercise 状态必须
  保。届时实现要点：复用已导出的 checkpoint-store 协议 + Redis codec，新增
  `POST /engine/v1/session/restore {"session_id"}`（无 checkpoint → 404），沿
  SESSION→LOG→REGISTRY 锁序接入 session-handle，不触碰冻结核心。
