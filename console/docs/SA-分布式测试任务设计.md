# SA 分布式测试任务设计

> 目标：把 10 台算力机通过 SuperAgent 的工单结构串成一个可观测的测试闭环，
> 产出可用于架构迭代的量化数据。

---

## 一、先说清楚架构事实（决定了任务能怎么设计）

我读了 SA 源码，以下几点是硬约束，直接影响任务形态：

### 1. SA 的 worker 只在本机跑

`src/executor/dsh.ts` 第 70 行：

```ts
readonly machine: Pick<Machine, 'stateDir'>
```

它只拿 `stateDir`（一个本地绝对路径）。**SA 没有任何"远端机器"的概念**，
不存在跨机调度能力。

### 2. 唯一能触达远端的接口是 `executor.prepare`

`src/policy.ts` 第 99 行：

```ts
prepare: z.string().max(LIMITS.prepareCommand).default(''),
```

在 `prepareDirectory()` 里，它对**每个新工单**执行这条命令，
工作目录是工单目录的父目录，带工单环境变量，超时 `PREPARE_TIMEOUT_MS`。
平台适配：Windows 上用 `powershell -NoProfile -NonInteractive -Command`。

**这是 SA 唯一能在 worker 开始干活前执行任意命令的钩子。**
要碰远端机器，只能走这里。

### 3. 并发上限 16

`src/limits.ts`：

```ts
maxWorkers: { min: 1, max: 16 }
```

默认 3。

### 4. 工单状态机

```
working/queued → working → person/delivery | person/answer
                       →  person/review  | person/blocked | person/failed
```

---

## 二、任务设计：**分布式一致性校验（Distributed Consistency Verification）**

### 为什么选这个任务

| 要求 | 这个任务怎么满足 |
|---|---|
| 十台机都要参与 | 每台跑同一个确定性计算，产出可交叉验证的结果 |
| 数据可收集 | 每台产出结构化的 JSON 指标（耗时/算力/环境指纹）|
| 能验证 SA 能力 | 走完整工单流程：GitHub Issue → 评估 → 派发 → 执行 → 回帖 |
| 失败可诊断 | 每台独立产出，失败点明确 |
| 可重复 | 固定输入 + 确定性算法 = 可复现 |

### 任务定义

**每台机器执行同一个确定性计算任务，产出一份可独立验证的结果报告。**

具体算法（选 SHA-256 串链，因为它确定、可并行、无浮点误差）：

```
输入：固定种子 seed = "sa-test-2026-11-10"
步骤：
  1. h0 = SHA256(seed)
  2. h(i) = SHA256(h(i-1) || i)   for i = 1..N
  3. 输出：h(N) 的十六进制，以及每 1000 步的中间值校验点
```

**N = 200,000**（预计单机 8-15 秒，足够产生可测差异，又不会拖太久）

### 为什么这个算法适合测试

1. **结果唯一**：10 台必须算出完全相同的结果。任何一台不同 → 立刻发现
2. **可定位**：每 1000 步存一个校验点，能精确定位从哪步开始分歧
3. **可测性能**：记录总耗时，反映 CPU 差异
4. **可测环境**：同时采集 OS 版本、node 版本、CPU 型号
5. **无需依赖**：纯计算，不碰网络、不碰文件系统，排除干扰因素

---

## 三、两种执行路径（都要测）

### 路径 A：SA 工单驱动（测 SA 本身）

```
GitHub Issue（1 个父 Issue + 10 个子任务）
    ↓
SA github source 轮询发现
    ↓
eval 评估（用 skyunion-deepseek）
    ↓
建立工单，executor.prepare 执行（这里 ssh 到目标机分配任务）
    ↓
worker 在本机处理结果（解析、校验、汇总）
    ↓
回帖到 GitHub Issue
```

**这条路径测的是：**
- GitHub 轮询延迟
- eval 判定准确性（会不会错误拒绝/错误接受）
- 工单建立到 worker 启动的耗时
- prepare 钩子的可靠性
- 并发调度（3 个 worker vs 10 台机器的排队行为）
- 回帖成功率

### 路径 B：直连批处理（对照组）

绕过 SA，直接 ssh 到 10 台并发跑同一个任务。

**为什么要这个对照组：**

只有和它对比，才能算出 SA 的调度开销：

```
SA 总耗时 - 直连总耗时 = SA 的编排成本
```

没有这个基线，就无法判断"SA 慢"是它自己的问题还是机器的问题。

---

## 四、要收集的数据

### 每台机器的执行数据

