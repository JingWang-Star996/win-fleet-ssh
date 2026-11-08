# restore-ssh.ps1
# 把 SSH 恢复到可用状态（本地运行，不需要网络）
#
# 场景：服务化失败后 SSH 断了
# 策略：优先修服务；服务不行就用前台进程；两者都要验证 banner
#
# 关键：不依赖任何外部资源，纯本地操作

$ErrorActionPreference = 'Continue'
$Log = 'C:\ProgramData\ssh-agent\restore.log'
$dir = Split-Path $Log -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

function L([string]$m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line
    try { [IO.File]::AppendAllText($Log, $line + "`r`n", [Text.Encoding]::UTF8) } catch { }
}

$Svc = 'sshd'
$Port = 22

L '=========================================='
L 'SSH 恢复'
L "身份: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# ---------- 找可用的 sshd ----------
L ''
L '[1/4] 找 sshd 二进制'
$candidates = @(
    'C:\Program Files\OpenSSH\sshd.exe',
    'C:\Windows\System32\OpenSSH\sshd.exe',
    'C:\sshd-standalone\sshd.exe'
)
$sshd = $null
foreach ($c in $candidates) {
    if (Test-Path $c) {
        $v = try { (Get-Item $c).VersionInfo.ProductVersion } catch { '?' }
        L "  [有] $c  ($v)"
        if (-not $sshd) { $sshd = $c }
    } else {
        L "  [无] $c"
    }
}
if (-not $sshd) {
    L 'FAIL: 找不到任何 sshd.exe'
    L 'RESULT=NO_SSHD'
    exit 1
}
L "  选用: $sshd"

# ---------- 检查现状 ----------
L ''
L '[2/4] 检查现状'
$svc = Get-CimInstance Win32_Service -Filter "Name='$Svc'" -ErrorAction SilentlyContinue
if ($svc) {
    L "  服务: $($svc.State) / $($svc.StartMode)"
    L "  路径: $($svc.PathName)"
} else {
    L '  服务: 未注册'
}
$listen = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
L "  端口 $Port : $(if($listen.Count -gt 0){"监听中 PID=$($listen[0].OwningProcess)"}else{'无监听'})"
$procs = @(Get-CimInstance Win32_Process -Filter "Name='sshd.exe'" -ErrorAction SilentlyContinue)
L "  sshd 进程: $($procs.Count) 个"
foreach ($p in $procs) { L "    PID=$($p.ProcessId)  $($p.CommandLine)" }

# ---------- 尝试 1：修/建服务 ----------
L ''
L '[3/4] 尝试服务方式'
$svcOk = $false

# 先清掉可能有问题的服务配置，用 WMI 方式重建（对空格安全）
if ($svc) {
    L '  删除现有服务配置（准备重建）'
    & sc.exe stop $Svc 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & sc.exe delete $Svc 2>&1 | Out-Null
    Start-Sleep -Seconds 3
}

# 停掉可能占用端口的前台进程
$procs = @(Get-CimInstance Win32_Process -Filter "Name='sshd.exe'" -ErrorAction SilentlyContinue)
foreach ($p in $procs) {
    L "  停 PID=$($p.ProcessId)"
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}
for ($i = 0; $i -lt 12; $i++) {
    if (@(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue).Count -eq 0) { break }
    Start-Sleep -Seconds 1
}

