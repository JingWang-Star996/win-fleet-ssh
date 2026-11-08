# 踩坑记录

这份文档记录了开发过程中真实遇到并解决的问题。每一条都来自实际环境，不是理论推演。

按主题分组，组内大致按严重程度排序。

---

## 一、SSH 服务装不上 / 起不来

### 1. 系统自带 OpenSSH 9.5 在认证阶段崩溃

**现象**

服务能启动，端口在监听，TCP 能连。但任何一次登录尝试都在认证阶段失败，事件日志里能看到：

```
sshd: fatal: lookup_sid: LookupAccountSid failed for account 'user' with error: 1332
```

错误码 1332 = `ERROR_NONE_MAPPED`，「找不到账户名到 SID 的映射」。

**为什么**

Windows 版 OpenSSH 在认证阶段要把用户名翻译成 SID。某些系统上这个翻译机制本身是坏的——受影响范围不止 sshd，任何需要做 SID 翻译的操作都会失败。

**怎么判断**

在目标机上用 SYSTEM 身份跑一段极简 PowerShell：

```powershell
[Security.Principal.WindowsIdentity]::GetCurrent().User.Translate(
    [Security.Principal.NTAccount])
```

抛异常就是坏的。

**解法**

用 [PowerShell/Win32-OpenSSH](https://github.com/PowerShell/Win32-OpenSSH/releases) 的便携版（10.x），它不依赖系统那个翻译路径。

框架里的 `deploy-all.ps1` 会先做这个探测，异常就跳过服务方式。

---

### 2. SYSTEM 身份跑不起来，用户身份却正常

**现象**

同一台机器、同一份配置：

| 版本 | SYSTEM 身份 | 用户身份 |
|---|---|---|
| 系统组件 9.5.6.4 | 失败，`ExitCode 1067` | 正常 |
| 便携版 10.0p2 | 失败，`START_PENDING` 后变成 `Stopped` | 正常 |

`1067` = `ERROR_PROCESS_ABORTED`，进程异常终止。

**关键认知**

**这不是版本问题。** 一开始以为是 9.5 的 bug，换便携版；结果便携版也一样崩。真正的原因是这台机器的 SYSTEM 上下文本身坏了——连用 SYSTEM 跑个 PowerShell 写文件都写不出来。

**解法**

服务方式在这类机器上永远走不通。只能退到用户身份方案：

- S4U 计划任务（免密码，开机触发）
- 登录触发器（需要有人登录桌面）
- 独立实例跑在备用端口

框架的做法是**部署前先探测 SYSTEM 健康度**，不健康就直接跳到 S4U，省掉几分钟无效尝试。

---

### 3. `sc create` 的参数永远拼不对

**现象**

```powershell
$binPath = '"C:\Program Files\OpenSSH\sshd.exe" -f "C:\ProgramData\ssh\sshd_config"'
sc.exe create sshd binPath= $binPath start= auto
```

`sc` 打印帮助信息，退出码 `1639`（`ERROR_INVALID_COMMAND_LINE`）。

**三个层次的坑，逐个踩过**

**第一层**：PowerShell 直传。`$binPath` 里有空格，被拆成多个 argv，`sc` 收到的 `binPath=` 后面只有 `"C:\Program`。

**第二层**：包了引号，但拼命令时又包一层，变成 `""C:\Program Files\...""`，双引号重复。仍然 `1639`。

**第三层**：用 `cmd /c` 执行整行，`cmd` 会先剥掉最外层引号，`sc` 收到的还是错。

**最终解法**

**放弃 `sc.exe`**，改用 WMI：

```powershell
$svc = Get-CimInstance Win32_Service -Filter "Name='sshd'"
Invoke-CimMethod -InputObject $svc -MethodName Change -Arguments @{
    PathName = '"C:\Program Files\OpenSSH\sshd.exe"'
}
```

或者新建服务时用 `New-Service -BinaryPathName`，它对空格完全友好。

**额外发现**：`sshd.exe` 默认就读 `C:\ProgramData\ssh\sshd_config`，根本不需要 `-f` 参数。去掉它，路径里就没有内部引号了，问题少一半。

---

### 4. `Stop-Service` 会无限等待

**现象**

```
Stop-Service sshd
```

卡住几分钟不返回。

**原因**

`Stop-Service` 没有默认超时。如果服务是「受保护」的（被其它服务依赖、或有看门狗在拉起），它会一直等到服务真的停下——而它可能永远不停。

**解法**

用 `sc.exe stop` + 自己控制等待：

```powershell
sc.exe stop sshd | Out-Null
for ($i = 0; $i -lt 15; $i++) {
    if (-not (Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Seconds 1
}
```

---

## 二、失联与恢复

### 5. 最贵的一次事故：先杀能用的，新方案失败

**事故经过**

要给一台机器把 sshd 从「前台进程」改成「Windows 服务」。脚本逻辑是：

```
1. 停掉正在工作的 sshd（释放 22 端口）
2. 创建服务并启动
3. 服务启动失败 → 机器彻底失联
```

结果服务创建成功但启动失败，而前台进程已经被杀掉了。机器活着（ping 通、3389/445 都开着），但 SSH 没了，只能人工到机器前处理。

**根因**

这是**顺序问题**，不是技术问题。验证未通过就拆掉退路。

**正确顺序**

```
1. 在备用端口（2222）启动候选方案
2. 验证 2222 能读到 SSH- banner   ← 关键闸门
3. 验证通过后，才停掉旧实例
4. 接管生产端口
5. 持续监控 60 秒，异常立即回滚
```

框架里 `ssh-start-adaptive.ps1` 就是按这个顺序写的。

**教训**：任何「切换」操作，都要先建立新通路，再拆除旧通路。反过来做，中间任何一个失败都是不可恢复的。

---

### 6. 守护进程和心跳都会进程爆炸

**现象**

控制台显示某台机器心跳异常，去看进程列表：

```
SERVER-A : 96 个 heartbeat-send.ps1 进程
另一台机器   : 23 个
```

同一秒内重复上报 8 次。

**原因**

`heartbeat-send.ps1` 的主体是 `while ($true)` 常驻循环。而计划任务每 10 分钟触发一次——**每次触发都新起一个永不退出的循环进程**。

`ssh-guardian.ps1` 有同样的问题。

**后果比想象的严重**

不只是重复上报。96 个 PowerShell 进程抢资源，导致 SSH 探测超时，**心跳误报 `sshd=False`**。

一开始以为是探测逻辑写错了，单独跑却是 `True`。清完进程立刻恢复正常。

**教训**：看到「功能误报」，先查进程数和资源占用，别急着改判定逻辑。

**解法**

命名 Mutex 做单实例锁，放在循环之前：

```powershell
$MutexName = 'Global\FleetHeartbeatMutex'
$m = New-Object System.Threading.Mutex($false, $MutexName)
if (-not $m.WaitOne(0, $false)) { exit 0 }   # 已有实例在跑，直接退出
```

**规则**：凡是被计划任务周期性触发的常驻脚本，必须加单实例锁。无例外。

---

### 7. 机器失联时，心跳是唯一的信息通道

**场景**

SSH 挂了，但你不知道机器还活着没、IP 是多少。

**为什么心跳能救**

心跳任务是独立的计划任务，不依赖 SSH、不依赖共享目录：

```
[10:11:11] sent OK ips=3 sshd=False   ← SSH 断着，心跳照常上报
[10:13:55] sent OK ips=3 sshd=True    ← 恢复后自动变 True
```

机器挂了 SSH 的 2 分钟里，心跳一直在报。至少能确认机器活着、当前 IP 是什么。

**设计要点**

心跳必须用 **SYSTEM 身份**跑。如果用当前用户身份，机器重启后没人登录就永远不上报，等于白装。

---

## 三、身份识别

### 8. `MachineGuid` 在克隆机器上会重复

**现象**

两台机器算出的机器码完全相同，登记时互相覆盖，控制台里只剩一台。

**排查**

```powershell
reg query "HKLM\SOFTWARE\Microsoft\Cryptography" /v MachineGuid
```

两台输出一模一样：`8ebba3f3-dedf-4768-96cf-10af53771028`。

**原因**

`MachineGuid` 在系统镜像里就被固化了。用同一个镜像克隆出来的机器，这个值完全相同。

原设计假设「每台机器的 GUID 唯一」，在克隆部署场景下不成立。

**解法**

`GUID + 物理网卡 MAC` 组合哈希：

```python
seed = "guid:" + guid
if mac:
    seed += "|mac:" + mac
machine_id = sha256(seed).hexdigest()[:16]
```

实测四台机器：GUID 有两台相同，MAC 全不同，机器码全部唯一。

**注意**：要排除虚拟网卡（VMware `00:50:56`、VirtualBox `08:00:27`、Hyper-V `00:15:5D`），它们会在机器间重复。

---

### 9. 不要用 BIOS 序列号做身份

**现象**

同一台机器两次采集，算出的机器码不一样，档案认不出是老机器。

**原因**

很多品牌机/组装机的 BIOS 序列号是占位值：

```
Default string
To be filled by O.E.M.
System Serial Number
```

某些工具会改写这个值（在占位值和真实值之间来回）。一旦参与哈希，机器码就漂移了。

**解法**

- 排除占位值（黑名单匹配）
- 不把 BIOS 序列号作为主要身份依据

---

## 四、PowerShell 与编码

### 10. `.ps1` 文件不能双击运行

**现象**

用户拿到 `restore-ssh.ps1`，双击没反应，或者用记事本打开了。

**原因**

Windows 默认把 `.ps1` 关联到编辑器，而不是 PowerShell 执行。而且即使关联对了，默认执行策略也可能是 `Restricted`。

**解法**

配一个 `.cmd` 包装器：

```batch
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-ssh.ps1"
pause
```

**要点**：

- `%~dp0` 是 cmd 文件自身所在目录，避免手输中文路径
- `-ExecutionPolicy Bypass` 绕过执行策略，不改系统设置
- `.cmd` 文件本身保存为 **ASCII**，避免代码页问题

---

### 11. 中文路径在 cmd 里的编码陷阱

**现象**

`.cmd` 文件里有中文路径，在某些机器上变成乱码，命令执行失败。

**原因**

`cmd.exe` 按当前活动代码页解析批处理文件内容。中文系统默认 936（GBK），但文件如果存成 UTF-8 就会乱码。

**解法**

- `.cmd` / `.bat` 文件**只用 ASCII 内容**，中文路径通过 `%~dp0` 相对引用，不写死
- 如果必须含中文，存成 GBK 编码
- **不要**在 `.cmd` 里用 `chcp 65001`——这会让 GBK 内容反而乱码

---

### 12. PowerShell 脚本的 UTF-8 BOM

**现象**

含中文的 `.ps1` 在某些机器上执行时报语法错误，错误信息里的中文是乱码。

**原因**

Windows PowerShell 5.1 对无 BOM 的 UTF-8 文件按 ANSI 代码页解析。中文变乱码后，字符串边界解析错乱，报「缺少终止符」。

**解法**

`.ps1` 文件保存为 **UTF-8 with BOM**。PowerShell 7+ 不需要，但为了兼容 5.1 还是加上。

---

### 13. 复杂引号嵌套导致解析失败

**现象**

```powershell
Write-Output "结果: $(if($x){'成功'}else{'失败'})"
```

在特定情况下报「缺少右 }」。

