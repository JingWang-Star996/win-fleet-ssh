<#
.SYNOPSIS
    心跳上报：把本机身份和当前所有 IP 发给源端。
.DESCRIPTION
    为什么需要它：
      - 算力机器不接 Tailscale（安全边界）
      - LAN IP 每次重启可能变
      - 共享目录因凭据问题访问不了
      所以让机器主动上报，源端不用去找它。

    注册方式：
      计划任务，登录时 + 每 5 分钟触发。
      不依赖 sshd，也不依赖源端在线。

.PARAMETER Server
    源端地址，默认 192.0.2.125:18765（实测目标机可反向 ping 通）
.PARAMETER Once
    只发一次就退出（用于手动测试）
#>
[CmdletBinding()]
param(
    [string]$Server = 'http://192.0.2.125:18765',
    [string]$Token = '',
    [switch]$Once,
    [int]$IntervalSec = 300
)

$ErrorActionPreference = 'Continue'
$StateDir = 'C:\ProgramData\ssh-agent'
if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force -ErrorAction SilentlyContinue | Out-Null
}
$LogFile = Join-Path $StateDir 'heartbeat.log'

function Log([string]$m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    try {
        [IO.File]::AppendAllText($LogFile, $line + "`r`n", [Text.Encoding]::UTF8)
    } catch { }
}

function Get-Identity {
    $g = ''
    try {
        $g = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -ErrorAction Stop).MachineGuid
    } catch { }
    $b = ''
    try {
        $b = (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
    } catch { }
    $v = ''
    try {
        $v = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue).VolumeSerialNumber
    } catch { }
    $mac = ''
    try {
        $mac = (Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Up' } |
                Select-Object -First 1).MacAddress
    } catch { }

    return [ordered]@{
        machineGuid  = if ($g) { $g.ToString().ToLower() } else { '' }
        biosSerial   = if ($b) { "$b".Trim() } else { '' }
        volumeSerial = if ($v) { "$v".Trim() } else { '' }
        mac          = if ($mac) { "$mac".Trim() } else { '' }
        hostname     = $env:COMPUTERNAME
    }
}

function Get-AllIPv4 {
    $ips = @()
    try {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.IPAddress -notmatch '^127\.' -and
                $_.IPAddress -notmatch '^169\.254\.' -and
                $_.PrefixOrigin -ne 'WellKnown'
            } |
            ForEach-Object {
                $ips += [ordered]@{
                    ip     = $_.IPAddress
                    alias  = $_.InterfaceAlias
                    prefix = $_.PrefixLength
                }
            }
    } catch { }
    return $ips
}

function Send-Heartbeat {
    $ident = Get-Identity
    $ips = Get-AllIPv4
    $sshPort = 22

    # 检查 sshd 是否在跑
    $sshdOk = $false
    try {
        $tc = New-Object System.Net.Sockets.TcpClient
        $tc.ReceiveTimeout = 3000
        $tk = $tc.ConnectAsync('127.0.0.1', $sshPort)
        $ok = $false
        try { $ok = $tk.Wait(3000) } catch { }
        if ($ok -and $tc.Connected) {
            $st = $tc.GetStream()
            $buf = New-Object byte[] 64
            $n = 0
            try { $n = $st.Read($buf, 0, 64) } catch { }
            if ($n -gt 0) {
                $txt = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
                $sshdOk = $txt.StartsWith('SSH-')
            }
        }
        $tc.Close()
    } catch { }

    $svc = Get-Service sshd -ErrorAction SilentlyContinue

    $payload = [ordered]@{
        machineId    = ''   # 由源端按 Guid 算，这里留空让源端决定
        identity     = $ident
        hostname     = $env:COMPUTERNAME
        ips          = $ips
        sshPort      = $sshPort
        sshOk        = $sshdOk
        serviceState = if ($svc) { "$($svc.Status)" } else { 'none' }
        serviceStart = if ($svc) { "$($svc.StartType)" } else { '' }
        user         = "$env:USERDOMAIN\$env:USERNAME"
        os           = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        uptimeMin    = [int]((Get-Date) - (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime).TotalMinutes
        at           = (Get-Date -Format 'o')
    }

    $json = $payload | ConvertTo-Json -Depth 6 -Compress

    $headers = @{}
    if ($Token) { $headers['X-Heartbeat-Token'] = $Token }

    try {
        $resp = Invoke-RestMethod -Uri "$Server/heartbeat" -Method Post `
            -Body $json -ContentType 'application/json; charset=utf-8' `
            -Headers $headers -TimeoutSec 15 -ErrorAction Stop
        Log "sent OK ips=$($ips.Count) sshd=$sshdOk resp=$($resp.ok)"
        return $true
    } catch {
        Log "send FAIL: $($_.Exception.Message)"
        return $false
    }
}

# ---------------- 主流程 ----------------
if ($Once) {
    $ok = Send-Heartbeat
    if ($ok) { Write-Output 'HEARTBEAT OK' } else { Write-Output 'HEARTBEAT FAILED' }
    exit $(if ($ok) { 0 } else { 1 })
}

# ============================================================
# 单实例锁 —— 必须放在循环之前
# ============================================================
# 2026-11-06 事故：计划任务每 10 分钟触发一次，而本脚本是无限循环，
# 没有锁导致 SERVER-A 上堆积了 95 个实例，同秒重复上报 8 次，
# 并因为资源争抢导致 SSH 探测超时、误报 sshd=False。
#
# 用命名 Mutex 保证全机只有一个心跳进程。
$MutexName = 'Global\FleetHeartbeatMutex'
$script:HbMutex = $null
try {
    $script:HbMutex = New-Object System.Threading.Mutex($false, $MutexName)
    if (-not $script:HbMutex.WaitOne(0, $false)) {
        # 已有实例在跑，直接退出（不刷日志）
        exit 0
    }
} catch {
    # 创建失败也继续，但记一笔便于排查
    Log "Mutex 失败: $($_.Exception.Message)"
}

Log "heartbeat loop start, server=$Server interval=${IntervalSec}s pid=$PID"

# 循环中顺便自检：如果配置文件的地址变了，重新读取
$ConfigPath = Join-Path $PSScriptRoot 'heartbeat-target.txt'
$lastServer = $Server

while ($true) {
    $null = Send-Heartbeat

    # 检查配置是否被更新（用户改了地址但没重启任务）
    if (Test-Path $ConfigPath) {
        try {
            $line = (Get-Content $ConfigPath -TotalCount 1 -ErrorAction Stop)
            $newServer = ("$line").Trim() -replace '[\uFEFF\u200B\s]', ''
            if ($newServer -and $newServer -ne $lastServer) {
                Log "配置变更: $lastServer -> $newServer"
                $Server = $newServer
                $lastServer = $newServer
            }
        } catch { }
    }

    Start-Sleep -Seconds $IntervalSec
}

