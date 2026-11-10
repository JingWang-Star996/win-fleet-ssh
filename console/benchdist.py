# -*- coding: utf-8 -*-
"""分布式压测：把 5 台机器拉进同一个任务里并发跑，而不是各自测各自的。

任务形态
    在 nonce 空间搜索 SHA256(prefix16 || nonce_le64) 至少有 N 位前导零的解。
    每台机器分到互不重叠的一份（stride 交错），合起来才是完整搜索。

为什么这样设计
    1. 所有机器解同一个问题，才叫"协作"；各测各的只是并排跑 5 个 benchmark。
    2. 每台必须汇报哈希次数，这是工作量证明，不能凭空报数。
    3. 协调器用 Python 独立复算每个解，worker 报错会被当场抓出来。
    4. 分片不重叠 -> 理想情况下 5 台等价于 1 台 5 倍速的机器，
       这正好能量出并行效率。

与 agentchat 的分工
    agentchat: ssh 到单台，用它的 dsh 回答一句话
    这个文件: ssh 到多台并发，跑同一任务的切片，汇总校验
    两者都用同样的 SSH/SCP 参数与二进制管道解码，保持行为一致。
"""
from __future__ import annotations

import concurrent.futures
import hashlib
import os
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from typing import Callable

HERE = os.path.dirname(os.path.abspath(__file__))
REMOTE_DIR = "C:/sa-work/bench"
TASK_TAG = "dsh-dist-v1"
PREFIX = TASK_TAG.encode("ascii").ljust(16, b"\x00")

SSH = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes",
       "-o", "ConnectTimeout=8", "-p", "22"]
SCP = ["scp", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes", "-P", "22"]

# Worker 脚本：内置在模块里，避免依赖外部文件的相对路径。
WORKER_PS1 = r'''param(
    [int]$DurationSec = 45,
    [int]$Difficulty = 20,
    [UInt64]$Start = 0,
    [UInt64]$Stride = 1,
    [string]$TaskTag = 'dsh-dist-v1'
)
$ErrorActionPreference = 'Stop'
$h = $env:COMPUTERNAME

$tagBytes = [Text.Encoding]::ASCII.GetBytes($TaskTag)
$prefix = [byte[]]::new(16)
for ($i = 0; $i -lt 16; $i++) {
    if ($i -lt $tagBytes.Length) { $prefix[$i] = $tagBytes[$i] } else { $prefix[$i] = 0 }
}
$buf = [byte[]]::new(24)
[Array]::Copy($prefix, 0, $buf, 0, 16)
$sha = [System.Security.Cryptography.SHA256]::Create()

function Get-Zeros {
    param([byte[]]$D)
    $bits = 0
    foreach ($b in $D) {
        if ($b -eq 0) { $bits += 8; continue }
        for ($m = 0x80; $m -gt 0; $m = $m -shr 1) {
            if (($b -band $m) -ne 0) { return $bits }
            $bits++
        }
        return $bits
    }
    return $bits
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$hashes = [UInt64]0
$found = New-Object System.Collections.ArrayList
$counter = $Start

while ($sw.Elapsed.TotalSeconds -lt $DurationSec) {
    for ($k = 0; $k -lt 2000; $k++) {
        $c = $counter
        $buf[16] = [byte]($c -band 0xFF)
        $buf[17] = [byte](($c -shr 8) -band 0xFF)
        $buf[18] = [byte](($c -shr 16) -band 0xFF)
        $buf[19] = [byte](($c -shr 24) -band 0xFF)
        $buf[20] = [byte](($c -shr 32) -band 0xFF)
        $buf[21] = [byte](($c -shr 40) -band 0xFF)
        $buf[22] = [byte](($c -shr 48) -band 0xFF)
        $buf[23] = [byte](($c -shr 56) -band 0xFF)
        $d = $sha.ComputeHash($buf)
        $hashes++
        if (($d[0] -eq 0) -and ($d[1] -eq 0) -and (($d[2] -shr 4) -eq 0)) {
            $z = Get-Zeros $d
            if ($z -ge $Difficulty) {
                $hex = -join ($d | ForEach-Object { $_.ToString('x2') })
                [void]$found.Add("$counter|$z|$hex")
            }
        }
        $counter += $Stride
    }
}
$sw.Stop()
$sha.Dispose()

Write-Output ('HOST=' + $h)
Write-Output ('SECONDS=' + [math]::Round($sw.Elapsed.TotalSeconds, 2))
Write-Output ('HASHES=' + $hashes)
Write-Output ('RATE=' + [math]::Round([double]$hashes / $sw.Elapsed.TotalSeconds, 1))
Write-Output ('SOLUTIONS=' + $found.Count)
$i = 0
foreach ($f in $found) {
    Write-Output ('SOL_' + $i + '=' + $f)
    $i++
}
'''


def _no_window_kwargs() -> dict:
    """屏蔽 ssh/scp 的控制台窗口（同 agentchat，两者都会频繁调 ssh）。"""
    if os.name != "nt":
        return {}
    si = subprocess.STARTUPINFO()
    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    si.wShowWindow = 0  # SW_HIDE
    return {"creationflags": 0x08000000, "startupinfo": si}


def _run(cmd: list[str], timeout: int) -> tuple[int, bytes, bytes]:
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout,
                           **_no_window_kwargs())
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return -1, b"", f"timeout {timeout}s".encode()
    except Exception as e:  # noqa: BLE001
        return -2, b"", str(e).encode()


def _dec(b: bytes) -> str:
    for enc in ("utf-8", "gbk", "latin-1"):
        try:
            return b.decode(enc)
        except UnicodeDecodeError:
            continue
    return b.decode("utf-8", "replace")