**原因**

PowerShell 的字符串插值里嵌套引号，中英文引号混用时解析器容易出错。

**解法**

拆开写：

```powershell
$status = if ($x) { '成功' } else { '失败' }
Write-Output "结果: $status"
```

或者用变量中转，避免在 `$()` 里嵌套引号。

---

## 五、远程操作

### 14. `scp` 需要 SFTP 子系统

**现象**

SSH 能登录（`ssh host hostname` 成功），但 `scp` 失败，退出码 255。

**原因**

`scp` 依赖 sshd 配置里的 `Subsystem sftp`。如果配置里缺这一行，或者 `sftp-server.exe` 路径不对，`scp` 就用不了。

**解法**

检查并补上：

```
Subsystem sftp sftp-server.exe
```

**临时绕过**：用 `ssh host "command"` 直接执行命令，不传文件。

---

### 15. `Start-Job` 里的进程会被回收

**现象**

用一个 Job 启动守护进程测试，看起来「进程启动后立刻退出了」，日志只写到一半。

**原因**

`Start-Job` 创建的作业在 PowerShell 会话结束时被清理，连带子进程一起杀掉。

**解法**

测试常驻进程要用**计划任务**启动，那才是真实运行环境。`Start-Job` 只能测短命脚本。

---

### 16. 触发 SSR 会话中断的操作要脱离会话执行

