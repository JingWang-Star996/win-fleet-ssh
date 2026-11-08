# run-and-log.ps1
# 执行一个 PowerShell 脚本，把输出实时显示到屏幕，同时以 UTF-8 写入日志文件。
#
# 为什么不用 Tee-Object：PowerShell 5.1 的 Tee-Object 没有 -Encoding 参数，
# 且默认写 UTF-16，导致日志被其他工具识别成二进制文件、无法直接读取。

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Script,
    [Parameter(Mandatory)][string]$LogPath,
    # 追加传给目标脚本的参数，例如 "-SkipDsh -NoVerify"
    [string]$ExtraArgs = ''
)

$ErrorActionPreference = 'Continue'

# 确保日志目录存在
$logDir = Split-Path $LogPath -Parent
if ($logDir -and -not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
}

$enc = New-Object System.Text.UTF8Encoding($true)

$argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$Script`""
if ($ExtraArgs -and $ExtraArgs.Trim()) { $argLine = "$argLine $($ExtraArgs.Trim())" }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName  = 'powershell.exe'
$psi.Arguments = $argLine
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow  = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi

$fs = $null
$sw = $null
$exit = 1
try {
    $null = $proc.Start()
    $fs = [IO.File]::Open($LogPath, 'Append', 'Write', 'ReadWrite')
    $sw = New-Object IO.StreamWriter($fs, $enc)
    $sw.AutoFlush = $true

    # 实时转发 stdout
    while (-not $proc.HasExited) {
        $line = $proc.StandardOutput.ReadLine()
        if ($null -ne $line) {
            Write-Host $line
            $sw.WriteLine($line)
        }
    }
    # 收尾：把剩余缓冲读完
    while (($line = $proc.StandardOutput.ReadLine()) -ne $null) {
        Write-Host $line
        $sw.WriteLine($line)
    }
    while (($line = $proc.StandardError.ReadLine()) -ne $null) {
        Write-Host $line -ForegroundColor Red
        $sw.WriteLine($line)
    }

    $exit = $proc.ExitCode
} catch {
    Write-Host "  [ERROR] run-and-log failed: $($_.Exception.Message)" -ForegroundColor Red
    try { [IO.File]::AppendAllText($LogPath, "ERROR: $($_.Exception.Message)`r`n", $enc) } catch { }
    $exit = 1
} finally {
    if ($sw) { try { $sw.Flush(); $sw.Dispose() } catch { } }
    if ($fs) { try { $fs.Dispose() } catch { } }
    if ($proc) { try { $proc.Dispose() } catch { } }
}

exit $exit