```json
{
  "hostname": "SHA1084",
  "role": "算力机",
  "cpu": "AMD Ryzen 7 3700X 8-Core",
  "cores": 16,
  "os": "Microsoft Windows 11 企业版 LTSC",
  "nodeVersion": "v24.22.1",
  "startedAt": "2026-11-10T01:15:23.456+08:00",
  "finishedAt": "2026-11-10T01:15:38.789+08:00",
  "elapsedMs": 15333,
  "resultHash": "a3f5...",
  "checkpoints": ["h1000的值", "h2000的值", ...],
  "throughput": 13043.5
}
```

### SA 编排数据

```json
{
  "issueCreatedAt": "...",
  "firstPollAt": "...",
  "pollLatencyMs": 3421,
  "evalStartedAt": "...",
  "evalFinishedAt": "...",
  "evalDurationMs": 2100,
  "evalVerdict": "accept",
  "ticketCreatedAt": "...",
  "prepareStartedAt": "...",
  "prepareFinishedAt": "...",
  "prepareDurationMs": 8900,
  "workerStartedAt": "...",
  "workerFinishedAt": "...",
  "replyPostedAt": "...",
  "totalDurationMs": 45700
}
```

### 汇总指标

| 指标 | 定义 | 用途 |
|---|---|---|
| 结果一致性 | 10 台 resultHash 相同的比例 | 正确性 |
| 一致性收敛时间 | 从第一个到最后一个完成 | 调度效率 |
| SA 编排开销 | SA 总耗时 − 直连总耗时 | SA 的性能成本 |
| eval 准确率 | 正确判定数 / 总数 | eval 质量 |
| 并发利用率 | 平均并发 worker 数 / maxWorkers | 调度饱和度 |
| 失败率 | 失败工单 / 总工单 | 稳定性 |
| 重试次数 | 重试发生次数 | 稳定性 |

---

## 五、任务分解

### 阶段 1：准备（不碰 SA）

1. **写任务程序** `hashchain.ps1`
   - 输入：seed、N、输出路径
   - 输出：JSON（含 hash、校验点、耗时、环境信息）
2. **写校验程序**（本机 Python）
   - 独立复算，验证 10 台结果一致
3. **在 10 台上验证任务本身能跑通**
   - 这一步必须跑通，否则后续测的是"任务坏了"而不是"SA 坏了"

### 阶段 2：路径 B 基线（直连批处理）

4. **直连并发跑 10 台**
   - 记录端到端耗时
   - 这是后续对比的基线

### 阶段 3：路径 A（SA 驱动）

5. **在 GitHub 建测试 Issue**
   - 内容：任务描述 + 要求每台机器报告
   - 打 `sa-test` 标签
6. **配置 SA 的 executor.prepare**
   - 钩子脚本：ssh 到目标机，启动 hashchain，回收结果
7. **观察 SA 完整流程**
   - 记录每个阶段的耗时
8. **回收结果并校验**

### 阶段 4：分析

9. **生成对比报告**
   - 路径 A vs 路径 B
   - 10 台性能分布
   - SA 各阶段耗时占比
10. **输出架构改进建议**

---

## 六、这个设计能回答的问题

| 问题 | 怎么回答 |
|---|---|
| SA 的 GitHub 轮询够快吗？ | pollLatency 数据 |
| eval 判定准不准？ | 10 次判定的准确性 |
| prepare 钩子是可靠的分发手段吗？ | prepare 成功率 + 耗时 |
| maxWorkers=3 够用吗？ | 排队时间 vs 执行时间 |
| SA 的编排开销有多大？ | 路径 A − 路径 B |
| 哪台机器是瓶颈？ | 各台耗时分布 |
| 失败恢复是否有效？ | 重试次数与最终成功率 |

---

## 七、风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| OFFCE 的 GitHub 依赖代理 | 若代理挂，路径 A 断 | 先验证代理稳定；准备 fallback |
| eval 拒绝测试 Issue | 流程走不下去 | 先用简单明确的 Issue 文本；必要时临时放宽 policy |
| prepare 超时 | 工单失败 | PREPARE_TIMEOUT 内完成；先测单机耗时 |
| 10 台同时跑压垮本机 | SA 自己崩 | 分批（3+3+4）或调 maxWorkers |
| 结果不一致无法定位 | 数据不可用 | 每 1000 步存校验点 |

---

## 八、待确认

1. **测试 Issue 建在哪个仓库？** 当前 SA 配的是 `JingWang-Star996/superagent-workspace`
2. **N 取多少？** 我建议 200,000（单机 8-15 秒）。要更明显的性能差异可以加到 500,000
3. **是否需要分成 10 个独立 Issue？** 
   - 单个 Issue + prepare 内部循环：简单，但测不到并发调度
   - 10 个 Issue：能测并发，更接近真实场景，但更慢
4. **路径 A 用哪个 SA？** 本机的（3082）还是 OFFCE 的备用（3092）？建议先用本机
