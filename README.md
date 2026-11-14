# win-fleet-ssh

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2B-blue)](https://github.com/JingWang-Star996/win-fleet-ssh)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)](https://github.com/JingWang-Star996/win-fleet-ssh)
[![Python](https://img.shields.io/badge/Python-3.9%2B-blue)](https://github.com/JingWang-Star996/win-fleet-ssh)

Windows 主机批量 SSH 部署框架。一条命令完成多台 Windows 机器的 SSH 服务部署、开机自启配置、健康监控与集中管理。

面向「有一批 Windows 机器，想统一管起来」的场景：算力机、测试机、小规模服务器集群。

> **如果你只读一部分，请读 [docs/PITFALLS.md](docs/PITFALLS.md)。**
> 那里记录了 18 个真实踩过的问题，包括两次导致 SSH 完全失联的事故。
> 这些问题大多不会在文档里出现，只会在实际部署时咬你一口。


## 它解决什么问题

在一批 Windows 机器上部署 SSH 会遇到一堆反复出现的问题：

| 问题 | 常见表现 |
|---|---|
| SSH 服务装不上 | `OpenSSH Server` 可选功能安装失败、组件版本冲突 |
| 装上了但连不上 | 认证阶段报 `lookup_sid 1332`、密钥权限不正确 |
| 能连但重启就失效 | 前台进程跑着，重启后没了；登录触发器需要人登录桌面 |
| 服务起不来 | SYSTEM 身份启动崩溃，`ExitCode 1067` |
| IP 会变 | DHCP 换了地址，之前的连接信息全失效 |
| 挂了没人知道 | 远程机器失联，只能跑到机器前处理 |

这个框架针对上述每一项都有对应机制，并且**在真实环境里验证过**（详细的踩坑记录见 [docs/PITFALLS.md](docs/PITFALLS.md)）。

## 核心特性

### 部署：自动判断环境，失败自动降级

不要求用户事先知道目标机的情况。部署脚本自己探测、自己选方案：

```
探测 SYSTEM 上下文是否健康
  ├─ 健康  → 方式 A：Windows 服务（最可靠，开机自启不依赖登录）
  └─ 异常  → 方式 A2：S4U 计划任务（用户身份 + 开机触发，免密码）
              └─ 失败 → 方式 B：登录触发器
                          └─ 失败 → 方式 C：独立实例（备用端口）
```

四种方式逐级降级，每一步都用 **SSH banner 探测**确认真的可用，而不是只看服务状态。

### 启动：永不自断退路

切换启动方式时，先停掉正在工作的实例是危险的——新方式失败就意味着彻底失联。

框架的做法：

1. 先在备用端口（默认 2222）启动候选方案
2. 验证该端口能读到 `SSH-` banner
3. 确认可用后，才停掉旧实例
4. 接管生产端口，持续监控 60 秒
5. 任何一步失败，立即回滚

### 运行：守护进程自动自愈

部署时装一个常驻看门狗：

- 每 30 秒探测一次 SSH 可连性
- 连续 2 次失败触发修复
- 修复顺序：重启当前方式 → 前台进程兜底
- 以 SYSTEM 身份运行，开机自启，不依赖登录

实测效果：手动杀掉 sshd 进程后，**40 秒内自动恢复**。

### 找机器：心跳上报解决 IP 漂移

目标机每 5 分钟把身份和网卡地址推给控制台：

```
MachineGuid + 物理网卡 MAC  →  sha256  →  16 位机器码
```

- 不依赖 SSH、不依赖共享目录、不依赖固定 IP
- 换网络、换 IP 后控制台自动更新地址簿
- 重装系统才会变机器码

**注意**：机器码刻意组合了 MAC，因为用同一系统镜像克隆的机器 `MachineGuid` 会相同，只用 GUID 会导致多台机器撞码互相覆盖。

### 管理：带图形界面的控制台

`console/console2.py` 提供 Tkinter 控制台：

- 机器列表（在线状态、地址、部署方式）
- 实时资源占用（CPU / 内存 / GPU，每 20 秒一轮，独立列展示）
- 批量探测可达性
- 心跳接收（内置 HTTP 服务，默认端口 18765）
- 操作审计日志
- 一键生成批量 SSH 命令

## 快速开始

### 前置条件

- **源端**（你的工作机）：Windows + Python 3.9+（仅控制台需要）
- **目标机**：Windows 10 / Server 2016 及以上
- **网络**：能 SSH 到目标机，或有其它方式把部署包送过去

### 1. 准备部署包

```powershell
git clone https://github.com/<your-account>/win-fleet-ssh.git
cd win-fleet-ssh
```

### 2. 下载 OpenSSH 便携版（可选但推荐）

框架默认优先使用便携版 OpenSSH，因为部分系统自带的组件版本存在认证崩溃问题。

从 [PowerShell/Win32-OpenSSH Releases](https://github.com/PowerShell/Win32-OpenSSH/releases) 下载 `OpenSSH-Win64.zip`，解压到：

```
deploy/windows/OpenSSH-Win64/
    sshd.exe
    ssh-keygen.exe
    ...
```

不下载也能工作，脚本会退回到系统自带组件。

### 3. 在目标机执行部署

把整个仓库复制到目标机，或用共享目录/U 盘传过去：

```powershell
cd <部署包路径>
.\deploy.ps1 -HeartbeatServer http://<控制台IP>:18765
```

或直接双击 `deploy.cmd`（心跳地址从 `heartbeat-target.txt` 读取）。

### 4. 启动控制台

```powershell
cd console
python console2.py
```

首次运行会生成空的 `data/registry.json`。

## 目录结构

```
win-fleet-ssh/
├── deploy/
│   ├── deploy.ps1                    部署入口
│   ├── deploy.cmd                    双击入口（自动读心跳配置）
│   ├── heartbeat-target.txt          心跳接收端地址
│   ├── windows/
│   │   ├── deploy-all.ps1            部署主体（10 个步骤）
│   │   ├── ssh-start-adaptive.ps1    自适应启动（4 级降级）
│   │   ├── ssh-guardian.ps1          守护进程（自愈）
│   │   ├── heartbeat-send.ps1        心跳上报
│   │   ├── install-heartbeat.ps1     心跳安装
│   │   ├── agent.ps1                 自愈代理（可选）
│   │   ├── run-and-log.ps1           带日志执行包装
│   │   └── deploy-summary.ps1        部署结果汇总
│   ├── linux/
│   │   └── deploy-linux.sh           Linux 目标机部署
│   └── common/
│       └── logging.ps1               日志与输出样式
├── console/
│   ├── console2.py                   控制台主程序
│   ├── registry2.py                  机器台账
│   ├── identity.py                   机器码生成
│   ├── heartbeat.py                  心跳接收服务
│   ├── probe.py                      可达性探测
│   └── install_guardian.py           守护进程安装
├── tools/
│   ├── diagnose/                     诊断脚本
│   └── repair/                       修复脚本
├── docs/
│   ├── PITFALLS.md                   踩坑记录（最有价值的部分）
│   ├── ARCHITECTURE.md               设计说明
│   └── CONFIG.md                     配置项参考
└── benchmarks/
    └── 2026-11-10-cluster-bench/     10 台集群实测：算力分布、收集策略、掉线容错
```

## 部署流程（10 步）

```
 1  安装 OpenSSH Server         检测并安装，优先用便携版
 2  主机密钥                     生成或复用
 3  授权公钥                     写入 authorized_keys，修权限
 4  sshd_config                  生成配置（避开已知崩溃项）
 5  防火墙 / 默认 Shell          放行端口，设 PowerShell
 6  启动 SSH                     4 级自动降级 + banner 验证
 7  DSH                         可选，AI 辅助诊断运行时
 8  验证                         实际登录测试
 9  心跳上报                     装计划任务，5 分钟一次
10  守护进程                     装看门狗，30 秒一次
```

## 可选：DSH 集成

框架的 `agent.ps1` 支持调用 **DSH**（DeepSeek Harness）做 AI 辅助诊断：遇到没预见过的问题时，让 AI 读日志、自己查、自己修。

DSH 是独立的开源项目，本仓库**不包含其运行时**。如需此功能：

1. 从 DSH 官方仓库获取运行时
2. 在目标机部署到 `%USERPROFILE%\.dsh\runtime`
3. `agent.ps1` 会自动检测

不使用 DSH 时，`agent.ps1` 仍能按内置规则做基础修复。

## 已知限制

- **S4U 方式并非所有机器可用**：需要账户有密码历史。实测中部分克隆机器上注册成功但运行失败，脚本会自动降级。
- **部分机器的 SYSTEM 上下文损坏**：表现为 `SYSTEM` 身份跑任何东西都写不出文件。这种情况服务方式必然失败，只能退到用户身份方案（重启后需登录）。
- **`MachineGuid` 在克隆部署时会重复**：本框架用 `GUID + MAC` 组合规避，但如果多台机器的 MAC 也被克隆（极少见），仍会撞码。
- **控制台仅支持 Windows**：Tkinter + Win32 API 调用，未做跨平台适配。
- **Linux 部署脚本较简单**：只做基础 SSH 配置，没有 Windows 侧的完整降级链。

## 安全提示

- 框架传输的是**公钥**，私钥始终留在源端
- 心跳上报是**明文 HTTP**，设计用于可信内网。跨网段使用请自行加 TLS 或走 VPN
- 控制台的 HTTP 服务**没有认证**，不要暴露到公网
- 部署脚本会写入 `authorized_keys`，请确认源端私钥妥善保管

## 参考

- [踩坑记录](docs/PITFALLS.md) — 16 个真实问题及解法，建议先读
- [设计说明](docs/ARCHITECTURE.md) — 为什么这样设计
- [配置参考](docs/CONFIG.md) — 全部参数说明
- [PowerShell/Win32-OpenSSH](https://github.com/PowerShell/Win32-OpenSSH) — OpenSSH 便携版来源

## 许可

MIT
