<#
.SYNOPSIS
    自愈代理：让目标机上的 DSH 自己诊断和修复 SSH。
.DESCRIPTION
    设计目标：源端（我这台）不在线时，目标机也能自救。

    为什么不依赖 SSH：
      自愈要重启 sshd，而源端的入口就是 SSH。
      如果走 SSH 下发任务，自杀式重连会让任务中断。
      所以走两支通道：
        1) 共享目录队列（\\...\_agent-queue）
           源端写 .job 文件，目标机轮询执行，结果写 .result
        2) 计划任务定时触发（每 5 分钟）
           即使没有任务也要自检，发现 SSH 异常自动修

    为什么用 DSH 而不是写死规则：
      部署失败的形态太多（端口占用、配置错、权限、组件冲突）。
      写死的 if-else 只能覆盖已知情况；DSH 能读懂日志、自己查、
      自己改，能处理没预见过的问题。

.PARAMETER Mode
    check     只检查并报告（默认）
    heal      检查 + 异常时让 DSH 修复
    watch     与 heal 相同，但用于计划任务常驻调用
.PARAMETER Force
    跳过"SSH 正常就不动"的判断，强制执行一次 DSH 诊断
.PARAMETER UseDsh
    是否调用 DSH。默认开启。设为 $false 只跑内置规则修复（兜底）