L '  创建服务（New-Service）'
try {
    $newPath = '"' + $sshd + '"'
    New-Service -Name $Svc -BinaryPathName $newPath `
        -DisplayName 'OpenSSH SSH Server' -StartupType Automatic `
        -ErrorAction Stop | Out-Null
    L '  服务已创建'

    # 权限
    & sc.exe privs $Svc SeAssignPrimaryTokenPrivilege 2>&1 | Out-Null
    & sc.exe privs $Svc SeTcbPrivilege 2>&1 | Out-Null
    & sc.exe privs $Svc SeBackupPrivilege 2>&1 | Out-Null
    & sc.exe privs $Svc SeRestorePrivilege 2>&1 | Out-Null
    & sc.exe privs $Svc SeImpersonatePrivilege 2>&1 | Out-Null

    L '  启动服务'
    & sc.exe start $Svc 2>&1 | Out-Null
    Start-Sleep -Seconds 6

    $cur = Get-CimInstance Win32_Service -Filter "Name='$Svc'" -ErrorAction SilentlyContinue
    L "  服务状态: $(if($cur){$cur.State}else{'?'})"

    # 验证 banner
    for ($i = 1; $i -le 10; $i++) {
        Start-Sleep -Seconds 2
        try {
            $tc = New-Object System.Net.Sockets.TcpClient
            $tc.ReceiveTimeout = 4000
            $tk = $tc.ConnectAsync('127.0.0.1', $Port)
            $c = $false
            try { $c = $tk.Wait(4000) } catch { }
            if ($c -and $tc.Connected) {
                $st = $tc.GetStream()
                $buf = New-Object byte[] 128
                $n = 0
                try { $n = $st.Read($buf, 0, 128) } catch { }
                if ($n -gt 0) {
                    $txt = [Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim()
                    L "  第${i}次: $txt"
                    if ($txt.StartsWith('SSH-')) { $svcOk = $true; break }
                }
                $tc.Close()
            }
        } catch { }
        L "  第${i}次: 无响应"
    }
} catch {
    L "  服务创建失败: $($_.Exception.Message)"
}

# ---------- 尝试 2：前台进程兜底 ----------
if (-not $svcOk) {
    L ''
    L '  服务方式失败，改用前台进程（保证现在能用）'
    # 清掉失败的服务，避免它开机时抢占
    & sc.exe stop $Svc 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & sc.exe delete $Svc 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    $procs = @(Get-CimInstance Win32_Process -Filter "Name='sshd.exe'" -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3

    try {
        Start-Process -FilePath $sshd -ArgumentList '-D' -WindowStyle Hidden
        L '  已启动前台进程'
        Start-Sleep -Seconds 6
        for ($i = 1; $i -le 8; $i++) {
            try {
                $tc = New-Object System.Net.Sockets.TcpClient
                $tc.ReceiveTimeout = 4000
                $tk = $tc.ConnectAsync('127.0.0.1', $Port)
                $c = $false
                try { $c = $tk.Wait(4000) } catch { }
                if ($c -and $tc.Connected) {
                    $st = $tc.GetStream()
                    $buf = New-Object byte[] 128
                    $n = 0
                    try { $n = $st.Read($buf, 0, 128) } catch { }
                    if ($n -gt 0) {
                        $txt = [Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim()
                        L "  $txt"
                        if ($txt.StartsWith('SSH-')) { $svcOk = $true; break }
                    }
                    $tc.Close()
                }
            } catch { }
            Start-Sleep -Seconds 2
        }
    } catch {
        L "  前台启动失败: $($_.Exception.Message)"
    }

    # 兜底再加登录触发器，保证重启后能起来
    if ($svcOk) {
        L '  额外配置登录触发器（重启后自动启动）'
        try {
            $tn = 'OpenSSH-Server-Logon'
            & schtasks.exe /delete /tn $tn /f 2>&1 | Out-Null
            $tr = '"' + $sshd + '" -D'
            & schtasks.exe /create /tn $tn /tr $tr /sc onlogon /ru "$env:USERDOMAIN\$env:USERNAME" /rl HIGHEST /f 2>&1 | Out-Null
            L "  登录触发器: $(if($LASTEXITCODE -eq 0){'已配置'}else{'配置失败'})"
        } catch { }
    }
}

# ---------- 结论 ----------
L ''
L '[4/4] 结果'
if ($svcOk) {
    $finalSvc = Get-CimInstance Win32_Service -Filter "Name='$Svc'" -ErrorAction SilentlyContinue
    $finalProc = @(Get-CimInstance Win32_Process -Filter "Name='sshd.exe'" -ErrorAction SilentlyContinue)
    L "  服务: $(if($finalSvc){"$($finalSvc.State)/$($finalSvc.StartMode)"}else{'未注册（前台模式）'})"
    L "  进程: $($finalProc.Count)"
    L "  端口: $(if(@(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue).Count -gt 0){'监听中'}else{'无'})"
    L 'RESULT=OK'
    exit 0
} else {
    L '  所有方式都失败'
    L 'RESULT=FAILED'
    exit 1
}
