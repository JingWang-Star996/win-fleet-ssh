# 配置参考

## 部署参数（`deploy.ps1`）

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `-Port` | int | `22` | 生产 SSH 端口 |
| `-AltPort` | int | `2222` | 备用端口，降级方案和试跑用 |
| `-HeartbeatServer` | string | `''` | 心跳接收端地址，如 `http://192.0.2.10:18765`。留空则读配置文件，都空则跳过心跳 |
| `-HeartbeatIntervalMin` | int | `5` | 心跳上报间隔（分钟） |
| `-SkipHeartbeat` | switch | — | 强制跳过心跳安装 |
| `-SkipGuardian` | switch | — | 跳过守护进程安装（不推荐） |
| `-SkipDsh` | switch | — | 跳过 DSH 组件 |
| `-EnablePassword` | switch | — | 允许密码认证（默认只允许密钥） |
| `-NoVerify` | switch | — | 跳过部署后的验证步骤 |

**常用组合**

```powershell
# 标准部署：密钥认证 + 心跳 + 守护
.\deploy.ps1 -HeartbeatServer http://192.0.2.10:18765

# 最简部署：只要 SSH，其余都不要
.\deploy.ps1 -SkipHeartbeat -SkipGuardian -SkipDsh

# 用非标准端口
.\deploy.ps1 -Port 2200 -AltPort 2201 -HeartbeatServer http://192.0.2.10:18765
```

---

## 配置文件

### `deploy/heartbeat-target.txt`

一行，心跳接收端地址：

```
http://192.0.2.10:18765
```

`deploy.cmd` 会读它并自动传给 `deploy.ps1`。直接跑 `deploy.ps1` 时也会读。

**容错**：带 BOM、有首尾空格都能正确处理。

**改了地址之后**：重新部署一次，已部署机器上的计划任务参数才会更新。

---

## 目标机上的产物

### 文件位置

| 路径 | 内容 |
|---|---|
| `C:\ProgramData\ssh\sshd_config` | SSH 服务配置 |
| `C:\ProgramData\ssh\administrators_authorized_keys` | 管理员组公钥 |
| `C:\ProgramData\ssh-agent\heartbeat-send.ps1` | 心跳脚本 |
| `C:\ProgramData\ssh-agent\heartbeat.log` | 心跳日志 |
| `C:\ProgramData\ssh-guardian\ssh-guardian.ps1` | 守护脚本 |
| `C:\ProgramData\ssh-guardian\guardian.log` | 守护日志 |
| `C:\Program Files\OpenSSH\` | 便携版 OpenSSH（如果用了） |
| `C:\sshd-standalone\` | 独立实例（降级方案 C） |

### 计划任务

| 任务名 | 频率 | 身份 | 作用 |
|---|---|---|---|
| `FleetHeartbeat` | 开机 + 每 N 分钟 | SYSTEM | 上报状态 |
| `SshGuardian` | 开机 + 每 10 分钟 | SYSTEM | 启动看门狗（看门狗本身常驻） |
| `OpenSSH-Server-Logon` | 登录时 | 当前用户 | 降级方案 B |
| `sshd-s4u` | 开机时 | 当前用户（S4U） | 降级方案 A2 |

### 服务

| 服务名 | 启动类型 | 说明 |
|---|---|---|
| `sshd` | Automatic | 主服务（方式 A 成功时） |
| `sshd-standalone` | Automatic | 独立实例（方式 C 时） |

---

## 控制台配置

### 常量（`console/heartbeat.py`）

```python
DEFAULT_PORT = 18765      # 心跳接收端口
```

改端口需要同时改目标机的心跳地址。

### 台账位置

```
console/data/registry.json
```

首次运行自动创建。可以直接编辑（JSON 格式），但建议通过控制台操作。

### 探测超时（`console/probe.py`）

```python
CONNECT_TIMEOUT = 3       # TCP 连接超时（秒）
BANNER_TIMEOUT  = 4       # banner 读取超时（秒）
```

内网环境可以调小（1-2 秒），跨网段建议调大（5-8 秒）。

---

## 守护进程参数

`ssh-guardian.ps1` 顶部常量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `$Port` | `22` | 监控的端口 |
| `$CheckIntervalSec` | `30` | 检查间隔（秒） |
| `$FailThreshold` | `2` | 连续失败几次触发修复 |

**调优建议**：

- 检查间隔不宜小于 15 秒，否则日志增长快且浪费资源
- 阈值设为 1 会导致瞬时抖动误触发修复，建议保持 2

---

## 心跳参数

`heartbeat-send.ps1` 参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Server` | 无 | 接收端地址，必填 |
| `-Once` | — | 只上报一次就退出（用于测试） |
| `-IntervalSec` | `300` | 循环间隔（秒） |

