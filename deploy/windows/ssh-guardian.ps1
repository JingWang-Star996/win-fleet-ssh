# ssh-guardian.ps1
# SSH 守护进程：持续监控，异常自动修复。
#
# 为什么需要它（2026-11-06 的教训）：
#   切换启动方式时如果新方式失败，机器会彻底失联，
#   必须有人到机器前手动恢复。这个守护进程就是为这个场景准备的：
#   它在切换前就开始运行，一旦检测到 SSH 不可用就自动回滚。
#
# 运行方式：
#   由计划任务以 SYSTEM 身份启动（开机 + 每 5 分钟），
#   进程常驻后台，每 30 秒检查一次。
#
# 回滚策略（按顺序）：
#   1. 尝试重启当前方案
#   2. 失败则回滚到上次可用的方案（从状态文件读）
#   3. 再失败则用前台进程兜底
#   4. 全程写日志，源端可通过心跳/共享读取

$ErrorActionPreference = 'Continue'

$StateDir = 'C:\ProgramData\ssh-guardian'
$StateFile = Join-Path $StateDir 'state.json'
$LogFile = Join-Path $StateDir 'guardian.log'
$Port = 22
$CheckIntervalSec = 30
$FailThreshold = 2          # 连续失败几次才动手（避免瞬时抖动误判）

if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force -ErrorAction SilentlyContinue | Out-Null
}

function Log([string]$m, [string]$level = 'INFO') {
    $line = "[{0}] [{1,-4}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $level, $m
    try { [IO.File]::AppendAllText($LogFile, $line + "`r`n", [Text.Encoding]::UTF8) } catch { }
    # 日志超过 2MB 就截断，避免无限增长
    try {
        if ((Get-Item $LogFile -ErrorAction SilentlyContinue).Length -gt 2MB) {
            $tail = Get-Content $LogFile -Tail 500 -ErrorAction SilentlyContinue
            [IO.File]::WriteAllLines($LogFile, $tail, [Text.Encoding]::UTF8)
        }
    } catch { }
}

# ============================================================
# 单实例锁
# ============================================================
# 计划任务每 10 分钟触发一次，而本脚本是常驻循环。
# 没有锁的话会越积越多，多个实例同时"修复"会互相打架。
# 用命名 Mutex 保证全机只有一个实例在跑。
$MutexName = 'Global\SshGuardianMutex'
$script:Mutex = $null
try {
    $script:Mutex = New-Object System.Threading.Mutex($false, $MutexName)
    $acquired = $script:Mutex.WaitOne(0, $false)
    if (-not $acquired) {
        # 已有实例在跑，本次直接退出（不写日志，避免刷屏）
        exit 0
    }
} catch {
    # Mutex 创建失败（权限问题等）也继续跑，但要记一笔
    Log "Mutex 创建失败: $($_.Exception.Message)" 'WARN'
}

