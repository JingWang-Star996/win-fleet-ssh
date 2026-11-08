<#
.SYNOPSIS
    SSH + DSH 部署启动器（唯一入口，替代所有 .bat）
.DESCRIPTION
    这个脚本负责所有"准备工作"，把部署逻辑交给 windows\deploy-all.ps1。
    之所以用 PowerShell 而不是 .bat，是为了彻底避开 cmd 的一串陷阱：

      - %~dp0 末尾恒为反斜杠，放进引号里会转义掉结束引号
        （robocopy 报 16、0 文件复制的根因）
      - .bat 文件里非 ASCII 字符会随代码页变成 ?????
      - if/else if 必须写成 goto 形式，否则语法错误
      - 括号块内变量不延迟展开

    在 PowerShell 里这些都是普通字符串操作，不会出错。

    流程：
      1. 判断是否在 UNC 路径（网络共享）上运行
         是 → 复制到本地 C:\Temp\SSH-Kit，再从本地重新启动自己
      2. 检查管理员权限
         否 → 用 RunAs 提权重启自己
      3. 本地运行 → 执行部署

.PARAMETER SshOnly
    只装 SSH，跳过 DSH（快，约 1 分钟）
.PARAMETER Full
    装 SSH + DSH（约 5-8 分钟）
.PARAMETER EnablePassword
    允许密码登录（默认仅密钥）
.PARAMETER NoPrompts
    不询问，按默认值执行（用于自动化）
.PARAMETER KeepLocal
    保留本地副本（默认部署完删除）
.EXAMPLE
    .\deploy.ps1
    交互式：检测环境 → 询问装什么 → 部署
.EXAMPLE
    .\deploy.ps1 -SshOnly -NoPrompts
    无人值守：只装 SSH，不问任何问题