**现象**

重启 sshd 的脚本，通过 SSH 会话触发会导致连接断开，脚本自己也被中断（因为父会话没了）。

**解法**

用计划任务以 SYSTEM 身份执行，与 SSH 会话完全脱离：

```powershell
schtasks /create /tn "TaskName" /tr "powershell -File script.ps1" `
    /sc once /st 23:59 /ru SYSTEM /rl HIGHEST /f
schtasks /run /tn "TaskName"
```

脚本跑完自删任务即可。

---

## 六、Python 侧的坑

### 17. HTTP 接收端与 GUI 争抢同一端口

**现象**

控制台打开了，心跳也在上报，但界面里看不到新机器。

**原因**

开发时遗留了一个测试用的接收端进程，占着 18765 端口。控制台启动时绑不上，只把状态标红，不弹窗。心跳全被那个测试进程收走了。

**后果**：排查花了很久，因为「看起来像新机器没上报」，实际是「上报了但没人接」。

**解法**

- 端口绑定失败时**必须明确提示**用户，说清是谁占的
- 开发时的临时进程用完立刻清理

---

### 18. 接收端的数据只在内存里，GUI 重启就丢

**现象**

控制台重启后，之前收到的机器全部消失，只剩台账里的历史记录。

**原因**

心跳数据存在接收端的内存字典里，只在收到时更新台账。如果 GUI 重启，内存清空，需要等下一轮心跳（5 分钟）才能重新看到。

**解法**

接收端收到心跳时**立刻写盘**，不依赖 GUI 的生命周期。数据写盘和界面刷新要解耦。

---

## 附录：排查顺序建议

遇到「部署后连不上」，按这个顺序查：

```
1. 目标机还活着吗？          ping / 3389 / 445
2. 22 端口有监听吗？         netstat -ano | findstr :22
3. 有 sshd 进程吗？          tasklist | findstr sshd
4. 能读到 SSH banner 吗？    TCP 连上后看有没有 SSH- 开头
5. 登录报什么错？            ssh -v 看详细过程
6. 服务状态？                sc query sshd
7. 事件日志？                事件查看器 → 应用程序
```

关键区分：**端口通 ≠ 能连**。僵尸进程会让端口保持监听状态，但不响应任何请求。所以每一步都要验证到 `SSH-` banner。
