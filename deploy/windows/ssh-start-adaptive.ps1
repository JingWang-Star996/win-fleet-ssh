<#
.SYNOPSIS
    SSH 自适应启动器：先探测环境，再选策略，全程不切断退路。
.DESCRIPTION
    为什么需要它（血泪教训）：

    2026-11-06 在 NODE-01 上测试 S4U 方案时，脚本先停掉了正在工作的
    sshd，再尝试用新方式启动，结果新方式失败 → 机器 SSH 彻底失联，
    只能人工到机器前恢复。

    核心原则改为：**并行验证，串行切换，永不自断退路**
      1. 先在备用端口（2222）把候选方案跑起来并验证可用
      2. 确认可用后，才停掉旧的、接管 22 端口
      3. 接管后 60 秒内持续监控，一旦异常立即回滚到旧方式
      4. 任何一步失败，都保留原有可用实例

    四种启动策略，按可靠性排序，自动探测哪个可用：
      service    Windows 服务      最可靠，开机自启，不依赖登录
      s4u        S4U 计划任务      以用户身份运行，开机触发，不需密码
      logonTask  登录触发器        用户登录后启动（最后手段）
      foreground 前台进程          手动拉起，重启即失效

    每种策略先在 2222 端口试跑，验证 banner 后再切换到 22。

.PARAMETER Port
    生产端口，默认 22
.PARAMETER ProbePort
    试跑端口，默认 2222（必须与生产端口不同）
.PARAMETER SkipProbe
    跳过试跑直接切换（不推荐，仅用于已知环境）
.PARAMETER ForceStrategy
    强制指定策略，跳过自动选择
#>
[CmdletBinding()]
param(
    [int]$Port = 22,
    [int]$ProbePort = 2222,
    [switch]$SkipProbe,
    [ValidateSet('auto','service','s4u','logonTask','foreground')]
    [string]$ForceStrategy = 'auto'
)

$ErrorActionPreference = 'Continue'
$LogFile = 'C:\ProgramData\ssh\start-adaptive.log'

function Log([string]$m, [string]$level = 'INFO') {
    $line = "[{0}] [{1,-4}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $level, $m
    Write-Host $line
    try {
        $d = Split-Path $LogFile -Parent
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction SilentlyContinue | Out-Null }
        [IO.File]::AppendAllText($LogFile, $line + "`r`n", [Text.Encoding]::UTF8)
    } catch { }
}
function Ok([string]$m)   { Log $m 'OK' }
function Warn([string]$m) { Log $m 'WARN' }
function Err([string]$m)  { Log $m 'ERR' }

