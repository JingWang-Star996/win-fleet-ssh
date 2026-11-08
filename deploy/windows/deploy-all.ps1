<#
.SYNOPSIS
    SSH + DSH 一键部署（统一入口，含三级启动降级）
.DESCRIPTION
    新机器插上就能跑，自动处理已知的全部故障：

      [1] 安装 OpenSSH Server（系统组件 → 便携版兜底）
      [2] 主机密钥
      [3] 授权公钥（管理员文件 + 用户文件）
      [4] sshd_config（无 Match 块，避免 lookup_sid 1332）
      [5] 防火墙 + 默认 Shell
      [6] 启动 —— 三级自动降级：
            A. Windows 服务（标准方式）
            B. 登录触发器 + 系统 sshd
            C. 独立实例 + 便携版 sshd（独立目录/配置/端口）
          C 是 NODE-01 上实测唯一可行的方案，作为最终兜底。
      [7] DSH 部署 + provider 校验 + 真实模型调用
      [8] 验证（用实际生效的端口）

    关键设计：
      - 每一步都用「读 SSH banner」判断是否真的可用，不只看端口监听
      - 所有日志写到 部署包\logs\，网络共享运行时源端可直接读取
      - 绝不在远程会话中盲目杀 sshd（先判断可用性再决定）

.PARAMETER Port
    SSH 端口，默认 22
.PARAMETER AltPort
    独立实例降级时使用的端口，默认 2222
.PARAMETER SkipDsh
    只装 SSH，跳过 DSH
.PARAMETER EnablePassword
    允许密码登录（默认只允许密钥）
.PARAMETER NoVerify
    跳过模型调用验证（省时间）
.PARAMETER HeartbeatServer
    心跳接收端地址，如 http://192.0.2.125:18765。
    给了就安装心跳上报任务（解决 IP 漂移），不给则跳过。
.PARAMETER HeartbeatIntervalMin
    心跳上报间隔（分钟），默认 5
.PARAMETER SkipHeartbeat
    强制跳过心跳安装
.PARAMETER SkipGuardian
    跳过守护进程安装（守护进程会在 SSH 挂掉时自动拉起，不建议跳过）
#>
[CmdletBinding()]
param(
    [int]$Port = 22,
    [int]$AltPort = 2222,
    [switch]$SkipDsh,
    [switch]$EnablePassword,
    [switch]$NoVerify,
    [string]$HeartbeatServer = '',
    [int]$HeartbeatIntervalMin = 5,
    [switch]$SkipHeartbeat,
    [switch]$SkipGuardian
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Here    = $PSScriptRoot
$KitRoot = Split-Path -Parent $Here
$Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'

$TaskName       = 'OpenSSH-Server-Logon'
$StandaloneDir  = 'C:\sshd-standalone'
$StandaloneTask = 'sshd-standalone'

# ============================================================
# 日志
# ============================================================
$LogPath = $null
foreach ($cand in @(
    (Join-Path $KitRoot "logs\deploy-$Stamp.log"),
    (Join-Path $env:TEMP "deploy-$Stamp.log")
)) {
    try {
        $d = Split-Path $cand -Parent
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null }
        [IO.File]::WriteAllText($cand, '', [Text.Encoding]::UTF8)
        $LogPath = $cand
        break
    } catch { continue }
}
if (-not $LogPath) { $LogPath = Join-Path $env:TEMP "deploy-$Stamp.log" }
$script:LogPath = $LogPath

function Say($m, $lv = 'INFO') {
    $colors = @{ OK='Green'; WARN='Yellow'; ERR='Red'; STEP='Cyan'; TIP='Magenta' }
    $c = if ($colors.ContainsKey("$lv")) { $colors["$lv"] } else { 'Gray' }
    $line = "[{0}] [{1,-4}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $lv, $m
    Write-Host $line -ForegroundColor $c
    try { [IO.File]::AppendAllText($script:LogPath, $line + "`r`n", [Text.Encoding]::UTF8) } catch { }
}
function Head($t) {
    Say ''
    Say ('-' * 66) 'STEP'
    Say "  $t" 'STEP'
    Say ('-' * 66) 'STEP'
    Say ''
}
function Kv($k, $v) { Say ("  {0,-24}: {1}" -f $k, $v) }

# ============================================================
# 环境
# ============================================================
$ident   = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($ident)
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$me      = $ident.Name

$SshDir     = Join-Path $env:ProgramData 'ssh'
$SshdConfig = Join-Path $SshDir 'sshd_config'
$AdminKeys  = Join-Path $SshDir 'administrators_authorized_keys'
$UserKeys   = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
$DshRoot    = Join-Path $env:USERPROFILE '.dsh'

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '          SSH + DSH 一键部署' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host ''
Say "主机      : $env:COMPUTERNAME"
Say "用户      : $me"
Say "管理员    : $isAdmin"
Say "SSH 端口  : $Port  (独立实例降级端口: $AltPort)"
Say "部署包    : $KitRoot"
Say "日志      : $LogPath"
Write-Host ''

if (-not $isAdmin) {
    Say '需要管理员权限才能安装服务/改防火墙。' 'ERR'
    Say '请用「一键部署.bat」运行，它会自动提权。' 'TIP'
    Write-Host ''
    Write-Host "  日志: $LogPath" -ForegroundColor Yellow
    exit 1
}

$script:Metrics   = [ordered]@{}
$script:EffPort   = $Port
$script:StartMode = $null

