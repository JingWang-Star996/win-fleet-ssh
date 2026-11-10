# install-heartbeat.ps1
# 在目标机上安装心跳上报：注册计划任务，开机即起、每 5 分钟上报一次。
#
# 设计要点：
#   - 用计划任务而不是服务：不需要额外二进制，也不占用服务控制管理器
#   - 用 SYSTEM 身份：机器无人登录时也能上报（这是关键，
#     否则重启后没人登录就永远不上报，等于白装）
#   - 不依赖 SSH：上报的是 UDP/HTTP 到源端，即使 sshd 挂了也能报
#   - 不做重试风暴：失败就等下一轮，避免源端不在时刷日志
#
# 用法（目标机管理员 PowerShell）：
#   .\install-heartbeat.ps1 -Server http://192.0.2.125:18765
[CmdletBinding()]
param(
    [string]$Server = 'http://192.0.2.125:18765',
    [string]$Token = '',
    [int]$IntervalMin = 5,
    [string]$ScriptSource = ''
)

$ErrorActionPreference = 'Continue'

$TaskName = 'FleetHeartbeat'
$InstallDir = 'C:\ProgramData\ssh-agent'
$Target = Join-Path $InstallDir 'heartbeat-send.ps1'

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  安装心跳上报' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''

# ---------- 权限检查 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal](
    [Security.Principal.WindowsIdentity]::GetCurrent()
)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '  [ERROR] 需要管理员权限' -ForegroundColor Red
    Write-Host '         请用管理员身份打开 PowerShell 后重试' -ForegroundColor Gray
    exit 2
}
Write-Host '  [OK] 管理员权限' -ForegroundColor Green

# ---------- 准备目录 ----------
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# ---------- 复制脚本 ----------
if ($ScriptSource -and (Test-Path $ScriptSource)) {
    Copy-Item $ScriptSource $Target -Force
    Write-Host "  [OK] 脚本已复制: $Target" -ForegroundColor Green
} elseif (Test-Path $Target) {
    Write-Host "  [OK] 使用已有脚本: $Target" -ForegroundColor Green
} else {
    Write-Host "  [ERROR] 找不到 heartbeat-send.ps1" -ForegroundColor Red
    Write-Host "         请用 -ScriptSource 指定路径" -ForegroundColor Gray
    exit 1
}

# ---------- 生成启动器 ----------
# 计划任务直接调用 powershell -File 会闪一下黑窗；
# 用 VBS 包一层（WScript.Shell 以隐藏窗口方式启动）更干净。
# 用单引号 here-string，避免 VBS 里的双引号与 PS 插值冲突。
$Launcher = Join-Path $InstallDir 'heartbeat-launch.vbs'
$vbsTemplate = @'
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""__TARGET__"" -Server ""__SERVER__""__TOKENPART__"
sh.Run cmd, 0, False
'@
$vbs = $vbsTemplate
$vbs = $vbs.Replace('__TARGET__', $Target)
$vbs = $vbs.Replace('__SERVER__', $Server)
# Token 为空时必须整段去掉，否则会给脚本传一个空串参数导致"缺少参数"报错
if ($Token) {
    $vbs = $vbs.Replace('__TOKENPART__', ' -Token ' + $Token)
} else {
    $vbs = $vbs.Replace('__TOKENPART__', '')
}
[IO.File]::WriteAllText($Launcher, $vbs, [Text.Encoding]::ASCII)
Write-Host "  [OK] 启动器: $Launcher" -ForegroundColor Green

# ---------- 注册计划任务 ----------
Write-Host ''
Write-Host "  [1/2] 注册计划任务: $TaskName" -ForegroundColor Cyan

& schtasks.exe /delete /tn $TaskName /f 2>&1 | Out-Null

# 双触发器：开机启动 + 每 N 分钟
# /ru SYSTEM 保证无人登录也运行
$tr = "wscript.exe `"$Launcher`""
$createOut = & schtasks.exe /create /tn $TaskName /tr $tr /sc minute /mo $IntervalMin /ru SYSTEM /rl HIGHEST /f 2>&1
$rc = $LASTEXITCODE

if ($rc -ne 0) {
    Write-Host "        失败: $($createOut -join ' ')" -ForegroundColor Red
    exit 1
}
Write-Host "        [OK] 每 $IntervalMin 分钟" -ForegroundColor Green

# 补一个开机触发器
$taskXml = & schtasks.exe /query /tn $TaskName /xml 2>&1
if ($LASTEXITCODE -eq 0) {
    $xml = ($taskXml -join "`r`n")
    # 在 <Triggers> 里插入 BootTrigger
    if ($xml -match '<Triggers>') {
        $bootTrigger = '<BootTrigger><Enabled>true</Enabled><Delay>PT30S</Delay></BootTrigger>'
        $newXml = $xml -replace '(<Triggers>)', "`$1$bootTrigger"
        $tmpXml = Join-Path $env:TEMP "hb-task-$PID.xml"
        [IO.File]::WriteAllText($tmpXml, $newXml, [Text.Encoding]::Unicode)
        & schtasks.exe /create /tn $TaskName /xml $tmpXml /f 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host '        [OK] 已添加开机触发器' -ForegroundColor Green
        } else {
            Write-Host '        [WARN] 开机触发器添加失败，仅保留定时触发' -ForegroundColor Yellow
        }
        Remove-Item $tmpXml -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host '  [2/2] 立即测试一次' -ForegroundColor Cyan
# 直接用调用运算符传参最可靠。
# 踩过的两个坑：
#   1) splat 哈希表传 -Once 会被转成字符串 "True"，SwitchParameter 报错
#   2) -Command "<含 -File 的长字符串>" 会把 -NoProfile 当成命令名
$testParams = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', $Target, '-Server', $Server, '-Once')
if ($Token) { $testParams += @('-Token', $Token) }
& powershell.exe @testParams 2>&1 | ForEach-Object {
    Write-Host "        $_" -ForegroundColor Gray
}

# ---------- 完成 ----------
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  安装完成' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "  上报地址 : $Server" -ForegroundColor Gray
Write-Host "  间隔     : $IntervalMin 分钟" -ForegroundColor Gray
Write-Host "  身份     : SYSTEM（无人登录也运行）" -ForegroundColor Gray
Write-Host "  日志     : $InstallDir\heartbeat.log" -ForegroundColor Gray
Write-Host ''
Write-Host '  验证命令：' -ForegroundColor Gray
Write-Host "    schtasks /query /tn $TaskName" -ForegroundColor White
Write-Host "    Get-Content $InstallDir\heartbeat.log -Tail 10" -ForegroundColor White
Write-Host ''