#>
[CmdletBinding()]
param(
    [ValidateSet('check','heal','watch')]
    [string]$Mode = 'check',
    [switch]$Force,
    [bool]$UseDsh = $true,
    [string]$QueueShare = '' 
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ============================================================
# 路径与常量
# ============================================================
$HostName    = $env:COMPUTERNAME.ToLower()
$WorkDir     = 'C:\ProgramData\ssh-agent'
$LogDir      = Join-Path $WorkDir 'logs'
$StateFile   = Join-Path $WorkDir 'state.json'
# 队列路径优先取参数，其次环境变量，最后留空（仅定时自检）
if (-not $QueueShare) { $QueueShare = $env:FLEET_QUEUE_SHARE }
$QueueShare  = if ($QueueShare) { $QueueShare.TrimEnd("\") } else { "" }
$QueueLocal  = Join-Path $WorkDir 'queue'
$ResultDir   = Join-Path $WorkDir 'results'

$SshPort         = 22
$AltPort         = 2222
$SshdConfig      = 'C:\ProgramData\ssh\sshd_config'
$SshdExe         = 'C:\Program Files\OpenSSH\sshd.exe'
$SystemSshdExe   = "$env:SystemRoot\System32\OpenSSH\sshd.exe"
$LogonTask       = 'OpenSSH-Server-Logon'
$StandaloneDir   = 'C:\sshd-standalone'

# 初始化目录
foreach ($d in @($WorkDir, $LogDir, $QueueLocal, $ResultDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction SilentlyContinue | Out-Null }
}

$RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile  = Join-Path $LogDir "agent-$RunStamp.log"

# ============================================================
# 日志
# ============================================================
$script:LogLines = New-Object System.Collections.Generic.List[string]

function Log([string]$m, [string]$level = 'INFO') {
    $line = "[{0}] [{1,-4}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $level, $m
    $script:LogLines.Add($line)
    Write-Host $line
    try { [IO.File]::AppendAllText($LogFile, $line + "`r`n", [Text.Encoding]::UTF8) } catch { }
}
function Ok([string]$m)   { Log $m 'OK' }
function Warn([string]$m) { Log $m 'WARN' }
function Err([string]$m)  { Log $m 'ERR' }
function Tip([string]$m)  { Log $m 'TIP' }

# ============================================================
# 探测：SSH 是否真的能用
# ============================================================
function Test-SshBanner([int]$Port, [int]$TimeoutMs = 5000) {
    $tc = $null
    try {
        $tc = New-Object System.Net.Sockets.TcpClient
        $tc.ReceiveTimeout = $TimeoutMs
        $tk = $tc.ConnectAsync('127.0.0.1', $Port)
        $ok = $false
        try { $ok = $tk.Wait($TimeoutMs) } catch { }
        if (-not ($ok -and $tc.Connected)) { return @{ Ok = $false; Reason = 'tcp-fail' } }
        $st = $tc.GetStream()
        $buf = New-Object byte[] 128
        $n = 0
        try { $n = $st.Read($buf, 0, 128) } catch { $n = 0 }
        if ($n -gt 0) {
            $txt = [Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim()
            if ($txt -match '^SSH-') { return @{ Ok = $true; Banner = $txt } }
            return @{ Ok = $false; Reason = "unexpected-banner: $txt" }
        }
        return @{ Ok = $false; Reason = 'no-banner' }
    } catch {
        return @{ Ok = $false; Reason = "error: $($_.Exception.Message)" }
    } finally {
        if ($tc) { try { $tc.Close() } catch { } }
    }
}

function Test-TcpOpen([int]$Port, [int]$TimeoutMs = 3000) {
    $tc = $null
    try {
        $tc = New-Object System.Net.Sockets.TcpClient
        $tk = $tc.ConnectAsync('127.0.0.1', $Port)
        $ok = $false
        try { $ok = $tk.Wait($TimeoutMs) } catch { }
        return ($ok -and $tc.Connected)
    } catch { return $false }
    finally { if ($tc) { try { $tc.Close() } catch { } } }
}

# ============================================================
# 收集诊断信息
# ============================================================
function Get-Diagnostics {
    $d = [ordered]@{}

    $d.Timestamp = Get-Date -Format 'o'
    $d.Host = $HostName
    $d.Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $d.IsAdmin = ([Security.Principal.WindowsPrincipal](
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    # SSH 端口
    $d.Port22 = Test-SshBanner $SshPort
    $d.Port22Tcp = Test-TcpOpen $SshPort
    $d.Port2222 = Test-SshBanner $AltPort

    # 进程
    $procs = @(Get-Process sshd -ErrorAction SilentlyContinue)
    $d.SshdProcessCount = $procs.Count
    $d.SshdProcesses = @($procs | ForEach-Object {
        [ordered]@{ Id = $_.Id; Path = $_.Path; Start = "$($_.StartTime)" }
    })

    # 监听
    $listen = @(Get-NetTCPConnection -LocalPort $SshPort -State Listen -ErrorAction SilentlyContinue)
    $d.Port22Listener = @($listen | ForEach-Object {
        [ordered]@{ Addr = "$($_.LocalAddress)"; Pid = $_.OwningProcess }
    })

    # 服务
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if ($svc) {
        $wmi = Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue
        $d.Service = [ordered]@{
            Status    = "$($svc.Status)"
            StartType = "$($svc.StartType)"
            StartName = if ($wmi) { $wmi.StartName } else { '?' }
        }
    } else {
        $d.Service = $null
    }

    # 计划任务
    $d.LogonTask = $null
    $t = Get-ScheduledTask -TaskName $LogonTask -ErrorAction SilentlyContinue
    if ($t) { $d.LogonTask = @{ State = "$($t.State)" } }

    $d.StandaloneTask = $null
    $t2 = Get-ScheduledTask -TaskName 'sshd-standalone' -ErrorAction SilentlyContinue
    if ($t2) { $d.StandaloneTask = @{ State = "$($t2.State)" } }

    # 配置
    if (Test-Path $SshdConfig) {
        $d.Config = [ordered]@{
            Exists = $true
            Size = (Get-Item $SshdConfig).Length
            Modified = "$((Get-Item $SshdConfig).LastWriteTime)"
        }
        $syntax = & $SshdExe -t 2>&1
        $d.Config.SyntaxOk = ($LASTEXITCODE -eq 0)
        if ($LASTEXITCODE -ne 0) {
            $d.Config.SyntaxError = ($syntax | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' | '
        }
    } else {
        $d.Config = @{ Exists = $false }
    }

    # 密钥与公钥
    $d.HostKeys = @(Get-ChildItem 'C:\ProgramData\ssh' -Filter 'ssh_host_*_key' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notlike '*.pub' }).Count

    $ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
    $uk = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
    $d.AdminKeys = if (Test-Path $ak) { @(Get-Content $ak -ErrorAction SilentlyContinue | Where-Object { $_ -match 'ssh-|ecdsa-' }).Count } else { -1 }
    $d.UserKeys  = if (Test-Path $uk) { @(Get-Content $uk -ErrorAction SilentlyContinue | Where-Object { $_ -match 'ssh-|ecdsa-' }).Count } else { -1 }

    # 防火墙
    $fw = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'sshd|OpenSSH' })
    $d.FirewallRules = @($fw | ForEach-Object { [ordered]@{ Name = $_.DisplayName; Enabled = "$($_.Enabled)" } })

    # 磁盘
    try {
        $drive = Get-PSDrive C -ErrorAction Stop
        $d.DiskFreeGB = [math]::Round($drive.Free / 1GB, 1)
    } catch { $d.DiskFreeGB = -1 }

    return $d
}

function Format-Diagnostics($d) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("host=$($d.Host) identity=$($d.Identity) admin=$($d.IsAdmin)")
    [void]$sb.AppendLine("port22_banner_ok=$($d.Port22.Ok) reason=$($d.Port22.Reason) tcp=$($d.Port22Tcp)")
    [void]$sb.AppendLine("port2222_banner_ok=$($d.Port2222.Ok)")
    [void]$sb.AppendLine("sshd_processes=$($d.SshdProcessCount)")
    foreach ($p in $d.SshdProcesses) { [void]$sb.AppendLine("  pid=$($p.Id) path=$($p.Path)") }
    [void]$sb.AppendLine("listeners_on_22=$($d.Port22Listener.Count)")
    [void]$sb.AppendLine("service=$(if($d.Service){"$($d.Service.Status)/$($d.Service.StartType)/$($d.Service.StartName)"}else{'none'})")
    [void]$sb.AppendLine("logon_task=$(if($d.LogonTask){$d.LogonTask.State}else{'none'})")
    [void]$sb.AppendLine("standalone_task=$(if($d.StandaloneTask){$d.StandaloneTask.State}else{'none'})")
    [void]$sb.AppendLine("config_exists=$($d.Config.Exists) syntax_ok=$($d.Config.SyntaxOk)")
    if ($d.Config.SyntaxError) { [void]$sb.AppendLine("  syntax_error=$($d.Config.SyntaxError)") }
    [void]$sb.AppendLine("host_keys=$($d.HostKeys) admin_keys=$($d.AdminKeys) user_keys=$($d.UserKeys)")
    [void]$sb.AppendLine("firewall_rules=$($d.FirewallRules.Count)")
    foreach ($r in $d.FirewallRules) { [void]$sb.AppendLine("  $($r.Name) enabled=$($r.Enabled)") }
    [void]$sb.AppendLine("disk_free_gb=$($d.DiskFreeGB)")
    return $sb.ToString()
}

# ============================================================
# 内置规则修复（不依赖 DSH 的兜底）
# ============================================================
function Invoke-RuleBasedHeal {
    param($Diag)

    Log '--- 内置规则修复 ---'

    $actions = @()

    # 规则 1：没有 sshd 进程 -> 尝试按顺序拉起
    if ($Diag.SshdProcessCount -eq 0) {
        Warn '没有 sshd 进程，尝试拉起'

        if ($Diag.Service) {
            try {
                Start-Service sshd -ErrorAction Stop
                $actions += 'started-service'
                Ok '已启动 sshd 服务'
            } catch { Warn "服务启动失败: $($_.Exception.Message)" }
        } else {
            Warn 'sshd 服务未注册'
        }

        Start-Sleep -Seconds 3

        if (-not (Test-SshBanner $SshPort).Ok) {
            if ($Diag.LogonTask -and $Diag.LogonTask.State -ne 'Disabled') {
                try {
                    Start-ScheduledTask -TaskName $LogonTask -ErrorAction Stop
                    $actions += 'started-logon-task'
                    Ok '已触发登录触发器任务'
                } catch { Warn "任务触发失败: $($_.Exception.Message)" }
            }
        }
    }

    Start-Sleep -Seconds 2

    # 规则 2：进程在但无 banner（僵死）-> 全杀重拉
    $after = Test-SshBanner $SshPort
    if (-not $after.Ok -and (Test-TcpOpen $SshPort)) {
        Warn '端口通但无 SSH banner（僵死状态），清理后重拉'
        @(Get-Process sshd -ErrorAction SilentlyContinue) | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch { }
        }
        Start-Sleep -Seconds 3
        $actions += 'killed-zombie'

        if ($Diag.Service) {
            try { Start-Service sshd -ErrorAction Stop; $actions += 'restarted-service' } catch { }
        }
        if (-not (Test-SshBanner $SshPort).Ok -and $Diag.LogonTask) {
            try { Start-ScheduledTask -TaskName $LogonTask -ErrorAction Stop; $actions += 'restarted-task' } catch { }
        }
        if (-not (Test-SshBanner $SshPort).Ok -and (Test-Path (Join-Path $StandaloneDir 'sshd.exe'))) {
            try {
                $st = Get-ScheduledTask -TaskName 'sshd-standalone' -ErrorAction SilentlyContinue
                if ($st) { Start-ScheduledTask -TaskName 'sshd-standalone' -ErrorAction Stop; $actions += 'started-standalone' }
            } catch { }
        }
    }

    # 规则 3：配置语法错 -> 用内置模板覆盖
    if ($Diag.Config.Exists -and -not $Diag.Config.SyntaxOk) {
        Warn '配置语法错误，写入标准模板'
        $bak = "$SshdConfig.agentbak-$RunStamp"
        try {
            Copy-Item $SshdConfig $bak -Force -ErrorAction Stop
            Ok "已备份: $(Split-Path $bak -Leaf)"
        } catch { }

        $template = @(
            "# Rebuilt by self-heal agent $RunStamp",
            "Port $SshPort",
            "PasswordAuthentication no",
            "PubkeyAuthentication yes",
            "AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2",
            "HostKey __PROGRAMDATA__/ssh/ssh_host_rsa_key",
            "HostKey __PROGRAMDATA__/ssh/ssh_host_ed25519_key",
            "Subsystem sftp sftp-server.exe"
        )
        try {
            [IO.File]::WriteAllLines($SshdConfig, $template, (New-Object Text.UTF8Encoding($false)))
            $chk = & $SshdExe -t 2>&1
            if ($LASTEXITCODE -eq 0) {
                $actions += 'rebuilt-config'
                Ok '配置已重建并通过语法检查'
            } else {
                Err '重建后的配置仍有语法错误，恢复备份'
                Copy-Item $bak $SshdConfig -Force -ErrorAction SilentlyContinue
            }
        } catch { Err "写配置失败: $($_.Exception.Message)" }
    }

    # 规则 4：公钥丢失 -> 从备份或其他位置补
    if ($Diag.AdminKeys -le 0 -and $Diag.UserKeys -le 0) {
        Warn '没有可用公钥，SSH 无法登录'
        # 找现存公钥副本
        $srcCandidates = @(
            (Join-Path $WorkDir 'authorized_keys.backup'),
            "$SshdConfig.agentbak-keys"
        )
        foreach ($s in $srcCandidates) {
            if (Test-Path $s) {
                try {
                    Copy-Item $s 'C:\ProgramData\ssh\administrators_authorized_keys' -Force -ErrorAction Stop
                    & icacls 'C:\ProgramData\ssh\administrators_authorized_keys' /inheritance:r /grant 'SYSTEM:F' /grant 'Administrators:F' 2>&1 | Out-Null
                    $actions += 'restored-keys'
                    Ok '已从备份恢复公钥'
                    break
                } catch { }
            }
        }
    }

    # 规则 5：防火墙规则缺失
    if ($Diag.FirewallRules.Count -eq 0) {
        Warn '没有防火墙规则，补建'
        try {
            New-NetFirewallRule -Name "OpenSSH-Server-In-TCP-$SshPort" -DisplayName "OpenSSH Server (TCP $SshPort)" `
                -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort $SshPort -Profile Any -ErrorAction Stop | Out-Null
            $actions += 'added-firewall'
            Ok '已添加防火墙规则'
        } catch { Warn "加规则失败: $($_.Exception.Message)" }
    }

    return $actions
}

# ============================================================
# DSH 智能修复
# ============================================================
function Find-Node {
    $cands = @(
        'C:\Users\user\AppData\Local\Programs\node\node.exe'
    )
    # 遍历所有用户目录
    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -notin @('Public','Default','Default User','All Users')) {
            $cands += (Join-Path $_.FullName 'AppData\Local\Programs\node\node.exe')
            $cands += (Join-Path $_.FullName '.workbuddy\binaries\node\versions')
        }
    }
    foreach ($c in $cands) {
        if ($c -like '*versions') { continue }
        if (Test-Path $c) { return $c }
    }
    # 兜底：找 versions 目录下的 node
    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $v = Join-Path $_.FullName '.workbuddy\binaries\node\versions'
        if (Test-Path $v) {
            $n = Get-ChildItem $v -Filter 'node.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                 Select-Object -First 1
            if ($n) { return $n.FullName }
        }
    }
    $nc = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($nc) { return $nc.Source }
    return $null
}

function Find-DshEntry {
    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -notin @('Public','Default','Default User','All Users')) {
            $e = Join-Path $_.FullName '.dsh\runtime\node_modules\@deepseek-ai\dsh\lib\bin.js'
            if (Test-Path $e) { return $e }
        }
    }
    return $null
}

function Invoke-DshHeal {
    param($Diag, [string]$DiagnosticText, [string]$OperatorNote)

    Log '--- DSH 智能修复 ---'

    $node = Find-Node
    $dsh  = Find-DshEntry

    if (-not $node) { Warn 'DSH 不可用：找不到 node.exe'; return $null }
    if (-not $dsh)  { Warn 'DSH 不可用：找不到 dsh 入口'; return $null }

    Ok "node: $node"
    Ok "dsh : $dsh"

    # 找到真实用户 profile，DSH 需要它
    $userProfile = $null
    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -notin @('Public','Default','Default User','All Users')) {
            if (Test-Path (Join-Path $_.FullName '.dsh')) { $userProfile = $_.FullName }
        }
    }
    if ($userProfile) {
        $env:USERPROFILE = $userProfile
        $env:HOME = $userProfile
    }

    # 组装任务提示词
    $promptFile = Join-Path $WorkDir "prompt-$RunStamp.txt"
    $prompt = @"
你是运行在 Windows 机器 $HostName 上的运维代理。你的任务是让这台机器的 SSH 恢复正常。

## 当前诊断快照
$DiagnosticText

## 背景知识（务必遵守，这些是实测结论）

1. 这台机器的 sshd 可能来自两个位置：
   - 便携版：C:\Program Files\OpenSSH\sshd.exe （版本 10.0p2，优先用它）
   - 系统组件：C:\Windows\System32\OpenSSH\sshd.exe

2. 服务方式可行（已验证）：sshd 服务 AUTO_START + LocalSystem，开机即启。
   如果服务未注册，可用 C:\Program Files\OpenSSH\install-sshd.ps1 注册。

3. 如果服务方式失败，退到登录触发器任务 "OpenSSH-Server-Logon"。

4. 如果还失败，退到独立实例：C:\sshd-standalone\sshd.exe -D -f C:\sshd-standalone\sshd_config
   监听 2222 端口。计划任务名 "sshd-standalone"。

5. 绝对不要在 sshd_config 里使用 Match 块。某些机器上 Match Group administrators
   会触发 lookup_sid 1332 导致认证阶段崩溃。用全局 AuthorizedKeysFile 两路径代替。

6. Subsystem 必须写在所有 Match 之前（本配置没有 Match，但保持这个习惯）。

7. 判断 SSH 是否真的可用，唯一标准是：连 127.0.0.1:22 能读到以 SSH- 开头的 banner。
   只看端口 Listen 会误判僵死进程。

8. 端口语义：refused=没开；timeout=防火墙；reset=进程收到连接后崩溃；
   TCP通但无banner=僵死。

9. 改完任何配置后必须跑 sshd -t 校验语法，再 -T 确认生效值。

10. 改配置前必须备份到 sshd_config.agentbak-<时间戳>。

## 你的任务

诊断并用最小改动修复。可以执行命令、改文件、重启服务。

严格约束：
- 不要卸载或重装 OpenSSH 组件（可能触发重启）
- 不要改动其他用户的数据
- 不要删除 sshd_config 备份
- 不要打开不必要的端口
- 每一步改动前后都要验证 SSH 是否可用

最后必须输出一段总结，格式：

RESULT: <FIXED | PARTIAL | UNFIXED>
ACTIONS:
- <做了什么>
- <做了什么>
VERIFY: <banner 内容，或失败原因>
NOTES: <留给人的说明，如有>

## 操作者备注
$OperatorNote
"@

    try {
        [IO.File]::WriteAllText($promptFile, $prompt, (New-Object Text.UTF8Encoding($false)))
    } catch {
        Warn "写提示词失败: $($_.Exception.Message)"
        return $null
    }

    Log "提示词已写入: $promptFile"
    Log '调用 DSH（可能需要几分钟，请耐心等待）...'

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $outFile  = Join-Path $WorkDir "dsh-out-$RunStamp.txt"
    $wrapFile = Join-Path $WorkDir "dsh-call-$RunStamp.ps1"

    try {
        $shortPrompt = "读取文件 $promptFile 并严格按其中的指示执行。这是自动运维任务，请直接动手修复，不要只给建议。"

        # ------------------------------------------------------------
        # 关键：必须用 call operator（&）而不是 ProcessStartInfo 传参。
        # 实测对比（SERVER-A / node v24.19 / dsh 0.2.1-rc.5）：
        #   & $node $dsh --profile headless "..."   -> 秒回
        #   ProcessStartInfo + 引号拼接             -> 卡死 9 分钟
        # node 在 Windows 上对 CreateProcess 的引号解析与 cmd 不同，
        # 路径会被当成带尾空格的文件名（MODULE_NOT_FOUND）或直接挂住。
        #
        # 为了既避开引号问题、又能控制超时，这里生成一个临时包装脚本：
        # 参数以变量形式写进脚本正文，执行时完全没有拼接。
        # ------------------------------------------------------------
        $wrapper = @"
`$ErrorActionPreference = 'Continue'
`$node = '$node'
`$dsh  = '$dsh'
`$task = @'
$shortPrompt
'@
& `$node `$dsh --profile headless `$task 2>&1
exit `$LASTEXITCODE
"@
        [IO.File]::WriteAllText($wrapFile, $wrapper, (New-Object Text.UTF8Encoding($true)))

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = 'powershell.exe'
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$wrapFile`""
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        if ($userProfile) { $psi.WorkingDirectory = $userProfile }

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $null = $proc.Start()

        # 异步读，避免缓冲区满导致子进程阻塞
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit(1800000)) {
            try { $proc.Kill() } catch { }
            Warn 'DSH 执行超时（30 分钟），已终止'
            return $null
        }

        $stdout = $outTask.Result
        $stderr = $errTask.Result
        $sw.Stop()

        try {
            [IO.File]::WriteAllText($outFile,
                "STDOUT:`r`n$stdout`r`n`r`nSTDERR:`r`n$stderr",
                (New-Object Text.UTF8Encoding($false)))
            Remove-Item $wrapFile -Force -ErrorAction SilentlyContinue
        } catch { }

        Ok ("DSH 完成，耗时 {0:N0} 秒，退出码 {1}" -f $sw.Elapsed.TotalSeconds, $proc.ExitCode)

        $resultLine = ($stdout -split "`r?`n" | Where-Object { $_ -match 'RESULT\s*:' } | Select-Object -First 1)
        if ($resultLine) { Ok "DSH 结论: $($resultLine.Trim())" }

        return @{
            ExitCode   = $proc.ExitCode
            Elapsed    = [math]::Round($sw.Elapsed.TotalSeconds)
            Stdout     = $stdout
            Stderr     = $stderr
            Result     = $resultLine
            OutputFile = $outFile
        }
    } catch {
        $sw.Stop()
        Err "DSH 调用失败: $($_.Exception.Message)"
        return $null
    }
}

# ============================================================
# 队列：从共享读取任务
# ============================================================
function Get-PendingJobs {
    $jobs = @()
    $sources = @()

    if (Test-Path $QueueShare) { $sources += $QueueShare }
    if (Test-Path $QueueLocal) { $sources += $QueueLocal }

    foreach ($src in $sources) {
        Get-ChildItem $src -Filter '*.job' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $jobs += @{ File = $_.FullName; Name = $_.BaseName; Source = $src; Modified = $_.LastWriteTime }
        }
    }
    return $jobs
}

function Invoke-Job {
    param($Job)

    Log "执行任务: $($Job.Name)（来自 $($Job.Source)）"

    $content = ''
    try { $content = Get-Content $Job.File -Raw -ErrorAction Stop } catch {
        Err "读任务失败: $($_.Exception.Message)"
        return $null
    }

    # 任务格式：第一行可选 "TARGET=hostname"，其余为说明
    $target = 'any'
    $note = $content
    if ($content -match '(?m)^TARGET\s*=\s*(\S+)') {
        $target = $Matches[1].ToLower()
        $note = ($content -replace '(?m)^TARGET\s*=.*$', '').Trim()
    }

    if ($target -ne 'any' -and $target -ne $HostName) {
        Log "  跳过（任务目标 $target，本机 $HostName）"
        return $null
    }

    Log "  说明: $note"

    # 先诊断
    $diag = Get-Diagnostics
    $diagText = Format-Diagnostics $diag

    # 按任务类型处理
    $result = $null
    if ($content -match '(?i)MODE\s*=\s*dsh') {
        Log '  模式: DSH 智能诊断'
        $result = Invoke-DshHeal -Diag $diag -DiagnosticText $diagText -OperatorNote $note
    } else {
        Log '  模式: 内置规则（队列任务默认）'
        $actions = Invoke-RuleBasedHeal -Diag $diag
        $result = @{ Result = "RULE-BASED: $($actions -join ',')"; Actions = $actions }
    }

    # 写结果
    $resultObj = [ordered]@{
        Job       = $Job.Name
        Host      = $HostName
        Time      = (Get-Date -Format 'o')
        Target    = $target
        Note      = $note
        Before    = $diag
        Actions   = if ($result -and $result.Actions) { $result.Actions } else { @() }
        DshResult = if ($result -and $result.Result) { $result.Result } else { $null }
        After     = (Get-Diagnostics)
        Log       = $script:LogLines
    }

    $resultJson = $resultObj | ConvertTo-Json -Depth 8

    # 写到本地结果目录
    $localResult = Join-Path $ResultDir "$($Job.Name)-$RunStamp.json"
    try { [IO.File]::WriteAllText($localResult, $resultJson, (New-Object Text.UTF8Encoding($false))) } catch { }

    # 写到共享（源端读这个）
    if (Test-Path $QueueShare) {
        try {
            $shareResult = Join-Path $QueueShare "$($Job.Name).result"
            [IO.File]::WriteAllText($shareResult, $resultJson, (New-Object Text.UTF8Encoding($false)))
            Ok "结果已写回共享: $($Job.Name).result"
        } catch { Warn "写共享失败: $($_.Exception.Message)" }
    }

    # 删除已处理任务
    try {
        Remove-Item $Job.File -Force -ErrorAction SilentlyContinue
        Log '  任务文件已删除'
    } catch { }

    return $resultObj
}

# ============================================================
# 主流程
# ============================================================
Log '================================================'
Log "自愈代理启动  主机=$HostName  模式=$Mode"
Log "身份=$([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Log '================================================'

# ---- 步骤 1：处理队列任务（优先，因为那是明确指令）----
$jobs = @(Get-PendingJobs)
if ($jobs.Count -gt 0) {
    Log "发现 $($jobs.Count) 个待处理任务"
    foreach ($j in $jobs) {
        $null = Invoke-Job -Job $j
    }
} else {
    Log '队列为空'
}

# ---- 步骤 2：自检 ----
Log ''
Log '--- 自检 ---'
$diag = Get-Diagnostics
$diagText = Format-Diagnostics $diag

Log $diagText

$sshOk = $diag.Port22.Ok -or $diag.Port2222.Ok

# 保存状态
$state = [ordered]@{
    LastRun   = (Get-Date -Format 'o')
    SshOk     = $sshOk
    Port22Ok  = $diag.Port22.Ok
    Port2222Ok = $diag.Port2222.Ok
    Service   = $diag.Service
    LogonTask = $diag.LogonTask
    Diagnosis = $diag
}
try {
    [IO.File]::WriteAllText($StateFile, ($state | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
} catch { }

# ---- 步骤 3：决定是否修复 ----
if ($Mode -eq 'check') {
    Log ''
    if ($sshOk) { Ok 'SSH 正常（check 模式，不修复）' }
    else { Warn 'SSH 异常（check 模式，不修复）' }
}
elseif ($sshOk -and -not $Force) {
    Log ''
    Ok 'SSH 正常，无需修复'
}
else {
    Log ''
    if ($sshOk) { Warn 'SSH 正常，但 Force 指定强制诊断' }
    else { Warn 'SSH 异常，开始修复' }

    # 先跑内置规则（快，覆盖常见问题）
    $actions = Invoke-RuleBasedHeal -Diag $diag
    Start-Sleep -Seconds 3

    $afterRule = Get-Diagnostics
    $ruleFixed = $afterRule.Port22.Ok -or $afterRule.Port2222.Ok

    if ($ruleFixed) {
        Ok '内置规则已修复'
    } else {
        Warn '内置规则未能修复，交给 DSH'
        Start-Sleep -Seconds 2
        $dshResult = Invoke-DshHeal -Diag $afterRule `
            -DiagnosticText (Format-Diagnostics $afterRule) `
            -OperatorNote "内置规则已尝试：$($actions -join ', ')，但 SSH 仍不可用"

        if ($dshResult) {
            Log ''
            Log '--- DSH 输出摘要 ---'
            ($dshResult.Stdout -split "`r?`n" | Select-Object -Last 30) | ForEach-Object { Log $_ }
        }
    }

    # 最终验证
    Start-Sleep -Seconds 3
    $final = Get-Diagnostics
    $finalOk = $final.Port22.Ok -or $final.Port2222.Ok

    Log ''
    Log '--- 最终结果 ---'
    if ($finalOk) {
        Ok "SSH 已恢复  22端口=$($final.Port22.Ok)  2222端口=$($final.Port2222.Ok)"
    } else {
        Err 'SSH 仍未恢复，需要人工介入'
        Err "诊断文件: $StateFile"
        Err "日志目录: $LogDir"
    }
}

# ---- 步骤 4：写共享状态（让源端能远程看到）----
if (Test-Path $QueueShare) {
    try {
        $statusFile = Join-Path $QueueShare "status-$HostName.json"
        $status = [ordered]@{
            Host      = $HostName
            Time      = (Get-Date -Format 'o')
            SshOk     = $sshOk
            Port22Ok  = $diag.Port22.Ok
            Port2222Ok = $diag.Port2222.Ok
            Service   = $diag.Service
            LogonTask = $diag.LogonTask
            DiskFreeGB = $diag.DiskFreeGB
            LastLog   = $LogFile
        }
        [IO.File]::WriteAllText($statusFile, ($status | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

Log ''
Log '代理结束'
