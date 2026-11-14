# 集群控制台

Windows 算力集群的图形控制台。Tkinter 单文件 GUI，无需额外依赖。

## 它解决什么

部署完 SSH 之后，管一批机器会遇到这些问题：

| 问题 | 控制台的应对 |
|---|---|
| 不知道哪些机器在线 | 可达性探测 + 心跳状态 |
| 想知道某台的配置 | 自动采集 CPU/内存/磁盘/系统 |
| 想知道哪台在忙 | 表格实时显示 CPU/内存/GPU 占用（每 20s 一轮） |
| 想在某台上执行命令 | 内置命令分发，支持批量 |
| 想用远端算力跑 LLM | 对话面板，把 prompt 送到目标机的 dsh |
| 想跑分布式任务 | 基准测试面板，一键分发并收集 |

## 文件构成

| 文件 | 作用 |
|---|---|
| `console2.py` | 主程序，Tkinter GUI |
| `registry2.py` | 机器台账（读写 `data/registry.json`） |
| `probe.py` | 可达性与环境探测 |
| `metrics.py` | 实时指标采集（CPU/内存/GPU） |
| `identity.py` | 机器码生成与识别 |
| `heartbeat.py` | 心跳接收服务 |
| `agentchat.py` | 与远端 dsh 对话 |
| `benchdist.py` | 分布式基准测试 |
| `node_router.py` | 能力路由（任务 → 节点选择） |
| `启动控制台.bat` | Windows 双击入口 |
| `config/nodes.json` | 节点能力注册表示例 |
| `data/registry.sample.json` | 台账结构样例（脱敏） |

## 运行

```bash
# Windows
双击 启动控制台.bat

# 或直接
python console2.py
```

依赖：Python 3.9+，仅标准库 + tkinter。

**注意**：托管 Python（`~\.workbuddy\binaries\python\*`）不带 tkinter。
需要系统 Python 或自建 venv：

```powershell
# 用系统 Python 建 venv（自带 tk 8.6）
& "C:\Users\<user>\AppData\Local\Programs\Python\Python311\python.exe" -m venv .venv
.venv\Scripts\pip install -r requirements.txt   # 本项目无第三方依赖
```

## 数据目录

首次运行会在 `data/` 下生成：

```
data/
├── registry.json     机器台账（本文件不入库，含真实 IP）
├── metrics-history.json  指标历史（每轮一条，最多 500 条）
├── bench-a/          基准测试结果
└── backups/          台账自动备份
```

`data/` 是运行产物，**不纳入版本控制**。结构参考 `data/registry.sample.json`。

## 关键实现说明

### 实时指标采集（metrics.py）

表格中的 CPU / 内存 / GPU 三列由 `metrics.py` 采集，每 20 秒一轮、后台线程执行，
不阻塞界面。三条约束：

1. **必须串行采集（`workers=1`）**。在 Tk 进程里并发创建多个 `ssh.exe`
   子进程会被严重拖慢：12 台节点下 `workers=2` 成功 1/12（78s），
   `workers=1` 成功 12/12（14.5s）。同样代码在没有 Tk 的命令行下
   `workers=12` 只需 1.4s。这是 Windows GUI 进程创建子进程的开销问题，
   换线程或换子进程隔离都绕不过去。串行虽慢，但正确性优先。

2. **CPU 不能用 `Get-Counter` 单次采样**（首次返回 0），改用 WMI 的
   `Win32_PerfFormattedData_PerfOS_Processor`，它自带平均，首采即有值。

3. **内存单位是 KB**。`TotalVisibleMemorySize` / `FreePhysicalMemory`
   返回 KB，需除两次 1024 才是 GB；只除一次会显示成「9646/65436G」。

GPU 走 `nvidia-smi`，路径必须用绝对路径 `C:\Windows\System32\nvidia-smi.exe`
（它不在 PATH 里）。无显卡的机器显示「无」。

采集结果每轮追加到 `data/metrics-history.json`（最多保留 500 条），
便于事后回看异常从什么时候开始。该文件属运行产物，不入库。

### 与远端 dsh 对话（agentchat.py）

三个必须知道的约束：

1. **不能调 `dsh.cmd`** —— 远端 `.dsh\bin` 可能是空目录（安装未生成启动器）。
   统一走 `node <runtime>/@deepseek-ai/dsh/lib/bin.js headless`。

2. **prompt 必须走 stdin**，不能走命令行参数。
   Windows 命令行参数层会破坏非 ASCII 字符。

3. **中文可以正常透传**。曾有一版误判为「中文经 scp 变问号」并加了
   ASCII 拦截，实际根因是目标机 `.credentials.yaml` 编码被破坏。
   实测证据：UTF-8 文件经 scp 上传后，远端 base64 回读与本地逐字节一致。

### 编码处理（踩过的坑）

| 场景 | 必须这样做 |
|---|---|
| 远端 PowerShell 脚本含中文 | 用 **`utf-8-sig`**（带 BOM）写入，PS 5.1 靠 BOM 判断编码 |
| 修改 `.credentials.yaml` | 用**字节级**读写，不要让 PowerShell 的 `Set-Content -Encoding UTF8` 碰它 —— 该 API 会加 BOM 并破坏 YAML 缩进 |
| `.bat` 批处理 | 保持 GBK + CRLF，否则中文 Windows 下 cmd 解码出错 |

**`Set-Content -Encoding UTF8` 在 PowerShell 5.1 里会加 BOM**，这个行为已经
两次导致配置文件损坏。任何需要精确控制编码的场合，都应该用
`[IO.File]::ReadAllBytes` / `WriteAllBytes` 手动处理。

## 已知限制

- 图形界面只支持 Windows（tkinter + 依赖 Windows 路径约定）
- 对话面板同时只处理一个目标机，批量对话需排队
- 能力路由只看「能不能做」，不看「做得多快」