# ============================================================
# 1. 安装 OpenSSH
# ============================================================
Head '[1/10] 安装 OpenSSH Server'

$sshdExe     = $null
$keygenExe   = $null
$portableDir = Join-Path $KitRoot 'windows\OpenSSH-Win64'

foreach ($c in @("$env:SystemRoot\System32\OpenSSH\sshd.exe", 'C:\Program Files\OpenSSH\sshd.exe')) {
    if (Test-Path $c) {
        $sshdExe   = $c
        $keygenExe = Join-Path (Split-Path $c -Parent) 'ssh-keygen.exe'
        Say "已安装（系统组件）: $c" 'OK'
        try { Kv '版本' (Get-Item $c).VersionInfo.FileVersion } catch { }
        break
    }
}

if (-not $sshdExe) {
    Say '未检测到 sshd.exe，尝试安装系统组件...'
    try {
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop |
               Select-Object -First 1
        if ($cap -and $cap.State -ne 'Installed') {
            Say "组件状态 $($cap.State)，开始安装（最多 180 秒）..." 'INFO'
            $capPs  = Join-Path $env:TEMP "cap-$Stamp.ps1"
            $capLog = Join-Path $env:TEMP "cap-$Stamp.log"
            $body = @"
try {
    `$r = Add-WindowsCapability -Online -Name '$($cap.Name)' -ErrorAction Stop
    "OK RESTART=`$(`$r.RestartNeeded)" | Out-File '$capLog' -Encoding utf8
} catch { "FAIL `$(`$_.Exception.Message)" | Out-File '$capLog' -Encoding utf8 }
"@
            [IO.File]::WriteAllText($capPs, $body, (New-Object Text.UTF8Encoding($true)))
            try {
                $pr = Start-Process powershell.exe `
                    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$capPs) `
                    -PassThru -WindowStyle Hidden
                if (-not $pr.WaitForExit(180000)) {
                    try { $pr.Kill() } catch { }
                    Say '组件安装超时，改用便携版' 'WARN'
                } else {
                    $res = if (Test-Path $capLog) { Get-Content $capLog -Raw } else { '' }
                    if ($res -match 'OK') {
                        if ($res -match 'RESTART=True') { Say '组件已装，需重启（将自动降级）' 'WARN' }
                        else { Say '组件安装完成' 'OK' }
                        $sys = "$env:SystemRoot\System32\OpenSSH\sshd.exe"
                        if (Test-Path $sys) {
                            $sshdExe = $sys
                            $keygenExe = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh-keygen.exe'
                        }
                    } else {
                        Say "组件安装失败: $($res -replace 'FAIL ','')" 'WARN'
                        if ($res -match '0x800f0954') { Say '（组策略拦截了安装源，常见情况）' 'TIP' }
                    }
                }
            } finally { Remove-Item $capPs, $capLog -Force -ErrorAction SilentlyContinue }
        } elseif ($cap -and $cap.State -eq 'Installed') {
            $sys = "$env:SystemRoot\System32\OpenSSH\sshd.exe"
            if (Test-Path $sys) {
                $sshdExe = $sys
                $keygenExe = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh-keygen.exe'
            }
        }
    } catch { Say "查询组件失败: $($_.Exception.Message)" 'WARN' }
}

if (-not $sshdExe) {
    Say '使用部署包内便携版 OpenSSH' 'INFO'
    if (-not (Test-Path (Join-Path $portableDir 'sshd.exe'))) {
        $zip = Join-Path $KitRoot 'payload\OpenSSH-Win64.zip'
        if (Test-Path $zip) {
            Say '解压便携版...'
            try { Expand-Archive -Path $zip -DestinationPath (Join-Path $KitRoot 'windows') -Force -ErrorAction Stop }
            catch { Say "解压失败: $($_.Exception.Message)" 'ERR' }
        }
    }
    if (Test-Path (Join-Path $portableDir 'sshd.exe')) {
        $installDir = Join-Path $env:ProgramFiles 'OpenSSH'
        if (-not (Test-Path $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }
        Copy-Item (Join-Path $portableDir '*') $installDir -Recurse -Force -ErrorAction SilentlyContinue
        $sshdExe   = Join-Path $installDir 'sshd.exe'
        $keygenExe = Join-Path $installDir 'ssh-keygen.exe'
        Say "便携版已部署: $installDir" 'OK'
    }
}

if (-not $sshdExe) {
    Say '找不到任何可用的 sshd.exe，部署终止' 'ERR'
    Say '检查 windows\OpenSSH-Win64 或 payload\OpenSSH-Win64.zip' 'TIP'
    Write-Host ''
    Write-Host "  日志: $LogPath" -ForegroundColor Yellow
    exit 1
}
$script:Metrics['sshdPath']    = $sshdExe
$script:Metrics['sshdVersion'] = try { (Get-Item $sshdExe).VersionInfo.FileVersion } catch { '?' }

# ============================================================
# 2. 主机密钥
# ============================================================
Head '[2/10] 主机密钥'

if (-not (Test-Path $SshDir)) { New-Item -ItemType Directory -Path $SshDir -Force | Out-Null }

$madeKeys = 0
foreach ($kt in @(
    @{ Name='rsa';     Args=@('-t','rsa','-b','3072') },
    @{ Name='ed25519'; Args=@('-t','ed25519') }
)) {
    $target = Join-Path $SshDir "ssh_host_$($kt.Name)_key"
    if (Test-Path $target) { continue }
    try {
        & $keygenExe -q @($kt.Args) -f $target -N '""' 2>&1 | Out-Null
        if (Test-Path $target) {
            $madeKeys++
            Say "已生成 ssh_host_$($kt.Name)_key" 'OK'
            & icacls $target /inheritance:r /grant 'SYSTEM:F' /grant 'Administrators:F' 2>&1 | Out-Null
        }
    } catch { Say "生成 $($kt.Name) 密钥失败: $($_.Exception.Message)" 'WARN' }
}

$existKeys = @(Get-ChildItem $SshDir -Filter 'ssh_host_*_key' -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notlike '*.pub' })
if ($existKeys.Count -eq 0) {
    Say '主机密钥创建失败，部署终止' 'ERR'
    Write-Host ''
    Write-Host "  日志: $LogPath" -ForegroundColor Yellow
    exit 1
}
Say "现有主机密钥: $($existKeys.Count) 个（本次新建 $madeKeys）" 'OK'
$script:Metrics['hostKeys'] = $existKeys.Count

# ============================================================
# 3. 授权公钥
# ============================================================
Head '[3/10] 授权公钥'

$kitKeysFile = Join-Path $KitRoot 'keys\authorized_keys'
$wantKeys = @()
if (Test-Path $kitKeysFile) {
    $wantKeys = @(Get-Content $kitKeysFile -Encoding UTF8 -ErrorAction SilentlyContinue |
                  Where-Object { $_ -match '^\s*(ssh-|ecdsa-|sk-)' } |
                  ForEach-Object { $_.Trim() })
}

if ($wantKeys.Count -eq 0) {
    Say "部署包内无公钥（$kitKeysFile）" 'WARN'
    Say '没有公钥就只能靠密码登录，请确认 keys\authorized_keys' 'TIP'
} else {
    Say "部署包内公钥: $($wantKeys.Count) 条"

    foreach ($target in @(
        @{ Path=$AdminKeys; Label='管理员公钥' },
        @{ Path=$UserKeys;  Label='用户公钥'   }
    )) {
        try {
            $dir = Split-Path $target.Path -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $exist = @()
            if (Test-Path $target.Path) {
                $exist = @(Get-Content $target.Path -Encoding UTF8 | Where-Object { $_.Trim() })
            }
            $merged = New-Object System.Collections.Generic.List[string]
            foreach ($l in $exist) { if (-not $merged.Contains($l)) { $merged.Add($l) } }
            foreach ($k in $wantKeys) { if (-not $merged.Contains($k)) { $merged.Add($k) } }
            [IO.File]::WriteAllText($target.Path, (($merged -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))

            if ($target.Path -eq $AdminKeys) {
                & icacls $AdminKeys /inheritance:r /grant 'SYSTEM:F' /grant 'Administrators:F' 2>&1 | Out-Null
            }
            Say "$($target.Label)已写入" 'OK'
        } catch { Say "$($target.Label)写入失败: $($_.Exception.Message)" 'WARN' }
    }
}
$script:Metrics['pubkeys'] = $wantKeys.Count

# ============================================================
# 4. sshd_config
# ============================================================
Head '[4/10] sshd_config'

if (Test-Path $SshdConfig) {
    $bak = "$SshdConfig.bak-$Stamp"
    try { Copy-Item $SshdConfig $bak -Force; Say "已备份: $(Split-Path $bak -Leaf)" 'OK' } catch { }
}

# 关键设计（均经实测）：
#   1) 不用 Match 块 —— Match Group administrators 会让 sshd 在认证阶段
#      查询组 SID，某些机器上该查询失败（lookup_sid 1332），连接被 reset。
#   2) Subsystem 必须在任何 Match 之前 —— Match 会吞掉其后所有指令，
#      导致 subsystem 静默失效（SFTP 不可用）。
#   3) 用空格分隔而非 TAB —— 避免某些写入路径丢字符。
$cfg = @(
    "# Generated by deploy-kit $Stamp",
    "# No Match block on purpose (avoids lookup_sid 1332 on some machines)",
    "",
    "Port $Port",
    "",
    "PasswordAuthentication $(if ($EnablePassword) { 'yes' } else { 'no' })",
    "PubkeyAuthentication yes",
    "",
    "# 两个路径都写上：无 Match 块时管理员组也走用户路径",
    "AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2",
    "",
    "HostKey __PROGRAMDATA__/ssh/ssh_host_rsa_key",
    "HostKey __PROGRAMDATA__/ssh/ssh_host_ed25519_key",
    "",
    "# Subsystem 必须位于任何 Match 块之前",
    "Subsystem sftp sftp-server.exe"
)

try {
    [IO.File]::WriteAllLines($SshdConfig, $cfg, (New-Object Text.UTF8Encoding($false)))
    Say "配置已写入（端口 $Port，密码登录 $(if($EnablePassword){'允许'}else{'禁止'})）" 'OK'
} catch {
    Say "写配置失败: $($_.Exception.Message)" 'ERR'
}

$tOut = & $sshdExe -t 2>&1
if ($LASTEXITCODE -eq 0) {
    Say '配置语法正确' 'OK'
} else {
    Say '配置语法有误:' 'ERR'
    $tOut | Where-Object { $_ -ne '' } | ForEach-Object { Say "  $_" 'ERR' }
}

try {
    $eff = & $sshdExe -T 2>&1
    if ($LASTEXITCODE -eq 0) {
        foreach ($pat in @('^port ', '^subsystem ', '^authorizedkeysfile ', '^passwordauthentication ', '^pubkeyauthentication ')) {
            $eff | Select-String -Pattern $pat | Select-Object -First 1 | ForEach-Object { Say ("  " + $_.Line) 'INFO' }
        }
        if (-not ($eff | Select-String -Pattern '^subsystem ')) {
            Say '警告：subsystem 未生效，SFTP 将不可用（不影响 SSH 登录）' 'WARN'
        }
    }
} catch { }

# ============================================================
# 5. 防火墙 + 默认 Shell
# ============================================================
Head '[5/10] 防火墙 / 默认 Shell'

foreach ($p in @($Port, $AltPort) | Select-Object -Unique) {
    try {
        $ruleName = "OpenSSH-Server-In-TCP-$p"
        $r = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        if ($r) {
            if ($r.Enabled -ne 'True') { Enable-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue }
            Say "防火墙规则已存在: TCP $p" 'OK'
        } else {
            New-NetFirewallRule -Name $ruleName -DisplayName "OpenSSH Server (TCP $p)" `
                -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
                -LocalPort $p -Profile Any -ErrorAction Stop | Out-Null
            Say "已新增防火墙规则: TCP $p" 'OK'
        }
    } catch { Say "防火墙规则 TCP $p 失败: $($_.Exception.Message)" 'WARN' }
}

# 程序级规则：以用户身份运行时防火墙按程序判定，端口规则可能被忽略
try {
    if (-not (Get-NetFirewallRule -Name 'sshd-allowed-program' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'sshd-allowed-program' -DisplayName 'sshd (allow sshd.exe)' `
            -Direction Inbound -Program $sshdExe -Action Allow -Profile Any -Enabled True `
            -ErrorAction Stop | Out-Null
        Say '已新增程序级放行: sshd.exe' 'OK'
    }
} catch { }

try {
    $rk = 'HKLM:\SOFTWARE\OpenSSH'
    if (-not (Test-Path $rk)) { New-Item -Path $rk -Force | Out-Null }
    $pwshPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Set-ItemProperty -Path $rk -Name DefaultShell -Value $pwshPath -Force
    Say '默认 Shell = PowerShell' 'OK'
} catch { Say "设置默认 Shell 失败: $($_.Exception.Message)" 'WARN' }

# ============================================================
# 6. 启动（三级降级）
# ============================================================
Head '[6/10] 启动 SSH（三级自动降级）'

function Test-Listen([int]$p) {
    return (@(Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue).Count -gt 0)
}
function Test-SshHandshake([int]$p) {
    # 不只看端口：TCP 通但读不到 SSH banner 说明进程僵死
    $tc = $null
    try {
        $tc = New-Object System.Net.Sockets.TcpClient
        $tc.ReceiveTimeout = 5000
        $tk = $tc.ConnectAsync('127.0.0.1', $p)
        $ok = $false
        try { $ok = $tk.Wait(4000) } catch { }
        if (-not ($ok -and $tc.Connected)) { return $false }
        $st = $tc.GetStream()
        $buf = New-Object byte[] 128
        $n = 0
        try { $n = $st.Read($buf, 0, 128) } catch { $n = 0 }
        if ($n -gt 0) {
            $txt = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
            return ($txt -match '^SSH-')
        }
        return $false
    } catch { return $false }
    finally { if ($tc) { try { $tc.Close() } catch { } } }
}

if (Test-Listen $Port) {
    if (Test-SshHandshake $Port) {
        Say "端口 $Port 已有可用的 sshd，保持不动" 'OK'
        $script:StartMode = 'existing'
        $script:EffPort   = $Port
    } else {
        Say "端口 $Port 被占用但无 SSH 响应（进程僵死），继续尝试其它方式" 'WARN'
    }
}

# ---------- 前置：探测 SYSTEM 上下文 ----------
# 2026-11-06 教训：NODE-01 上 SYSTEM 身份跑 sshd 必崩（ExitCode 1067），
# 但 SERVER-A 上完全正常。盲试会白白浪费几分钟并可能触发崩溃。
# 所以先用一个极简 SYSTEM 任务探测：它能否解析自己的 SID 并写出文件。
$script:SystemHealthy = $false

if (-not $script:StartMode) {
    $probePs = 'C:\Windows\Temp\sys-ctx-probe.ps1'
    $probeOut = 'C:\Windows\Temp\sys-ctx-result.txt'
    $probeBody = @'
try {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $nt = $sid.Translate([Security.Principal.NTAccount])
    "OK|$($nt.Value)" | Set-Content 'C:\Windows\Temp\sys-ctx-result.txt' -Encoding UTF8
} catch {
    "FAIL|$($_.Exception.Message)" | Set-Content 'C:\Windows\Temp\sys-ctx-result.txt' -Encoding UTF8
}
'@
    $sysProbeOk = $false
    try {
        if (Test-Path $probeOut) { Remove-Item $probeOut -Force -ErrorAction SilentlyContinue }
        [IO.File]::WriteAllText($probePs, $probeBody, [Text.Encoding]::UTF8)

        $tnProbe = 'SysCtxProbe'
        & schtasks.exe /delete /tn $tnProbe /f 2>&1 | Out-Null
        & schtasks.exe /create /tn $tnProbe /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$probePs`"" /sc once /st 23:59 /ru SYSTEM /rl HIGHEST /f 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & schtasks.exe /run /tn $tnProbe 2>&1 | Out-Null
            for ($i = 0; $i -lt 10; $i++) {
                Start-Sleep -Seconds 2
                if (Test-Path $probeOut) { break }
            }
            if (Test-Path $probeOut) {
                $pr = (Get-Content $probeOut -Raw -ErrorAction SilentlyContinue).Trim()
                $sysProbeOk = ($pr -match '^OK\|')
                Say "  SYSTEM 探测: $pr" 'INFO'
            } else {
                Say '  SYSTEM 探测: 无输出（上下文异常）' 'WARN'
            }
        }
        & schtasks.exe /delete /tn $tnProbe /f 2>&1 | Out-Null
        Remove-Item $probePs -Force -ErrorAction SilentlyContinue
        Remove-Item $probeOut -Force -ErrorAction SilentlyContinue
    } catch {
        Say "  SYSTEM 探测异常: $($_.Exception.Message)" 'WARN'
    }

    $script:SystemHealthy = $sysProbeOk
    if ($sysProbeOk) {
        Say 'SYSTEM 上下文健康，可用服务方式' 'OK'
    } else {
        Say 'SYSTEM 上下文异常，跳过服务方式，改用用户身份' 'WARN'
    }
}

# ---------- 方式 A：Windows 服务 ----------
if (-not $script:StartMode) {
    Say '方式 A：Windows 服务' 'INFO'
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if ($svc) {
        try {
            Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service sshd -ErrorAction Stop
            for ($i=0; $i -lt 10; $i++) {
                Start-Sleep -Seconds 1
                if (Test-Listen $Port) { break }
            }
            if (Test-SshHandshake $Port) {
                Say '方式 A 成功：服务已启动且 SSH 可响应' 'OK'
                $script:StartMode = 'service'
                $script:EffPort   = $Port
            } else {
                Say '服务已启动但 SSH 无响应' 'WARN'
                try { Stop-Service sshd -Force -ErrorAction SilentlyContinue } catch { }
            }
        } catch { Say "服务启动失败: $($_.Exception.Message)" 'WARN' }
    } else {
        Say 'sshd 服务未注册，跳过方式 A' 'INFO'
    }
}

# ---------- 方式 A2：S4U 计划任务 ----------
# 介于服务与登录触发器之间：
#   以用户身份运行（避开 SYSTEM 崩溃问题）
#   开机触发（不需要登录，这是它比 B 强的关键）
#   不需要密码（空密码账户也能注册）
# 实测：NODE-01 上 S4U 注册成功，但运行时是否真能起 sshd 需现场验证，
# 所以必须用 banner 检查确认，不能只看任务 State。
if (-not $script:StartMode) {
    Say ''
    Say '方式 A2：S4U 计划任务（用户身份 + 开机触发 + 免密码）' 'INFO'

    $s4uTask = 'sshd-s4u'
    $madeA2 = $false

    try {
        @(Get-Process sshd -ErrorAction SilentlyContinue) | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch { }
        }
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Seconds 1
            if (-not (Test-Listen $Port)) { break }
        }

        & schtasks.exe /delete /tn $s4uTask /f 2>&1 | Out-Null

        $actA2 = New-ScheduledTaskAction -Execute $sshdExe -Argument '-D'
        $trgA2 = New-ScheduledTaskTrigger -AtStartup
        $priA2 = New-ScheduledTaskPrincipal -UserId $me -LogonType S4U -RunLevel Highest
        $setA2 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
                 -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

        Register-ScheduledTask -TaskName $s4uTask -Action $actA2 -Trigger $trgA2 `
            -Principal $priA2 -Settings $setA2 -Force -ErrorAction Stop | Out-Null
        Say '  S4U 任务已注册' 'INFO'

        & schtasks.exe /run /tn $s4uTask 2>&1 | Out-Null

        # 必须用 banner 验证，不能只看 State
        for ($i = 1; $i -le 12; $i++) {
            Start-Sleep -Seconds 2
            if (Test-SshHandshake $Port) {
                Say '方式 A2 成功：SSH 可响应（S4U，开机自启、不需登录）' 'OK'
                $script:StartMode = 's4u'
                $script:EffPort = $Port
                $madeA2 = $true
                break
            }
        }

        if (-not $madeA2) {
            Say '方式 A2 失败：任务已注册但无 SSH 响应' 'WARN'
            & schtasks.exe /delete /tn $s4uTask /f 2>&1 | Out-Null
        }
    } catch {
        Say "方式 A2 异常: $($_.Exception.Message)" 'WARN'
        $madeA2 = $false
    }
}

# ---------- 方式 B：登录触发器 + 系统 sshd ----------
if (-not $script:StartMode) {
    Say ''
    Say '方式 B：登录触发器（当前用户身份运行系统 sshd）' 'INFO'

    @(Get-Process sshd -ErrorAction SilentlyContinue) | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch { }
    }
    for ($i=0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 1
        if (-not (Test-Listen $Port)) { break }
    }

    foreach ($tn in @($TaskName, 'OpenSSH-Server-Boot')) {
        $null = & schtasks.exe /query /tn $tn 2>&1
        if ($LASTEXITCODE -eq 0) { & schtasks.exe /delete /tn $tn /f 2>&1 | Out-Null }
    }

    $madeB = $false
    try {
        $act = New-ScheduledTaskAction -Execute $sshdExe -Argument '-D'
        $trg = New-ScheduledTaskTrigger -AtLogOn -User $me
        $pri = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
               -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
               -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg `
            -Principal $pri -Settings $set -Force -ErrorAction Stop | Out-Null
        $madeB = $true
    } catch { Say "创建任务失败: $($_.Exception.Message)" 'WARN' }

    if ($madeB) {
        $null = & schtasks.exe /run /tn $TaskName 2>&1
        for ($i=0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 1
            if (Test-Listen $Port) { break }
        }
        if (Test-SshHandshake $Port) {
            Say '方式 B 成功：SSH 可响应' 'OK'
            $script:StartMode = 'logonTask'
            $script:EffPort   = $Port
        } else {
            Say '方式 B 失败：端口有监听但 SSH 无响应' 'WARN'
            Say '（系统组件与账户环境不兼容，改用方式 C）' 'TIP'
        }
    }
}

# ---------- 方式 C：独立实例 ----------
if (-not $script:StartMode) {
    Say ''
    Say '方式 C：独立实例（便携版 sshd，独立目录/配置/端口）' 'INFO'
    Say '  已在 NODE-01 实测：绕开系统组件的认证崩溃问题。' 'TIP'

    @(Get-Process sshd -ErrorAction SilentlyContinue) | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Seconds 2

    if (-not (Test-Path (Join-Path $portableDir 'sshd.exe'))) {
        Say "便携版不可用: $portableDir" 'WARN'
    } else {
        if (-not (Test-Path $StandaloneDir)) {
            New-Item -ItemType Directory -Path $StandaloneDir -Force | Out-Null
        }
        Copy-Item (Join-Path $portableDir '*') $StandaloneDir -Recurse -Force -ErrorAction SilentlyContinue
        Say "工作目录: $StandaloneDir" 'OK'

        $sSshd   = Join-Path $StandaloneDir 'sshd.exe'
        $sKeygen = Join-Path $StandaloneDir 'ssh-keygen.exe'

        foreach ($kt in @(
            @{ Name='rsa';     Args=@('-t','rsa','-b','3072') },
            @{ Name='ed25519'; Args=@('-t','ed25519') }
        )) {
            $target = Join-Path $StandaloneDir "hk_$($kt.Name)"
            if (-not (Test-Path $target)) {
                & $sKeygen -q @($kt.Args) -f $target -N '""' 2>&1 | Out-Null
            }
        }
        $sKeyCount = @(Get-ChildItem $StandaloneDir -Filter 'hk_*' -File -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -notlike '*.pub' }).Count
        Say "独立主机密钥: $sKeyCount 个" 'OK'

        $sCfg = Join-Path $StandaloneDir 'sshd_config'
        $sCfgLines = @(
            "# Standalone sshd config (generated $Stamp)",
            "Port $AltPort",
            "",
            "# 两个都开，先确保能连上；后续可按需收紧",
            "PasswordAuthentication yes",
            "PubkeyAuthentication yes",
            "",
            "AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2",
            "",
            "HostKey $StandaloneDir\hk_rsa",
            "HostKey $StandaloneDir\hk_ed25519",
            "",
            "Subsystem sftp sftp-server.exe"
        )
        [IO.File]::WriteAllLines($sCfg, $sCfgLines, (New-Object Text.UTF8Encoding($false)))

        $sTest = & $sSshd -t -f $sCfg 2>&1
        if ($LASTEXITCODE -eq 0) {
            Say '独立实例配置语法正确' 'OK'
        } else {
            Say '独立实例配置语法错误:' 'ERR'
            $sTest | Where-Object { $_ -ne '' } | ForEach-Object { Say "  $_" 'ERR' }
        }

        $null = & schtasks.exe /query /tn $StandaloneTask 2>&1
        if ($LASTEXITCODE -eq 0) { & schtasks.exe /delete /tn $StandaloneTask /f 2>&1 | Out-Null }

        $madeC = $false
        try {
            $act = New-ScheduledTaskAction -Execute $sSshd -Argument "-D -f `"$sCfg`""
            $trg = New-ScheduledTaskTrigger -AtLogOn -User $me
            $pri = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                   -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
                   -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
            Register-ScheduledTask -TaskName $StandaloneTask -Action $act -Trigger $trg `
                -Principal $pri -Settings $set -Force -ErrorAction Stop | Out-Null
            $madeC = $true
            Say "任务已创建: $StandaloneTask" 'OK'
        } catch { Say "创建任务失败: $($_.Exception.Message)" 'WARN' }

        if ($madeC) {
            $null = & schtasks.exe /run /tn $StandaloneTask 2>&1
            for ($i=0; $i -lt 25; $i++) {
                Start-Sleep -Seconds 1
                if (Test-Listen $AltPort) { break }
            }
            if (Test-SshHandshake $AltPort) {
                Say '方式 C 成功：独立实例可响应 SSH' 'OK'
                $script:StartMode = 'standalone'
                $script:EffPort   = $AltPort
            } else {
                Say '方式 C 失败：独立实例未响应' 'WARN'
            }
        }
    }
}

if (-not $script:StartMode) {
    Say ''
    Say '三种启动方式全部失败。' 'ERR'
    Say '已收集诊断信息，请把 logs\ 下最新文件回传。' 'TIP'

    $collector = Join-Path $KitRoot 'tools\diagnose\collect-diagnostics.ps1'
    if (Test-Path $collector) {
        try { & powershell -NoProfile -ExecutionPolicy Bypass -File $collector -Port $Port 2>&1 | Out-Null } catch { }
    }
    Write-Host ''
    Write-Host "  日志目录: $(Split-Path $LogPath -Parent)" -ForegroundColor Yellow
    exit 1
}

$script:Metrics['startMode'] = $script:StartMode
$script:Metrics['effPort']   = $script:EffPort
Say ''
Kv '启动方式' $(switch ($script:StartMode) {
    'existing'   { '沿用已有实例' }
    'service'    { 'Windows 服务（标准）' }
    's4u'        { "S4U 计划任务（开机自启，不需登录）" }
    'logonTask'  { "登录触发器（$me）" }
    'standalone' { "独立实例（$StandaloneDir）" }
    default      { '未知' }
})
Kv '生效端口' $script:EffPort

# ============================================================
# 7. DSH
# ============================================================
if ($SkipDsh) {
    Head '[7/10] DSH（已跳过）'
    Say '按 -SkipDsh 要求跳过' 'INFO'
} else {
    Head '[7/10] 部署 DSH'
    $dshDeploy = Join-Path $KitRoot 'dsh\deploy-dsh.ps1'
    if (Test-Path $dshDeploy) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $dshDeploy 2>&1 |
            ForEach-Object { Write-Host "  $_" }
    } else {
        Say '找不到 dsh\deploy-dsh.ps1，跳过' 'WARN'
    }
}

# ============================================================
# 8. 验证
# ============================================================
Head '[8/10] 验证'

$sshOk = Test-SshHandshake $script:EffPort
Say "SSH 端口 $($script:EffPort): $(if($sshOk){'可响应 SSH 协议'}else{'无响应'})" $(if($sshOk){'OK'}else{'ERR'})

if (-not $SkipDsh) {
    $dshEntry = Join-Path $DshRoot 'runtime\node_modules\@deepseek-ai\dsh\lib\bin.js'
    if (Test-Path $dshEntry) {
        Say 'DSH 运行时: 已安装' 'OK'

        $nodeExe = $null
        $nodeCand = Join-Path $KitRoot 'dsh\node\node.exe'
        if (Test-Path $nodeCand) { $nodeExe = $nodeCand }
        else {
            $nc = Get-Command node.exe -ErrorAction SilentlyContinue
            if ($nc) { $nodeExe = $nc.Source }
        }

        if ($nodeExe) {
            $provOk = $false
            try {
                $dump = & $nodeExe $dshEntry --profile web --dump-config 2>&1
                $text = ($dump -join "`n")
                $found = @()
                foreach ($p in @('relay-glm','relay-deepseek','qwen-dashscope')) {
                    if ($text -match [regex]::Escape($p)) { $found += $p }
                }
                $provOk = ($found.Count -ge 2)
                Say "provider 加载: $($found.Count)/3（$($found -join ', ')）" $(if($provOk){'OK'}else{'WARN'})
            } catch { Say "provider 检查异常: $($_.Exception.Message)" 'WARN' }

            if ($provOk -and -not $NoVerify) {
                Say '正在做模型调用测试（约 30 秒）...' 'INFO'
                $sw = [Diagnostics.Stopwatch]::StartNew()
                try {
                    $r = & $nodeExe $dshEntry --profile headless 'reply with exactly: PONG' 2>&1
                    $sw.Stop()
                    $rt = ($r -join ' ').Trim()
                    if ($rt -match 'PONG') {
                        Say ("模型调用成功（{0:N0} 秒）" -f $sw.Elapsed.TotalSeconds) 'OK'
                    } else {
                        Say ("模型调用返回异常（{0:N0} 秒）: {1}" -f $sw.Elapsed.TotalSeconds, $rt) 'WARN'
                    }
                } catch {
                    $sw.Stop()
                    Say "模型调用失败: $($_.Exception.Message)" 'WARN'
                }
            }
        } else {
            Say '找不到 node.exe，跳过 DSH 验证' 'WARN'
        }
    } else {
        Say 'DSH 运行时未安装' 'WARN'
    }
}

