# -*- coding: utf-8 -*-
r"""采集集群各节点的 CPU / 内存 / GPU 使用率。

## 为什么独立成模块

console2.py 已 1916 行，直接改容易破坏原有逻辑。
指标采集是纯数据逻辑，独立出来便于单测与复用。

## 采集方式

走 ssh 执行 PowerShell，一次拿全三类指标：

    CPU    Get-Counter '\Processor(_Total)\% Processor Time'
           或 Win32_PerfFormattedData 的 PercentProcessorTime
    MEM    Win32_OperatingSystem 的 TotalVisibleMemorySize / FreePhysicalMemory
    GPU    nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total

## 关键约束（踩过的坑）

1. **不能用 `Get-Counter` 单次采样**：首次返回 0。
   改用 WMI 的 `Win32_PerfFormattedData_PerfOS_Processor`，它自带平均。
2. **ssh 会话在 Session 0**，但读性能计数器不需要交互会话，可以直接跑。
3. **nvidia-smi 路径**：不在 PATH 里，用绝对路径 `C:\Windows\System32\nvidia-smi.exe`。

## 用法

    from metrics import collect_one, collect_many
    m = collect_one("192.0.2.150")          # 默认用当前登录用户
    # {"cpu": 12.5, "mem_used": 8.2, "mem_total": 63.9,
    #  "gpu": [{"util": 3, "mem_used": 503, "mem_total": 16311}]}
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor

SSH = r"C:\Windows\System32\OpenSSH\ssh.exe"

# SSH 登录用户名：优先环境变量 FLEET_SSH_USER，否则取当前登录用户。
# 不在源码里写死真实账号，公开仓库不需要携带个人环境信息。
DEFAULT_USER = os.environ.get("FLEET_SSH_USER") or os.environ.get("USERNAME") or ""

# 单台采集脚本（PowerShell）
PS = r'''
$ErrorActionPreference = "SilentlyContinue"
$o = [ordered]@{}

# CPU：Win32_PerfFormattedData 自带平均，首采即有值
$c = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction SilentlyContinue |
     Where-Object { $_.Name -eq "_Total" } | Select-Object -First 1
if ($c) { $o.cpu = [int]$c.PercentProcessorTime } else { $o.cpu = -1 }

# 内存
# 注意单位：TotalVisibleMemorySize / FreePhysicalMemory 的单位是 KB。
# 先转 MB（/1024），再转 GB（/1024）。只除一次会显示成「9646/65436G」。
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os) {
  $o.mem_total = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
  $o.mem_free  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
  $o.mem_used  = [math]::Round($o.mem_total - $o.mem_free, 1)
  $o.mem_pct   = if ($o.mem_total -gt 0) { [int](100 * $o.mem_used / $o.mem_total) } else { 0 }
} else { $o.mem_pct = -1 }

# GPU
$smi = "C:\Windows\System32\nvidia-smi.exe"
if (Test-Path -LiteralPath $smi) {
  $g = & $smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>$null
  $arr = @()
  foreach ($ln in ($g -split "`r?`n")) {
    $t = $ln.Trim()
    if (-not $t) { continue }
    $p = $t -split ","
    if ($p.Count -ge 3) {
      $arr += [ordered]@{ util = [int]$p[0].Trim();
                          mem_used = [int]$p[1].Trim();
                          mem_total = [int]$p[2].Trim() }
    }
  }
  $o.gpu = $arr
} else { $o.gpu = @() }

$o | ConvertTo-Json -Compress -Depth 4
'''

# 转义成单行，便于 ssh 传参
PS_ONELINE = ("powershell -NoProfile -Command \"" +
              PS.replace('"', '\\"').replace("\n", "; ") + "\"")
PS_ENC = None       # 用 -EncodedCommand 更稳，见 encode()


def encode_ps(script: str) -> str:
    """把 PowerShell 脚本编码为 -EncodedCommand 需要的形式（UTF-16LE base64）。

    这样做的好处：完全避开引号转义、换行、中文路径问题。
    """
    import base64
    return base64.b64encode(script.encode("utf-16-le")).decode("ascii")


CMD = ("powershell -NoProfile -EncodedCommand " + encode_ps(PS))


def collect_one(host: str, user: str = DEFAULT_USER, timeout: float = 12.0,
                port: int = 22) -> dict:
    """采集单台指标。失败返回 {"err": ...}。"""
    t0 = time.time()
    try:
        r = subprocess.run(
            [SSH, "-o", "BatchMode=yes",
             "-o", "StrictHostKeyChecking=no",
             "-o", f"ConnectTimeout={int(timeout)}",
             "-p", str(port), f"{user}@{host}", CMD],
            capture_output=True, text=True, timeout=timeout + 5,
            encoding="utf-8", errors="replace",
            creationflags=0x08000000)
    except subprocess.TimeoutExpired:
        return {"err": "timeout", "sec": round(time.time() - t0, 1)}
    except OSError as e:
        return {"err": type(e).__name__, "sec": round(time.time() - t0, 1)}

    out = (r.stdout or "").strip()
    if r.returncode != 0 or not out.startswith("{"):
        return {"err": f"rc={r.returncode}",
                "sec": round(time.time() - t0, 1)}
    try:
        d = json.loads(out)
    except json.JSONDecodeError:
        return {"err": "json", "sec": round(time.time() - t0, 1)}

    d["sec"] = round(time.time() - t0, 1)
    d["at"] = time.time()
    return d


def collect_many(hosts: list, user: str = DEFAULT_USER,
                 workers: int = 8, timeout: float = 12.0,
                 on_partial=None) -> dict:
    """并发采集多台，返回 {host: metrics}。

    参数
        on_partial  可选回调，每拿到一台就回调一次 (host, metrics)。
                    控制台用它做「渐进式刷新」：不等全部采完就先把
                    已采到的行画出来，避免首屏十几秒空白。

    为什么不用 f.result() 顺序取
        原来的写法按 futures 插入顺序 f.result()，若第一个 future 恰好
        是离线机（卡满 timeout），后面的结果就算早就拿到了也得干等。
        改用 as_completed 按完成顺序收，配合 on_partial 可以让快机
        的结果立刻上屏。
    """
    from concurrent.futures import as_completed

    res: dict = {}
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(collect_one, h, user, timeout): h for h in hosts}
        for f in as_completed(futs):
            h = futs[f]
            try:
                r = f.result()
            except Exception as e:
                r = {"err": type(e).__name__}
            res[h] = r
            if on_partial is not None:
                try:
                    on_partial(h, r)
                except Exception:
                    pass
    return res


def fmt_cpu(m: dict) -> str:
    if m and m.get("_pending"):
        return "…"          # 首轮还没采到，区别于「采不到」
    if not m or m.get("err"):
        return "—"
    c = m.get("cpu", -1)
    return f"{c}%" if c >= 0 else "—"


def fmt_mem(m: dict) -> str:
    if m and m.get("_pending"):
        return "…"
    if not m or m.get("err"):
        return "—"
    p = m.get("mem_pct", -1)
    if p < 0:
        return "—"
    return f"{p}% {m.get('mem_used', 0):.0f}/{m.get('mem_total', 0):.0f}G"


def fmt_gpu(m: dict) -> str:
    """GPU 列：多卡时用分号分隔。"""
    if m and m.get("_pending"):
        return "…"
    if not m or m.get("err"):
        return "—"
    gpus = m.get("gpu") or []
    if not gpus:
        return "无"
    parts = []
    for g in gpus:
        u = g.get("util", 0)
        mu = g.get("mem_used", 0)
        mt = g.get("mem_total", 0)
        pct = int(100 * mu / mt) if mt else 0
        parts.append(f"{u}% {pct}%")
    return " / ".join(parts)


def fmt_gpu_detail(m: dict) -> str:
    if not m or m.get("err"):
        return "—"
    gpus = m.get("gpu") or []
    if not gpus:
        return "无 GPU"
    parts = []
    for g in gpus:
        parts.append(f"算力 {g.get('util', 0)}% · "
                     f"显存 {g.get('mem_used', 0)}/{g.get('mem_total', 0)} MiB")
    return " | ".join(parts)


# --------------------------------------------------------------- 落盘
HISTORY = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "data", "metrics-history.json")
HIST_MAX = 500          # 最多保留 500 轮


def save_history(snapshot: dict) -> None:
    """把一轮采集结果追加到历史文件，便于事后看趋势。

    为什么需要：控制台只管当下，但排查问题要看"什么时候开始异常的"。
    """
    try:
        os.makedirs(os.path.dirname(HISTORY), exist_ok=True)
        rec = []
        if os.path.exists(HISTORY):
            try:
                with open(HISTORY, encoding="utf-8") as f:
                    rec = json.load(f)
            except (OSError, json.JSONDecodeError):
                rec = []
        rec.append({"at": time.strftime("%Y-%m-%d %H:%M:%S"),
                    "data": snapshot})
        rec = rec[-HIST_MAX:]
        with open(HISTORY, "w", encoding="utf-8") as f:
            json.dump(rec, f, ensure_ascii=False)
    except OSError:
        pass


def load_history() -> list:
    try:
        with open(HISTORY, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return []


if __name__ == "__main__":
    import sys
    hosts = sys.argv[1:] or ["192.0.2.150", "192.0.2.32"]
    for h in hosts:
        m = collect_one(h)
        print(f"{h:<18} CPU {fmt_cpu(m):<6} MEM {fmt_mem(m):<18} "
              f"GPU {fmt_gpu(m)}")
        if m.get("err"):
            print(f"   err={m['err']}")