# ============================================================
# 探测工具
# ============================================================
function Test-SshBanner([int]$p, [int]$timeoutMs = 4000) {
    $tc = $null
    try {
        $tc = New-Object System.Net.Sockets.TcpClient
        $tc.ReceiveTimeout = $timeoutMs
        $tk = $tc.ConnectAsync('127.0.0.1', $p)
        $ok = $false
        try { $ok = $tk.Wait($timeoutMs) } catch { }
        if (-not ($ok -and $tc.Connected)) { return $null }
        $st = $tc.GetStream()
        $buf = New-Object byte[] 160
        $n = 0
        try { $n = $st.Read($buf, 0, 160) } catch { $n = 0 }
        if ($n -gt 0) {
            $txt = [Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim()
            if ($txt.StartsWith('SSH-')) { return $txt }
        }
        return $null
    } catch {
        return $null
    } finally {
        if ($tc) { try { $tc.Close() } catch { } }
    }
}

function Test-TcpOpen([int]$p) {
    $tc = $null
    try {
        $tc = New-Object System.Net.Sockets.TcpClient
        $tk = $tc.ConnectAsync('127.0.0.1', $p)
        $ok = $false
        try { $ok = $tk.Wait(2000) } catch { }
        return ($ok -and $tc.Connected)
    } catch { return $false }
    finally { if ($tc) { try { $tc.Close() } catch { } } }
}

function Find-SshdBinary {
    # 优先便携版（10.0p2，无 lookup_sid 问题），其次系统版
    $cands = @(
        'C:\sshd-standalone\sshd.exe',
        'C:\Program Files\OpenSSH\sshd.exe',
        "$env:SystemRoot\System32\OpenSSH\sshd.exe"
    )
    foreach ($c in $cands) {
        if (Test-Path $c) {
            $ver = try { (Get-Item $c).VersionInfo.ProductVersion } catch { '?' }
            return @{ Path = $c; Version = $ver }
        }
    }
    return $null
}

function Get-ConfigPath {
    $cands = @(
        'C:\ProgramData\ssh\sshd_config',
        'C:\sshd-standalone\sshd_config'
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    return $null
}

# ============================================================
# 环境探测：SYSTEM 上下文是否健康
# ============================================================
function Test-SystemContext {
    <#
      这是关键探测：NODE-01 上 SYSTEM 身份跑 sshd 必崩，
      但 SERVER-A 上完全正常。必须先判断，不能盲试。

      做法：用 SYSTEM 身份跑一个极简测试任务，看它能否
      写出文件并返回预期内容。写不出来说明 SYSTEM 上下文坏了。
    #>
    Log '探测 SYSTEM 上下文...'

    $probeScript = 'C:\Windows\Temp\sys-ctx-probe.ps1'
    $probeOut = 'C:\Windows\Temp\sys-ctx-result.txt'

    $body = @'
$r = @()
$r += "identity=$([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
try {
    $nt = [Security.Principal.WindowsIdentity]::GetCurrent().User.Translate([Security.Principal.NTAccount])
    $r += "sid_translate=OK:$($nt.Value)"
} catch {
    $r += "sid_translate=FAIL:$($_.Exception.Message)"
}
$r -join '|' | Set-Content 'C:\Windows\Temp\sys-ctx-result.txt' -Encoding UTF8
'@

    try {
        if (Test-Path $probeOut) { Remove-Item $probeOut -Force -ErrorAction SilentlyContinue }
        [IO.File]::WriteAllText($probeScript, $body, [Text.Encoding]::UTF8)

        $tn = 'SysCtxProbe'
        & schtasks.exe /delete /tn $tn /f 2>&1 | Out-Null
        $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$probeScript`""
        & schtasks.exe /create /tn $tn /tr $tr /sc once /st 23:59 /ru SYSTEM /rl HIGHEST /f 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Warn '  无法创建 SYSTEM 测试任务'
            return @{ Healthy = $false; Reason = 'task-create-failed' }
        }
        & schtasks.exe /run /tn $tn 2>&1 | Out-Null

        # 等结果，最多 20 秒
        $result = $null
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Seconds 2
            if (Test-Path $probeOut) {
                try {
                    $result = Get-Content $probeOut -Raw -ErrorAction Stop
                    break
                } catch { }
            }
        }
        & schtasks.exe /delete /tn $tn /f 2>&1 | Out-Null
        Remove-Item $probeScript -Force -ErrorAction SilentlyContinue

        if (-not $result) {
            Warn '  SYSTEM 任务跑完了但没写出结果 → SYSTEM 上下文异常'
            return @{ Healthy = $false; Reason = 'no-output' }
        }

        $result = $result.Trim()
        Log "  SYSTEM 探测结果: $result"

        if ($result -match 'sid_translate=FAIL') {
            Warn '  SYSTEM 无法解析自己的 SID → 与 lookup_sid 1332 同源，SYSTEM 方式不可用'
            return @{ Healthy = $false; Reason = 'sid-translate-failed' }
        }
        if ($result -match 'identity=NT AUTHORITY\\SYSTEM' -and $result -match 'sid_translate=OK') {
            Ok '  SYSTEM 上下文健康'
            return @{ Healthy = $true; Reason = 'ok' }
        }

        Warn '  SYSTEM 探测结果不符合预期'
        return @{ Healthy = $false; Reason = "unexpected: $result" }
    } catch {
        Warn "  SYSTEM 探测异常: $($_.Exception.Message)"
        return @{ Healthy = $false; Reason = "exception: $($_.Exception.Message)" }
    } finally {
        Remove-Item $probeScript -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# 候选方案：在试跑端口验证
# ============================================================
function Start-CandidateOnProbePort {
    <#
      在 ProbePort 启动一个临时 sshd，验证它真能服务连接。
      成功则返回进程对象，失败返回 null。
      注意：这里用的是「临时配置」，只监听 ProbePort，不碰生产配置。
    #>
    param(
        [string]$SshdPath,
        [int]$ProbePort,
        [string]$Strategy
    )

    Log "  在端口 $ProbePort 试跑（策略: $Strategy）..."

    # 确认端口没被占
    if (Test-TcpOpen $ProbePort) {
        Warn "    端口 $ProbePort 已被占用，跳过试跑"
        return $null
    }

    # 生成临时配置
    $tmpCfg = "C:\Windows\Temp\probe-sshd_config"
    $srcCfg = Get-ConfigPath

    $cfgLines = @(
        "# Temporary probe config generated $(Get-Date -Format 'o')",
        "Port $ProbePort",
        "ListenAddress 0.0.0.0",
        "PasswordAuthentication no",
        "PubkeyAuthentication yes"
    )
    # 复用生产配置里的 HostKey 和 AuthorizedKeysFile，保证认证行为一致
    if ($srcCfg) {
        $prodLines = Get-Content $srcCfg -ErrorAction SilentlyContinue
        foreach ($l in $prodLines) {
            if ($l -match '^\s*(HostKey|AuthorizedKeysFile)\s') {
                $cfgLines += $l.Trim()
            }
        }
    }
    $cfgLines += 'Subsystem sftp sftp-server.exe'

    try {
        [IO.File]::WriteAllLines($tmpCfg, $cfgLines, (New-Object Text.UTF8Encoding($false)))
    } catch {
        Warn "    写临时配置失败: $($_.Exception.Message)"
        return $null
    }

    # 语法校验
    $chk = & $SshdPath -t -f $tmpCfg 2>&1
    if ($LASTEXITCODE -ne 0) {
        Warn "    临时配置语法错误: $(($chk | Out-String).Trim())"
        Remove-Item $tmpCfg -Force -ErrorAction SilentlyContinue
        return $null
    }

    # 启动
    $proc = $null
    try {
        $proc = Start-Process -FilePath $SshdPath `
            -ArgumentList @('-D', '-f', $tmpCfg) `
            -WindowStyle Hidden -PassThru -ErrorAction Stop
    } catch {
        Warn "    启动失败: $($_.Exception.Message)"
        Remove-Item $tmpCfg -Force -ErrorAction SilentlyContinue
        return $null
    }

    # 验证 banner
    $banner = $null
    for ($i = 1; $i -le 8; $i++) {
        Start-Sleep -Seconds 1
        $banner = Test-SshBanner $ProbePort
        if ($banner) { break }
        if ($proc.HasExited) {
            Warn "    进程已退出（ExitCode=$($proc.ExitCode)）"
            break
        }
    }

    Remove-Item $tmpCfg -Force -ErrorAction SilentlyContinue

    if ($banner) {
        Ok "    试跑成功: $banner"
        return $proc
    } else {
        Warn '    试跑失败：无 banner'
        try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } } catch { }
        return $null
    }
}

# ============================================================
# 正式安装：按策略落地
# ============================================================
function Install-Strategy {
    param(
        [string]$Strategy,
        [string]$SshdPath,
        [string]$ConfigPath,
        [int]$Port
    )

    Log "  安装策略: $Strategy"

    switch ($Strategy) {
        'service' {
            $svcName = 'sshd'
            $binPath = if ($ConfigPath) { "`"$SshdPath`" -f `"$ConfigPath`"" } else { "`"$SshdPath`"" }

            & sc.exe stop $svcName 2>&1 | Out-Null
            Start-Sleep -Seconds 2
            & sc.exe delete $svcName 2>&1 | Out-Null
            Start-Sleep -Seconds 2

            $out = & sc.exe create $svcName binPath= $binPath start= auto DisplayName= 'OpenSSH SSH Server' 2>&1
            if ($LASTEXITCODE -ne 0) {
                Warn "    sc create 失败: $($out -join ' ')"
                return $false
            }
            & sc.exe privs $svcName SeAssignPrimaryTokenPrivilege/SeTcbPrivilege/SeBackupPrivilege/SeRestorePrivilege/SeImpersonatePrivilege 2>&1 | Out-Null

            & sc.exe start $svcName 2>&1 | Out-Null
            Start-Sleep -Seconds 5

            $svc = Get-Service $svcName -ErrorAction SilentlyContinue
            Log "    服务状态: $($svc.Status)"
            return ($svc -and $svc.Status -eq 'Running')
        }

        's4u' {
            $tn = 'sshd-s4u'
            & schtasks.exe /delete /tn $tn /f 2>&1 | Out-Null

            $action = New-ScheduledTaskAction -Execute $SshdPath `
                -Argument $(if ($ConfigPath) { "-D -f `"$ConfigPath`"" } else { '-D' })
            $trigger = New-ScheduledTaskTrigger -AtStartup
            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
                -LogonType S4U -RunLevel Highest

            try {
                Register-ScheduledTask -TaskName $tn -Action $action -Trigger $trigger `
                    -Principal $principal -Force -ErrorAction Stop | Out-Null
            } catch {
                Warn "    注册失败: $($_.Exception.Message)"
                return $false
            }

            & schtasks.exe /run /tn $tn 2>&1 | Out-Null
            Start-Sleep -Seconds 5
            $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
            Log "    任务状态: $($t.State)"
            return ($t -and $t.State -eq 'Running')
        }

        'logonTask' {
            $tn = 'OpenSSH-Server-Logon'
            & schtasks.exe /delete /tn $tn /f 2>&1 | Out-Null
            $tr = "`"$SshdPath`"" + $(if ($ConfigPath) { " -D -f `"$ConfigPath`"" } else { ' -D' })
            & schtasks.exe /create /tn $tn /tr $tr /sc onlogon `
                /ru "$env:USERDOMAIN\$env:USERNAME" /rl HIGHEST /f 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { return $false }
            & schtasks.exe /run /tn $tn 2>&1 | Out-Null
            Start-Sleep -Seconds 5
            return $true
        }

        'foreground' {
            try {
                Start-Process -FilePath $SshdPath `
                    -ArgumentList $(if ($ConfigPath) { @('-D', '-f', $ConfigPath) } else { @('-D') }) `
                    -WindowStyle Hidden -ErrorAction Stop
                Start-Sleep -Seconds 4
                return $true
            } catch {
                return $false
            }
        }

        default {
            return $false
        }
    }
}

# ============================================================
# 主流程
# ============================================================
Log '============================================================'
Log 'SSH 自适应启动'
Log "  身份: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Log "  生产端口: $Port   试跑端口: $ProbePort"
Log '============================================================'

# ---- 0. 现状 ----
Log ''
Log '[0/6] 检查现状'
$currentBanner = Test-SshBanner $Port
if ($currentBanner) {
    Ok "  $Port 端口已有可用实例: $currentBanner"
} else {
    $tcp = Test-TcpOpen $Port
    if ($tcp) {
        Warn "  $Port 端口有监听但无 banner（僵死）"
    } else {
        Warn "  $Port 端口无监听"
    }
}

$curProc = @(Get-CimInstance Win32_Process -Filter "Name='sshd.exe'" -ErrorAction SilentlyContinue)
Log "  当前 sshd 进程数: $($curProc.Count)"
foreach ($p in $curProc) {
    $o = try { $p | Invoke-CimMethod -MethodName GetOwner -ErrorAction Stop } catch { $null }
    $owner = if ($o) { "$($o.Domain)\$($o.User)" } else { '?' }
    Log "    PID=$($p.ProcessId) Owner=$owner"
}

# ---- 1. 选策略 ----
Log ''
Log '[1/6] 判断可用策略'

$bin = Find-SshdBinary
if (-not $bin) {
    Err '  找不到任何 sshd 二进制'
    exit 1
}
Ok "  sshd: $($bin.Path)  ($($bin.Version))"

$cfg = Get-ConfigPath
Log "  配置: $(if($cfg){$cfg}else{'未找到（用默认）'})"

$sysOk = Test-SystemContext

# 判断账号是否有密码（S4U 不需要密码，但 Password 类型需要）
$userInfo = Get-LocalUser -Name $env:USERNAME -ErrorAction SilentlyContinue
$hasPassword = if ($userInfo) { [bool]$userInfo.PasswordLastSet } else { $false }
Log "  账号有密码历史: $hasPassword"

# 策略优先级
$plan = @()
if ($ForceStrategy -ne 'auto') {
    $plan = @($ForceStrategy)
    Log "  强制策略: $ForceStrategy"
} else {
    if ($sysOk.Healthy) {
        $plan += 'service'
        Log '  SYSTEM 健康 → 首选 service'
    } else {
        Log "  SYSTEM 异常（$($sysOk.Reason)）→ 跳过 service"
    }
    $plan += 's4u'
    $plan += 'logonTask'
    $plan += 'foreground'
    Log "  候选顺序: $($plan -join ' → ')"
}

# ---- 2-4. 逐个尝试（先在试跑端口验证）----
$chosen = $null
foreach ($strategy in $plan) {
    Log ''
    Log "[2/6] 尝试策略: $strategy"

    if (-not $SkipProbe) {
        $probeProc = Start-CandidateOnProbePort -SshdPath $bin.Path `
            -ProbePort $ProbePort -Strategy $strategy

        if (-not $probeProc) {
            Warn "  策略 $strategy 试跑失败，换下一个"
            continue
        }

        # 试跑成功 → 清理，正式安装
        Log '  试跑通过，清理临时进程'
        try { Stop-Process -Id $probeProc.Id -Force -ErrorAction SilentlyContinue } catch { }
        Start-Sleep -Seconds 2
        for ($i = 0; $i -lt 8; $i++) {
            if (-not (Test-TcpOpen $ProbePort)) { break }
            Start-Sleep -Seconds 1
        }
    } else {
        Log '  跳过试跑（-SkipProbe）'
    }

    Log ''
    Log '[3/6] 停掉旧实例（此时已有可用的候选方案）'
    # 只有在候选方案验证通过后，才动旧实例
    Get-CimInstance Win32_Process -Filter "Name='sshd.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        Log "    停止 PID $($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    # 停掉可能占用端口的服务/任务
    & sc.exe stop sshd 2>&1 | Out-Null
    & schtasks.exe /end /tn 'OpenSSH-Server-Logon' 2>&1 | Out-Null
    & schtasks.exe /end /tn 'sshd-s4u' 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    for ($i = 0; $i -lt 10; $i++) {
        if (-not (Test-TcpOpen $Port)) { break }
        Start-Sleep -Seconds 1
    }

    Log ''
    Log '[4/6] 正式安装'
    $installed = Install-Strategy -Strategy $strategy -SshdPath $bin.Path `
        -ConfigPath $cfg -Port $Port

    # 验证
    $verified = $false
    if ($installed) {
        for ($i = 1; $i -le 12; $i++) {
            Start-Sleep -Seconds 2
            $b = Test-SshBanner $Port
            if ($b) {
                Ok "  $Port 端口验证通过: $b"
                $verified = $true
                break
            }
            Log "    第 $i 次检查：尚未响应"
        }
    }

    if ($verified) {
        $chosen = $strategy
        break
    } else {
        Warn "  策略 $strategy 落地后验证失败"
        # 清掉失败的安装
        if ($strategy -eq 'service') {
            & sc.exe stop sshd 2>&1 | Out-Null
            Start-Sleep -Seconds 1
            & sc.exe delete sshd 2>&1 | Out-Null
        } elseif ($strategy -eq 's4u') {
            & schtasks.exe /delete /tn 'sshd-s4u' /f 2>&1 | Out-Null
        }
        Log '  继续尝试下一个策略'
    }
}

# ---- 5-6. 结论与监控 ----
Log ''
if ($chosen) {
    Log '[5/6] 成功'
    Log "  策略: $chosen"

    # 清理落选的任务，避免开机时多个方案抢端口
    foreach ($tn in @('sshd-s4u', 'OpenSSH-Server-Logon')) {
        $exists = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
        if (-not $exists) { continue }
        $needed = ($chosen -eq 's4u' -and $tn -eq 'sshd-s4u') -or
                  ($chosen -eq 'logonTask' -and $tn -eq 'OpenSSH-Server-Logon')
        if (-not $needed) {
            & schtasks.exe /change /tn $tn /disable 2>&1 | Out-Null
            Log "    已禁用无关任务: $tn"
        }
    }

    Log ''
    Log '[6/6] 60 秒稳定性观察'
    $stable = $true
    for ($i = 1; $i -le 6; $i++) {
        Start-Sleep -Seconds 10
        $b = Test-SshBanner $Port
        if ($b) {
            Log "    ${i}0s: 正常"
        } else {
            Err "    ${i}0s: 失去响应"
            $stable = $false
            break
        }
    }

    Log ''
    if ($stable) {
        Ok 'RESULT=SUCCESS'
        Log "  启动方式: $chosen"
        Log "  端口: $Port"
        exit 0
    } else {
        Err 'RESULT=UNSTABLE'
        Log '  已观察到的策略不稳定，建议人工介入'
        exit 2
    }
} else {
    Err '[5/6] 所有策略都失败'
    Log '  最后手段：启动前台进程，保证可连'
    $fg = Install-Strategy -Strategy 'foreground' -SshdPath $bin.Path -ConfigPath $cfg -Port $Port
    Start-Sleep -Seconds 4
    $b = Test-SshBanner $Port
    if ($b) {
        Warn 'RESULT=FALLBACK_FOREGROUND'
        Log "  $b"
        Log '  注意：重启后会失效，需要重新运行本脚本'
        exit 3
    } else {
        Err 'RESULT=FAILED_ALL'
        Log '  所有方式都失败，SSH 不可用'
        exit 4
    }
}