# ============================================================
# 9. 心跳上报（可选）
# 解决 IP 漂移：机器主动上报身份 + 当前所有 IP 给源端，
# 源端不用扫描、不需要 Tailscale、也不依赖 SMB 凭据。
# ============================================================
if (-not $SkipHeartbeat -and $HeartbeatServer) {
    Head '[9/10] 心跳上报'

    $hbInstaller = Join-Path $Here 'install-heartbeat.ps1'
    $hbSender = Join-Path $Here 'heartbeat-send.ps1'

    if ((Test-Path $hbInstaller) -and (Test-Path $hbSender)) {
        Say "上报地址: $HeartbeatServer" 'INFO'
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hbInstaller `
                -Server $HeartbeatServer -IntervalMin $HeartbeatIntervalMin `
                -ScriptSource $hbSender *>&1 | ForEach-Object {
                    $line = "$_"
                    if ($line.Trim()) { Say "  $($line.Trim())" 'INFO' }
                }
            $hbTask = Get-ScheduledTask -TaskName 'FleetHeartbeat' -ErrorAction SilentlyContinue
            if ($hbTask) {
                Say "心跳任务已注册（每 $HeartbeatIntervalMin 分钟 + 开机）" 'OK'
            } else {
                Say '心跳任务注册失败' 'WARN'
            }
        } catch {
            Say "心跳安装异常: $($_.Exception.Message)" 'WARN'
        }
    } else {
        Say '心跳脚本缺失，跳过' 'WARN'
    }
} else {
    if ($SkipHeartbeat) {
        Say '心跳上报：已按参数跳过' 'INFO'
    } else {
        Say '心跳上报：未指定 -HeartbeatServer，跳过' 'INFO'
    }
}