#>
[CmdletBinding()]
param(
    [switch]$SshOnly,
    [switch]$Full,
    [switch]$EnablePassword,
    [switch]$NoPrompts,
    [switch]$KeepLocal,
    # 安全锁：确认已在该机器上验证过才开始部署
    # 开发/测试时用 -DryRun 走完整流程但不实际改动系统
    [switch]$DryRun,
    # 心跳上报地址。给了就在部署末尾安装心跳任务，解决 IP 漂移。
    # 例：-HeartbeatServer http://192.0.2.125:18765
    [string]$HeartbeatServer = '',
    [int]$HeartbeatIntervalMin = 5,
    [switch]$SkipHeartbeat
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$LocalKitDir = 'C:\Temp\SSH-Kit'
$ScriptPath  = $MyInvocation.MyCommand.Path
$Here        = $PSScriptRoot

# ============================================================
# 心跳地址：命令行优先，其次读配置文件，最后自动猜测
# ============================================================
# heartbeat-target.txt 由 deploy.cmd 读取后通过参数传进来，
# 但如果有人直接跑 deploy.ps1（不经过 cmd），参数就是空的。
# 这里补一层兜底，保证「双击 deploy.cmd」和「直接跑 ps1」都能装上心跳。
$HeartbeatServer = ("$HeartbeatServer").Trim().TrimStart([char]0xFEFF).Trim()
if (-not $HeartbeatServer -and -not $SkipHeartbeat) {
    $cfgFile = Join-Path $Here 'heartbeat-target.txt'
    if (Test-Path $cfgFile) {
        try {
            $line = (Get-Content $cfgFile -TotalCount 1 -ErrorAction Stop)
            $HeartbeatServer = ("$line").Trim().TrimStart([char]0xFEFF).Trim()
        } catch { }
    }
}
# 清掉可能的 BOM / 不可见字符
if ($HeartbeatServer) {
    $HeartbeatServer = $HeartbeatServer -replace '[\uFEFF\u200B\s]', ''
}

# ============================================================
# 控制台输出
# ============================================================
function Line([string]$ch = '=', [int]$n = 60) { Write-Host ($ch * $n) -ForegroundColor DarkGray }
function Title([string]$t) {
    Write-Host ''
    Line '='
    Write-Host "  $t" -ForegroundColor Cyan
    Line '='
    Write-Host ''
}
function Ok([string]$m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Err([string]$m)  { Write-Host "  [ERR]  $m" -ForegroundColor Red }
function Info([string]$m) { Write-Host "  $m" -ForegroundColor Gray }
function Step([string]$m) { Write-Host "  >> $m" -ForegroundColor Cyan }

# ============================================================
# 状态
# ============================================================
$RunningFromNetwork = $Here -like '\\*'
$IsElevated = ([Security.Principal.WindowsPrincipal](
    [Security.Principal.WindowsIdentity]::GetCurrent()
)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ============================================================
# 阶段 1：网络路径 → 复制到本地
# ============================================================
function Copy-KitToLocal {
    param([string]$Source)

    Title 'Step 1 / 3  复制到本地'

    Info "源     : $Source"
    Info "目标   : $LocalKitDir"
    Write-Host ''

    # 源路径规范化：PowerShell 的 Join-Path 不接受尾部反斜杠作为独立段，
    # 这里统一用 TrimEnd 去掉，避免拼出双反斜杠。
    $src = $Source.TrimEnd('\')

    if (-not (Test-Path (Join-Path $src 'windows\deploy-all.ps1'))) {
        Err "源路径里找不到 windows\deploy-all.ps1"
        Info "确认路径正确：$src"
        return $false
    }

    # 目标准备
    if (Test-Path $LocalKitDir) {
        Step '清理旧副本...'
        try {
            Remove-Item $LocalKitDir -Recurse -Force -ErrorAction Stop
        } catch {
            Warn "清理失败（可能有文件被占用）：$($_.Exception.Message)"
        }
    }
    try {
        New-Item -ItemType Directory -Path $LocalKitDir -Force -ErrorAction Stop | Out-Null
    } catch {
        Err "无法创建 $LocalKitDir ：$($_.Exception.Message)"
        return $false
    }

    # ---- 三种复制方法，逐个尝试 ----
    $methods = @(
        @{
            Name = 'robocopy'
            Run  = {
                param($s, $d)
                $out = & robocopy $s $d /E /NFL /NDL /NJH /NJS /R:1 /W:1 2>&1
                # robocopy: 0-7 都是成功，>=8 是失败
                return ($LASTEXITCODE -lt 8)
            }
        },
        @{
            Name = 'Copy-Item'
            Run  = {
                param($s, $d)
                try {
                    Get-ChildItem -LiteralPath $s -Force | ForEach-Object {
                        Copy-Item -LiteralPath $_.FullName -Destination $d -Recurse -Force -ErrorAction Stop
                    }
                    return $true
                } catch { return $false }
            }
        }
    )

    $copied = $false
    $i = 0
    foreach ($m in $methods) {
        $i++
        Step "[$i/$($methods.Count)] 使用 $($m.Name) 复制..."
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $okResult = & $m.Run $src $LocalKitDir
        } catch {
            Warn "  $($m.Name) 异常：$($_.Exception.Message)"
            $okResult = $false
        }
        $sw.Stop()

        if ($okResult) {
            # 不只看返回值，还要验证关键文件真的到了
            if (Test-Path (Join-Path $LocalKitDir 'windows\deploy-all.ps1')) {
                $size = (Get-ChildItem $LocalKitDir -Recurse -File -ErrorAction SilentlyContinue |
                         Measure-Object -Property Length -Sum).Sum
                Ok ("{0} 完成，{1:N0} 秒，{2:N1} MB" -f $m.Name, $sw.Elapsed.TotalSeconds, ($size / 1MB))
                $copied = $true
                break
            } else {
                Warn "  $($m.Name) 报告成功但关键文件缺失"
            }
        } else {
            Warn ("  {0} 失败，耗时 {1:N1} 秒" -f $m.Name, $sw.Elapsed.TotalSeconds)
        }
    }

    if (-not $copied) {
        Write-Host ''
        Err '所有复制方法都失败'
        Write-Host ''
        Info '可能原因：'
        Info '  - 当前账户无权读取该共享'
        Info '  - 安全软件拦截了文件复制'
        Info '  - 磁盘空间不足'
        Write-Host ''
        Info '手工兜底：用资源管理器把整个 SSH-Deploy-Kit 文件夹'
        Info "          复制到 $LocalKitDir"
        Info "          然后运行 $LocalKitDir\deploy.ps1"
        return $false
    }

    Write-Host ''
    Ok '复制完成'
    return $true
}

# ============================================================
# 阶段 2：提权
# ============================================================
function Restart-Elevated {
    param([string]$Target, [string[]]$Arguments)

    Title 'Step 2 / 3  提升权限'

    Warn '当前不是管理员权限'
    Write-Host ''
    Info '部署需要管理员权限：'
    Info '  - 安装 OpenSSH / 注册计划任务'
    Info '  - 修改防火墙规则'
    Info '  - 写入 C:\ProgramData'
    Write-Host ''

    # ------------------------------------------------------------
    # 远程桌面 / UU / 向日葵 场景的关键问题：
    #   Start-Process -Verb RunAs 弹出的 UAC 在【目标机本机桌面】上，
    #   如果用户是通过远程工具进来且没接显示器，根本看不到也点不到，
    #   进程会一直卡住或静默失败。
    #
    # 实测结论：schtasks /ru SYSTEM 同样需要管理员（返回"拒绝访问"），
    # 所以免 UAC 走不通。这里只能走 RunAs，但把提示写清楚，
    # 并给出远程环境下确实可行的替代方案。
    # ------------------------------------------------------------

    Info '将请求提权，会出现 UAC 弹窗'
    Write-Host ''
    Warn '如果你是通过 UU / 向日葵 / RDP 进入这台机器，'
    Warn 'UAC 弹窗会出现在目标机的本机桌面上，你可能看不到。'
    Write-Host ''
    Info '那种情况下，请改用下面任一方式：'
    Info '  A) 在目标机上先手动开一个管理员 PowerShell，再运行本脚本'
    Info '  B) 用「以管理员身份运行」启动 cmd/终端本身'
    Info '  C) 若目标机有物理显示器，直接在那上面点「是」'
    Write-Host ''
    Info '现在尝试自动提权（能成功就最好）...'
    Write-Host ''

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Target`"")
    if ($Arguments) { $argList += $Arguments }

    try {
        $p = Start-Process -FilePath 'powershell.exe' `
                           -ArgumentList $argList `
                           -Verb RunAs `
                           -PassThru `
                           -ErrorAction Stop
        Ok "已启动提权进程（PID $($p.Id)）"
        Info '部署在新窗口中继续'
        return $true
    } catch {
        Write-Host ''
        Err '提权失败'
        Info $_.Exception.Message
        Write-Host ''
        Info '手工兜底（30 秒）：'
        Info '  1. 开始菜单 → 输入 PowerShell'
        Info '  2. 右键 → 以管理员身份运行'
        Info '  3. 粘贴这行：'
        Write-Host ''
        Write-Host "     & `"$Target`"" -ForegroundColor Yellow
        Write-Host ''
        return $false
    }
}

# ============================================================
# 阶段 3：执行部署
# ============================================================
function Invoke-Deploy {
    param([string]$KitRoot)

    Title 'Step 3 / 3  执行部署'

    $deployScript = Join-Path $KitRoot 'windows\deploy-all.ps1'
    if (-not (Test-Path $deployScript)) {
        Err "找不到部署脚本：$deployScript"
        return 1
    }

    # 决定装什么
    $doDsh = $true
    if ($SshOnly) { $doDsh = $false }
    elseif ($Full) { $doDsh = $true }
    elseif (-not $NoPrompts) {
        Write-Host '  选择要安装的内容：'
        Write-Host ''
        Write-Host '    [1]  仅 SSH         约 1 分钟' -ForegroundColor White
        Write-Host '    [2]  SSH + DSH     约 5-8 分钟' -ForegroundColor White
        Write-Host '    [3]  取消' -ForegroundColor White
        Write-Host ''
        $choice = Read-Host '  请输入 1、2 或 3'
        switch ($choice) {
            '1' { $doDsh = $false }
            '2' { $doDsh = $true }
            default {
                Info '已取消'
                return 0
            }
        }
    }

    # 组装参数（注意：不能用 $args，它是 PowerShell 的自动变量）
    $deployArgs = @{}
    if (-not $doDsh) { $deployArgs['SkipDsh'] = $true }
    if ($EnablePassword) { $deployArgs['EnablePassword'] = $true }
    if (-not $doDsh) { $deployArgs['NoVerify'] = $true }
    if ($HeartbeatServer) { $deployArgs['HeartbeatServer'] = $HeartbeatServer }
    if ($SkipHeartbeat) { $deployArgs['SkipHeartbeat'] = $true }

    Write-Host ''
    if ($doDsh) { Info '模式：SSH + DSH' } else { Info '模式：仅 SSH' }
    Write-Host ''

    # 用 run-and-log 同时落盘（UTF-8）和显示
    $runner = Join-Path $KitRoot 'windows\run-and-log.ps1'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logFile = Join-Path $KitRoot "logs\deploy-$stamp.log"

    # ---- DryRun：只报告将要做什么，不动系统 ----
    if ($DryRun) {
        Write-Host ''
        Line '-'
        Write-Host '  DRY RUN - 不会做任何改动' -ForegroundColor Yellow
        Line '-'
        Info "将执行  : $deployScript"
        Info "日志路径: $logFile"
        Info "模式    : $(if($doDsh){'SSH + DSH'}else{'仅 SSH'})"
        Info "密码登录: $(if($EnablePassword){'允许'}else{'禁止'})"
        Info "部署包  : $KitRoot"
        Info ''
        Info '已检查的关键文件：'
        foreach ($f in @('windows\deploy-all.ps1','windows\run-and-log.ps1','windows\deploy-summary.ps1','keys\authorized_keys')) {
            $p = Join-Path $KitRoot $f
            Info "  $(if(Test-Path $p){'[有]'}else{'[缺]'}) $f"
        }
        Line '-'
        return 0
    }

    if (Test-Path $runner) {
        $extra = @()
        if (-not $doDsh) { $extra += '-SkipDsh' }
        if ($EnablePassword) { $extra += '-EnablePassword' }
        if (-not $doDsh) { $extra += '-NoVerify' }
        if ($HeartbeatServer) {
            $extra += '-HeartbeatServer'
            $extra += "`"$HeartbeatServer`""
            $extra += '-HeartbeatIntervalMin'
            $extra += "$HeartbeatIntervalMin"
        }
        if ($SkipHeartbeat) { $extra += '-SkipHeartbeat' }

        & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File $runner `
            -Script $deployScript `
            -LogPath $logFile `
            -ExtraArgs ($extra -join ' ')
        $rc = $LASTEXITCODE
    } else {
        # 退路：直接跑，不管日志编码
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $deployScript @deployArgs
        $rc = $LASTEXITCODE
    }

    Write-Host ''
    Line '-'
    if ($rc -eq 0) {
        Ok '部署成功'
    } else {
        Err "部署失败，退出码 $rc"
    }
    Info "日志：$logFile"
    Line '-'

    return $rc
}

# ============================================================
# 主流程
# ============================================================
Write-Host ''
Write-Host '  ╔══════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '  ║           SSH + DSH 一键部署                         ║' -ForegroundColor Cyan
Write-Host '  ╚══════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''
Info "主机     : $env:COMPUTERNAME"
Info "用户     : $env:USERDOMAIN\$env:USERNAME"
Info "管理员   : $IsElevated"
Info "脚本位置 : $Here"
Info "网络路径 : $RunningFromNetwork"
Write-Host ''

# ---- 阶段 1：网络路径先复制 ----
if ($RunningFromNetwork) {
    if (-not (Copy-KitToLocal -Source $Here)) {
        Write-Host ''
        Read-Host '按回车退出'
        exit 1
    }

    # 从本地副本重新启动整个流程
    $localScript = Join-Path $LocalKitDir 'deploy.ps1'
    if (-not (Test-Path $localScript)) {
        Err "本地副本里找不到 deploy.ps1：$localScript"
        Read-Host '按回车退出'
        exit 1
    }

    $restartArgs = @()
    if ($SshOnly)        { $restartArgs += '-SshOnly' }
    if ($Full)           { $restartArgs += '-Full' }
    if ($EnablePassword) { $restartArgs += '-EnablePassword' }
    if ($NoPrompts)      { $restartArgs += '-NoPrompts' }
    if ($KeepLocal)      { $restartArgs += '-KeepLocal' }
    if ($HeartbeatServer) {
        $restartArgs += '-HeartbeatServer'
        $restartArgs += $HeartbeatServer
        $restartArgs += '-HeartbeatIntervalMin'
        $restartArgs += "$HeartbeatIntervalMin"
    }
    if ($SkipHeartbeat)  { $restartArgs += '-SkipHeartbeat' }

    Info '切换到本地副本继续...'
    Write-Host ''

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$localScript`"") + $restartArgs
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru
    $null = $p.WaitForExit()
    exit $p.ExitCode
}

# ---- 阶段 2：提权检查 ----
# DryRun 不需要任何系统改动，因此跳过提权，直接给检查报告
if (-not $DryRun -and -not $IsElevated) {
    $argsForElevated = @()
    if ($SshOnly)        { $argsForElevated += '-SshOnly' }
    if ($Full)           { $argsForElevated += '-Full' }
    if ($EnablePassword) { $argsForElevated += '-EnablePassword' }
    if ($NoPrompts)      { $argsForElevated += '-NoPrompts' }
    if ($KeepLocal)      { $argsForElevated += '-KeepLocal' }
    if ($HeartbeatServer) {
        $argsForElevated += '-HeartbeatServer'
        $argsForElevated += $HeartbeatServer
        $argsForElevated += '-HeartbeatIntervalMin'
        $argsForElevated += "$HeartbeatIntervalMin"
    }
    if ($SkipHeartbeat) { $argsForElevated += '-SkipHeartbeat' }

    if (Restart-Elevated -Target $ScriptPath -Arguments $argsForElevated) {
        exit 0
    } else {
        Read-Host '按回车退出'
        exit 2
    }
}

if ($IsElevated) {
    Ok '管理员权限已确认'
} elseif (-not $DryRun) {
    Err '权限检查异常'   # 理论上不会到这里，提权分支已处理
    Read-Host '按回车退出'
    exit 2
} else {
    Warn 'DryRun 模式：未提权，只做只读检查'
}
Write-Host ''

# ---- 阶段 3：部署 ----
$rc = Invoke-Deploy -KitRoot $Here

# ---- 收尾 ----
if (-not $KeepLocal -and $Here -eq $LocalKitDir) {
    Write-Host ''
    Info '清理本地副本...'
    # 延迟删除：当前脚本还在本地副本里运行，不能立刻删
    $cleanup = Join-Path $env:TEMP "cleanup-kit-$(Get-Random).ps1"
    @"
Start-Sleep -Seconds 2
Remove-Item '$LocalKitDir' -Recurse -Force -ErrorAction SilentlyContinue
"@ | Set-Content -Path $cleanup -Encoding UTF8
    Start-Process -FilePath 'powershell.exe' `
                  -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-File', "`"$cleanup`"") `
                  -WindowStyle Hidden | Out-Null
    Info '副本将在几秒后自动清理'
}

Write-Host ''
if (-not $NoPrompts) {
    Read-Host '按回车退出'
}
exit $rc
