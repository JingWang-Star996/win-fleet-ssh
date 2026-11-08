<#
.SYNOPSIS
    日志位置解析（供各部署脚本 dot-source 使用）
.DESCRIPTION
    统一决定日志写到哪：
      1) 优先写到部署包根目录下的 logs\ —— 这样从网络共享运行时，
         源机器可以直接读到目标机产生的日志，无需人工回传。
      2) 若该位置不可写（只读介质、权限不足），回退到 %TEMP%。
    同时导出 Write-LogLine 辅助函数，保证所有脚本日志格式一致。
.NOTES
    调用方式（在脚本顶部）：
        . "$PSScriptRoot\..\common\logging.ps1"
        $LogPath = Initialize-LogPath -KitRoot $KitRoot -Prefix 'deploy' -Stamp $Stamp
#>

function Initialize-LogPath {
    param(
        [Parameter(Mandatory)][string]$KitRoot,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Stamp
    )

    $fileName = "$Prefix-$Stamp.log"
    $candidates = New-Object System.Collections.Generic.List[string]

    # 候选 1：部署包根目录 logs\（推荐，网络共享时源端可直接读取）
    $pkgLogs = Join-Path $KitRoot 'logs'
    $candidates.Add((Join-Path $pkgLogs $fileName))

    # 候选 2：部署包根目录本身（logs 子目录建不出来时）
    $candidates.Add((Join-Path $KitRoot $fileName))

    # 候选 3：TEMP（兜底）
    $candidates.Add((Join-Path $env:TEMP $fileName))

    foreach ($c in $candidates) {
        try {
            $dir = Split-Path -Parent $c
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            }
            # 实测可写性：追加一行探测
            $probe = "[" + (Get-Date -Format 'HH:mm:ss') + "] [INFO] log probe`r`n"
            [IO.File]::AppendAllText($c, $probe, [Text.Encoding]::UTF8)
            return $c
        } catch {
            continue
        }
    }

    # 所有位置都失败，返回 TEMP 路径（后续写入会静默失败，不阻塞主流程）
    return (Join-Path $env:TEMP $fileName)
}

function Write-LogLine {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message,
        [string]$Level = 'INFO'
    )
    $line = "[{0}] [{1,-4}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    try {
        [IO.File]::AppendAllText($Path, $line + "`r`n", [Text.Encoding]::UTF8)
    } catch { }
    return $line
}

function Get-LogDirectoryHint {
    param([string]$LogPath)
    if (-not $LogPath) { return '' }
    $dir = Split-Path -Parent $LogPath
    return $dir
}