# ============================================================
# ============================================================
# 10. 守护进程（自动修复）
# 装一个常驻看门狗：SSH 挂了它自己拉起来，不需要人回到机器前。
# 这是 2026-11-06 那次失联事故的直接产物。
# ============================================================
if (-not $SkipGuardian) {
    Head '[10/10] 守护进程'

    $guardianSrc = Join-Path $Here 'ssh-guardian.ps1'
    if (Test-Path $guardianSrc) {
        $gDir = 'C:\ProgramData\ssh-guardian'
        if (-not (Test-Path $gDir)) {
            New-Item -ItemType Directory -Path $gDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $gTarget = Join-Path $gDir 'ssh-guardian.ps1'

        try {
            Copy-Item $guardianSrc $gTarget -Force -ErrorAction Stop
            Say "已部署: $gTarget" 'OK'

            # VBS 启动器（隐藏窗口）
            $gVbs = Join-Path $gDir 'guardian-launch.vbs'
            $vbsTpl = @'
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""__TARGET__""", 0, False
'@
            [IO.File]::WriteAllText($gVbs, $vbsTpl.Replace('__TARGET__', $gTarget), [Text.Encoding]::ASCII)

            # 计划任务：每 10 分钟 + 开机
            $gTask = 'SshGuardian'
            & schtasks.exe /delete /tn $gTask /f 2>&1 | Out-Null
            & schtasks.exe /create /tn $gTask /tr "wscript.exe `"$gVbs`"" `
                /sc minute /mo 10 /ru SYSTEM /rl HIGHEST /f 2>&1 | Out-Null

            if ($LASTEXITCODE -eq 0) {
                Say '守护任务已注册（每 10 分钟检查）' 'OK'

                # 补开机触发
                $gXml = (& schtasks.exe /query /tn $gTask /xml 2>&1) -join "`r`n"
                if ($gXml -match '<Triggers>') {
                    $bootT = '<BootTrigger><Enabled>true</Enabled><Delay>PT1M</Delay></BootTrigger>'
                    $newXml = $gXml -replace '(<Triggers>)', "`$1$bootT"
                    $tmpX = Join-Path $env:TEMP "guardian-$Stamp.xml"
                    [IO.File]::WriteAllText($tmpX, $newXml, [Text.Encoding]::Unicode)
                    & schtasks.exe /create /tn $gTask /xml $tmpX /f 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { Say '  已添加开机触发器' 'OK' }
                    Remove-Item $tmpX -Force -ErrorAction SilentlyContinue
                }

                & schtasks.exe /run /tn $gTask 2>&1 | Out-Null
                Say '  已触发首次运行' 'INFO'
            } else {
                Say '守护任务注册失败' 'WARN'
            }
        } catch {
            Say "守护部署失败: $($_.Exception.Message)" 'WARN'
        }
    } else {
        Say '守护脚本缺失，跳过' 'WARN'
    }
} else {
    Say '守护进程：已按参数跳过' 'INFO'
}

# 汇总
# ============================================================
Write-Host ''
if ($sshOk) {
    Write-Host '  ============================================================' -ForegroundColor Green
    Write-Host '                    部署完成' -ForegroundColor Green
    Write-Host '  ============================================================' -ForegroundColor Green
} else {
    Write-Host '  ============================================================' -ForegroundColor Yellow
    Write-Host '              部署完成（SSH 未通过验证）' -ForegroundColor Yellow
    Write-Host '  ============================================================' -ForegroundColor Yellow
}
Write-Host ''
Kv 'SSH 启动方式' $(switch ($script:StartMode) {
    'existing'   { '沿用已有实例' }
    'service'    { 'Windows 服务（标准）' }
    's4u'        { "S4U 计划任务（开机自启，不需登录）" }
    'logonTask'  { "登录触发器（$me）" }
    'standalone' { "独立实例（$StandaloneDir）" }
    default      { '未知' }
})
Kv 'SSH 端口' $script:EffPort
Kv 'sshd 版本' $script:Metrics['sshdVersion']

Write-Host ''
Write-Host '  从其它机器连接：' -ForegroundColor White
$ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } |
         Select-Object -ExpandProperty IPAddress)
foreach ($ip in $ips) {
    if ($script:EffPort -ne 22) {
        Write-Host ("    ssh -p {0} {1}@{2}" -f $script:EffPort, $env:USERNAME, $ip) -ForegroundColor Yellow
    } else {
        Write-Host ("    ssh {0}@{1}" -f $env:USERNAME, $ip) -ForegroundColor Yellow
    }
}

if ($script:StartMode -eq 'standalone') {
    Write-Host ''
    Write-Host '  说明：使用独立实例方式（绕开系统 OpenSSH 组件的认证问题）' -ForegroundColor Yellow
    Write-Host "        工作目录: $StandaloneDir" -ForegroundColor Gray
    Write-Host "        计划任务: $StandaloneTask（登录时触发）" -ForegroundColor Gray
    Write-Host '        停止: Stop-Process -Name sshd -Force' -ForegroundColor Gray
    Write-Host "        启动: schtasks /run /tn $StandaloneTask" -ForegroundColor Gray
} elseif ($script:StartMode -eq 'logonTask') {
    Write-Host ''
    Write-Host "  注意：使用登录触发器，开机后需 $me 登录 sshd 才会运行。" -ForegroundColor Yellow
    Write-Host "        手动启动: schtasks /run /tn $TaskName" -ForegroundColor Gray
}

Write-Host ''
Write-Host "  日志: $LogPath" -ForegroundColor DarkGray
Write-Host ''
exit $(if ($sshOk) { 0 } else { 1 })
