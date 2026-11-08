# deploy-summary.ps1
# 部署结束后追加环境摘要，便于源端在不接触目标机的情况下判断结果。
# 由 远程一键部署.bat 调用： -LogPath <日志文件> -ExitCode <退出码>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LogPath,
    [int]$ExitCode = 0
)

$ErrorActionPreference = 'Continue'

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('')
$lines.Add('===== SUMMARY =====')
$lines.Add("host     = $env:COMPUTERNAME")
$lines.Add("user     = $env:USERDOMAIN\$env:USERNAME")
$lines.Add("time     = $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $lines.Add("os       = $($os.Caption) $($os.Version) build $($os.BuildNumber)")
} catch { $lines.Add("os       = (读取失败)") }

$lines.Add("exitCode = $ExitCode")

# 监听端口
try {
    $ss = @(Get-NetTCPConnection -LocalPort 22, 2222 -State Listen -ErrorAction SilentlyContinue)
    if ($ss.Count -gt 0) {
        foreach ($c in $ss) {
            $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            $lines.Add("listen   = $($c.LocalAddress):$($c.LocalPort)  pid=$($c.OwningProcess)  $($p.ProcessName)")
        }
    } else {
        $lines.Add('listen   = (none)')
    }
} catch { $lines.Add('listen   = (查询失败)') }

# 启动方式线索
$svcExists = [bool](Get-Service sshd -ErrorAction SilentlyContinue)
$lines.Add("svc_sshd = $svcExists")
$lines.Add("standalone_dir = $(Test-Path 'C:\sshd-standalone\sshd.exe')")

foreach ($tn in @('OpenSSH-Server-Logon', 'sshd-standalone')) {
    $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    $lines.Add("task[$tn] = $([bool]$t)")
}

# DSH
$dshEntry = Join-Path $env:USERPROFILE '.dsh\runtime\node_modules\@deepseek-ai\dsh\lib\bin.js'
$lines.Add("dsh_runtime = $(Test-Path $dshEntry)")
$nodeExe = $null
$nc = Get-Command node.exe -ErrorAction SilentlyContinue
if ($nc) {
    $nodeExe = $nc.Source
    $lines.Add("node     = $(& $nodeExe --version 2>&1)")
} else {
    $lines.Add('node     = (未找到)')
}

# 自我验证：读 banner
try {
    foreach ($port in @(22, 2222)) {
        $tc = $null
        try {
            $tc = New-Object System.Net.Sockets.TcpClient
            $tc.ReceiveTimeout = 3000
            $tk = $tc.ConnectAsync('127.0.0.1', $port)
            $ok = $false
            try { $ok = $tk.Wait(3000) } catch { }
            if ($ok -and $tc.Connected) {
                $st = $tc.GetStream()
                $buf = New-Object byte[] 128
                $n = 0
                try { $n = $st.Read($buf, 0, 128) } catch { $n = 0 }
                if ($n -gt 0) {
                    $txt = [Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim()
                    $lines.Add("banner[$port] = $txt")
                } else {
                    $lines.Add("banner[$port] = (TCP 通但无 banner)")
                }
            } else {
                $lines.Add("banner[$port] = (连不上)")
            }
        } finally {
            if ($tc) { try { $tc.Close() } catch { } }
        }
    }
} catch { }

$lines.Add('===== END =====')

try {
    # 用带 BOM 的 UTF-8 追加：后续任何工具（含默认 GBK 的环境）都能正确识别中文，
    # 避免出现「企业版」被读成乱码的问题。
    $enc = New-Object System.Text.UTF8Encoding($true)
    # 若文件已存在但无 BOM，先补一个
    if (Test-Path $LogPath) {
        $fs = [IO.File]::Open($LogPath, 'Open', 'ReadWrite')
        try {
            if ($fs.Length -lt 3) {
                $bom = [byte[]](0xEF, 0xBB, 0xBF)
                $fs.Write($bom, 0, 3)
            } else {
                $head = New-Object byte[] 3
                $null = $fs.Read($head, 0, 3)
                if (-not ($head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)) {
                    # 无 BOM：读全部内容，改写为带 BOM
                    $fs.Seek(0, 'Begin') | Out-Null
                    $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                    $all = $sr.ReadToEnd()
                    $sr.Dispose()
                    [IO.File]::WriteAllText($LogPath, $all, $enc)
                }
            }
        } finally { $fs.Dispose() }
    }
    [IO.File]::AppendAllText($LogPath, (($lines -join "`r`n") + "`r`n"), $enc)
    Write-Host "  [OK] 摘要已写入日志"
} catch {
    Write-Host "  [WARN] 摘要写入失败: $($_.Exception.Message)"
}