**手动测试单次上报**：

```powershell
.\heartbeat-send.ps1 -Server http://192.0.2.10:18765 -Once
# 输出 HEARTBEAT OK 表示成功
```

**上报内容**：

```json
{
  "machineId": "16位十六进制",
  "hostname": "主機名",
  "identity": {
    "machineGuid": "...",
    "mac": "...",
    "biosSerial": "...",
    "hostname": "..."
  },
  "ips": ["192.0.2.10", "..."],
  "sshOk": true,
  "serviceState": "Running",
  "uptimeHours": 123.4,
  "timestamp": "2026-01-01T00:00:00+08:00"
}
```

---

## 自适应启动参数

`ssh-start-adaptive.ps1` 参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Port` | `22` | 生产端口 |
| `-ProbePort` | `2222` | 试跑端口（必须与生产端口不同） |
| `-SkipProbe` | — | 跳过试跑直接切换（**不推荐**，会失去安全保护） |
| `-ForceStrategy` | `auto` | 强制指定方式：`service` / `s4u` / `logonTask` / `foreground` |

**为什么有 `-SkipProbe`**：已知环境稳定时可以省几十秒。但第一次在新机型上部署千万别用——试跑是唯一能防止失联的机制。

---

## 环境变量

| 变量 | 作用 |
|---|---|
| `FLEET_QUEUE_SHARE` | 共享队列 UNC 路径（`agent.ps1` 用） |

---

## 日志位置汇总

| 位置 | 内容 |
|---|---|
| 目标机 `C:\ProgramData\ssh-agent\heartbeat.log` | 心跳 |
| 目标机 `C:\ProgramData\ssh-guardian\guardian.log` | 守护修复记录 |
| 目标机 `C:\ProgramData\ssh\start-adaptive.log` | 启动方式切换 |
| 目标机 `C:\Windows\Temp\service-ify.log` | 服务化过程 |
| 源端 `console/data/gui-live.log` | 控制台运行日志 |
| 源端 `deploy/logs/` | 部署日志（`-LogDir` 可改） |

日志超过 2MB 会自动截断，只保留最后 500 行。

---

## 一次完整的部署命令

```powershell
# 在目标机上
cd C:\path\to\win-fleet-ssh\deploy

.\deploy.ps1 `
    -Port 22 `
    -AltPort 2222 `
    -HeartbeatServer http://192.0.2.10:18765 `
    -HeartbeatIntervalMin 5
```

预期输出（关键行）：

```
[1/10] 安装 OpenSSH Server
       [OK] 使用便携版 OpenSSH 10.0p2
[6/10] 启动 SSH（4 级自动降级）
       SYSTEM 探测: OK|
       SYSTEM 上下文健康，可用服务方式
       方式 A：Windows 服务
       [OK] 方式 A 成功，端口 22 已验证
[8/10] 验证
       [OK] SSH 登录测试通过
[9/10] 心跳上报
       [OK] 任务已注册，首次上报成功
[10/10] 守护进程
       [OK] 已启动
```