@dataclass
class WorkerOutcome:
    name: str
    host: str
    ok: bool = False
    seconds: float = 0.0
    hashes: int = 0
    rate: float = 0.0
    solutions: list[dict] = field(default_factory=list)
    error: str = ""


def push_worker(host: str) -> bool:
    """把内置的 worker 脚本推到目标机。返回是否成功。"""
    local = os.path.join(tempfile.gettempdir(), "bench-worker.ps1")
    with open(local, "w", encoding="ascii", newline="\r\n") as f:
        f.write(WORKER_PS1)

    _run(SSH + [f"<user>@{host}",
                f'powershell -NoProfile -Command "New-Item -ItemType Directory -Force -Path {REMOTE_DIR} | Out-Null; 1"'],
         30)
    rc, _, err = _run(SCP + [local, f"<user>@{host}:{REMOTE_DIR}/worker.ps1"], 60)
    try:
        os.remove(local)
    except OSError:
        pass
    return rc == 0


def run_slice(host: str, name: str, duration: int, difficulty: int,
              start: int, stride: int) -> WorkerOutcome:
    """在一台机器上跑一个分片。"""
    out = WorkerOutcome(name=name, host=host)
    cmd = (f"powershell -NoProfile -ExecutionPolicy Bypass -File {REMOTE_DIR}/worker.ps1 "
           f"-DurationSec {duration} -Difficulty {difficulty} -Start {start} -Stride {stride} "
           f"-TaskTag {TASK_TAG}")
    rc, out_b, err_b = _run(SSH + [f"<user>@{host}", cmd], duration + 240)
    if rc != 0:
        out.error = _dec(err_b).strip()[:200] or f"ssh rc={rc}"
        return out

    for line in _dec(out_b).splitlines():
        line = line.strip()
        if line.startswith("SECONDS="):
            try:
                out.seconds = float(line.split("=", 1)[1])
            except ValueError:
                pass
        elif line.startswith("HASHES="):
            out.hashes = int(line.split("=", 1)[1])
        elif line.startswith("RATE="):
            out.rate = float(line.split("=", 1)[1])
        elif line.startswith("SOL_"):
            parts = line.split("=", 1)[1].split("|")
            if len(parts) == 3:
                out.solutions.append({
                    "nonce": int(parts[0]), "zeros": int(parts[1]), "hash": parts[2],
                })
    out.ok = out.hashes > 0
    if not out.ok and not out.error:
        out.error = "no output"
    return out


def verify(sol: dict, difficulty: int) -> bool:
    """本机独立复算，不采信 worker 的汇报。"""
    buf = PREFIX + sol["nonce"].to_bytes(8, "little")
    digest = hashlib.sha256(buf).digest()
    if digest.hex() != sol["hash"]:
        return False
    bits = 0
    for b in digest:
        if b == 0:
            bits += 8
            continue
        for m in range(7, -1, -1):
            if b & (1 << m):
                break
            bits += 1
        break
    return bits == sol["zeros"] and bits >= difficulty


@dataclass
class BenchReport:
    duration: int = 0
    difficulty: int = 0
    wall_seconds: float = 0.0
    total_hashes: int = 0
    workers: list[WorkerOutcome] = field(default_factory=list)
    solutions: list[dict] = field(default_factory=list)
    invalid: int = 0

    @property
    def good(self) -> list[WorkerOutcome]:
        return [w for w in self.workers if w.ok]

    @property
    def aggregate_rate(self) -> float:
        total_s = sum(w.seconds for w in self.good)
        return self.total_hashes / total_s if total_s else 0.0

    @property
    def speedup(self) -> float:
        total_s = sum(w.seconds for w in self.good)
        return total_s / self.wall_seconds if self.wall_seconds else 0.0

    @property
    def efficiency(self) -> float:
        n = len(self.good)
        return (self.speedup / n * 100) if n else 0.0


def run_bench(machines: list[dict], duration: int, difficulty: int,
              progress: Callable[[str], None] | None = None) -> BenchReport:
    """跑一次分布式压测。

    machines: [{'name': str, 'host': str}, ...]
    progress: 可选回调，用于把进度写进界面
    """
    say = progress or (lambda _m: None)
    report = BenchReport(duration=duration, difficulty=difficulty)

    say(f"推送 worker 到 {len(machines)} 台机器…")
    usable = []
    for m in machines:
        if push_worker(m["host"]):
            usable.append(m)
            say(f"  {m['name']} 就绪")
        else:
            out = WorkerOutcome(name=m["name"], host=m["host"], error="推送失败")
            report.workers.append(out)
            say(f"  {m['name']} 推送失败")

    if not usable:
        return report

    say(f"并发启动 {len(usable)} 个分片（{duration}s）…")
    t0 = time.time()
    results: list[WorkerOutcome] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(usable)) as pool:
        futures = {
            pool.submit(run_slice, m["host"], m["name"], duration, difficulty,
                        i, len(usable)): m
            for i, m in enumerate(usable)
        }
        for fut in concurrent.futures.as_completed(futures):
            m = futures[fut]
            try:
                r = fut.result()
            except Exception as e:  # noqa: BLE001
                r = WorkerOutcome(name=m["name"], host=m["host"], error=str(e))
            results.append(r)
            if r.ok:
                say(f"  {r.name} 完成 {r.hashes:,} hashes @ {r.rate:,.0f}/s")
            else:
                say(f"  {r.name} 失败 {r.error[:60]}")
    report.wall_seconds = time.time() - t0
    report.workers = results
    report.total_hashes = sum(r.hashes for r in results if r.ok)

    say("独立复算所有解…")
    for r in results:
        for s in r.solutions:
            valid = verify(s, difficulty)
            report.solutions.append({**s, "from": r.name, "valid": valid})
            if not valid:
                report.invalid += 1
    return report