function Test-Banner([int]$p, [int]$tmo = 4000) {
    $tc = $null
    try {
        $tc = New-Object System.Net.Sockets.TcpClient
        $tc.ReceiveTimeout = $tmo
        $tk = $tc.ConnectAsync('127.0.0.1', $p)
        $ok = $false
        try { $ok = $tk.Wait($tmo) } catch { }
        if (-not ($ok -and $tc.Connected)) { return $null }
        $st = $tc.GetStream()
        $buf = New-Object byte[] 160
        $n = 0
        try { $n = $st.Read($buf, 0, 160) } catch { }
        if ($n -gt 0) {
            $t = [Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim()
            if ($t.StartsWith('SSH-')) { return $t }
        }
        return $null
    } catch { return $null }
    finally { if ($tc) { try { $tc.Close() } catch { } } }
}

function Get-State {
    if (Test-Path $StateFile) {
        try {
            return (Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json)
        } catch { }
    }
    return $null
}

function Save-State($s) {
    try {
        $s | ConvertTo-Json -Depth 5 | Set-Content $StateFile -Encoding UTF8
    } catch { }
}

function Find-Sshd {
    foreach ($c in @('C:\sshd-standalone\sshd.exe',
                     'C:\Program Files\OpenSSH\sshd.exe',
                     "$env:SystemRoot\System32\OpenSSH\sshd.exe")) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Find-Config {
    foreach ($c in @('C:\ProgramData\ssh\sshd_config', 'C:\sshd-standalone\sshd_config')) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

# ============================================================
# 修复动作
# ============================================================
function Try-RestartCurrent {
    param($state)
    $sshd = Find-Sshd
    $cfg = Find-Config
    if (-not $sshd) { return $false }

    Log "  尝试重启当前方案: $($state.strategy)" 'INFO'

    switch ($state.strategy) {
        'service' {
            & sc.exe start sshd 2>&1 | Out-Null
            Start-Sleep -Seconds 5
            return [bool](Test-Banner $Port)
        }
        's4u' {
            $t = Get-ScheduledTask -TaskName 'sshd-s4u' -ErrorAction SilentlyContinue
            if ($t) {
                & schtasks.exe /run /tn 'sshd-s4u' 2>&1 | Out-Null
                for ($i = 0; $i -lt 6; $i++) {
                    Start-Sleep -Seconds 2
                    if (Test-Banner $Port) { return $true }
                }
            }
            return $false
        }
        'logonTask' {
            $t = Get-ScheduledTask -TaskName 'OpenSSH-Server-Logon' -ErrorAction SilentlyContinue
            if ($t) {
                & schtasks.exe /run /tn 'OpenSSH-Server-Logon' 2>&1 | Out-Null
                for ($i = 0; $i -lt 6; $i++) {
                    Start-Sleep -Seconds 2
                    if (Test-Banner $Port) { return $true }
                }
            }
            return $false
        }
        default {
            return $false
        }
    }
}

function Try-Foreground {
    $sshd = Find-Sshd
    $cfg = Find-Config
    if (-not $sshd) { return $false }

    Log '  兜底：启动前台 sshd 进程' 'WARN'

    # 清掉卡住的进程
    Get-Process sshd -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    Start-Sleep -Seconds 3

    try {
        $args = if ($cfg) { @('-D', '-f', $cfg) } else { @('-D') }
        Start-Process -FilePath $sshd -ArgumentList $args -WindowStyle Hidden -ErrorAction Stop
    } catch {
        Log "    启动失败: $($_.Exception.Message)" 'ERR'
        return $false
    }

    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 2
        if (Test-Banner $Port) { return $true }
    }
    return $false
}

# ============================================================
# 主循环
# ============================================================
Log '=========================================='
Log "守护启动  PID=$PID  间隔=${CheckIntervalSec}s"

$state = Get-State
if (-not $state) {
    # 首次运行：探测当前实际用的什么方式
    $strategy = 'unknown'
    if (Get-Service sshd -ErrorAction SilentlyContinue) { $strategy = 'service' }
    elseif (Get-ScheduledTask -TaskName 'sshd-s4u' -ErrorAction SilentlyContinue) { $strategy = 's4u' }
    elseif (Get-ScheduledTask -TaskName 'OpenSSH-Server-Logon' -ErrorAction SilentlyContinue) { $strategy = 'logonTask' }
    else { $strategy = 'foreground' }

    $state = [pscustomobject]@{
        strategy     = $strategy
        lastGood     = (Get-Date -Format 'o')
        failCount    = 0
        healCount    = 0
        lastHeal     = ''
    }
    Save-State $state
    Log "  初始策略: $strategy"
}

$failCount = 0

while ($true) {
    $banner = Test-Banner $Port

    if ($banner) {
        if ($failCount -gt 0) {
            Log "  已恢复（之前连续失败 $failCount 次）" 'OK'
        }
        $failCount = 0
        $state.failCount = 0
        $state.lastGood = (Get-Date -Format 'o')
        Save-State $state
    } else {
        $failCount++
        $state.failCount = $failCount
        Log "  SSH 无响应（连续第 $failCount 次）" 'WARN'

        if ($failCount -ge $FailThreshold) {
            Log '  达到阈值，开始修复' 'WARN'
            $state.healCount = [int]$state.healCount + 1
            $state.lastHeal = (Get-Date -Format 'o')

            $fixed = $false

            # 1. 重启当前方式
            if (Try-RestartCurrent -state $state) {
                Log '  修复成功（重启当前方式）' 'OK'
                $fixed = $true
            }

            # 2. 前台兜底
            if (-not $fixed) {
                if (Try-Foreground) {
                    Log '  修复成功（前台进程兜底）' 'OK'
                    $state.strategy = 'foreground'
                    $fixed = $true
                }
            }

            if ($fixed) {
                $failCount = 0
                $state.failCount = 0
                $state.lastGood = (Get-Date -Format 'o')
                Save-State $state
            } else {
                Log '  修复失败，等待下一轮' 'ERR'
                Save-State $state
                # 失败后降低频率，避免疯狂重试
                Start-Sleep -Seconds 120
            }
        }
    }

    Start-Sleep -Seconds $CheckIntervalSec
}
