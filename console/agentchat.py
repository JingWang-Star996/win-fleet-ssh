# -*- coding: utf-8 -*-
"""与目标机上的 DSH 对话：把一句话需求发过去，拿回结果。

实测结论（2026-11-09，在 5 台算力机上验证）：

1. 远端 `.dsh\\bin` 可能是空目录（安装没生成启动器），所以不能调 dsh.cmd；
   统一改成 `node <runtime>/@deepseek-ai/dsh/lib/bin.js headless`。
2. 远端不一定有正式安装的 node。SHA1084 就完全没有；
   SHA1436 / SHA1222 只有 codex 缓存里的 node。所以要按顺序探测。
3. dsh headless 的 prompt 走 **stdin**（见 dsh-headless/lib/index.js 的
   readStdin），不是命令行参数。走 argv 时中文会被 Windows 参数层破坏。

关于中文（2026-11-10 已查清并修复）
    旧版本曾加过一个 isascii() 拦截，理由是「中文经 scp 变问号」。
    那个判断是错的，实测证据：

      - 本地写 UTF-8 文件 27 字节，经 subprocess scp 上传，
        远端 base64 回读与本地逐字节一致（e794a8e4b880...）
      - 手工 scp 与 Python subprocess scp 结果相同，传输层无问题

    当时真正看到的现象是「dsh 返回了乱码」，
    但根因是目标机的 .credentials.yaml 被一次错误的编码转换破坏
    （GBK 当 ANSI 读入后以 UTF-8 加 BOM 重写），导致 credentials-local
    解析失败、模型根本没被调用，输出的是错误栈而不是回答。

    所以：**中文可以正常透传，拦截已移除。**
    若再遇到乱码，先查目标机的 .credentials.yaml 是否完好
    （应为 UTF-8 无 BOM，refs/records 为顶层键）。
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import time
from dataclasses import dataclass

HERE = os.path.dirname(os.path.abspath(__file__))
REMOTE_DIR = "C:/sa-work/.agent-console"

# 远端 node 的候选位置，按可靠性排序
NODE_CANDIDATES = [
    r"%USERPROFILE%\AppData\Local\Programs\node\node.exe",
    r"C:\Program Files\nodejs\node.exe",
    r"C:\Program Files (x86)\nodejs\node.exe",
    r"%USERPROFILE%\.workbuddy\binaries\node\versions\22.22.2-6\node.exe",
]

SSH_BASE = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8", "-p", "22"]
SCP_BASE = ["scp", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes", "-P", "22"]

# 远端执行器：用 node 的 spawn 把 prompt 从文件读进来，经 stdin 喂给 dsh。
# 这样做是为了彻底避开 PowerShell 与 argv 的编码层。
RUNNER_JS = r"""const { spawn } = require("node:child_process");
const fs = require("node:fs");
const [, , binJs, promptFile, outFile] = process.argv;
let prompt;
try { prompt = fs.readFileSync(promptFile, "utf8").trim(); }
catch (e) { fs.writeFileSync(outFile, "ERR:read_prompt " + e.message, "utf8"); process.exit(2); }
if (!prompt) { fs.writeFileSync(outFile, "ERR:empty_prompt", "utf8"); process.exit(2); }
const out = [];
const child = spawn(process.execPath, [binJs, "headless"], {
  stdio: ["pipe", "pipe", "pipe"],
  env: Object.assign({}, process.env, { NO_COLOR: "1" }),
});
child.stdout.on("data", (c) => out.push(c));
let errTail = "";
child.stderr.on("data", (c) => { errTail = (errTail + c.toString("utf8")).slice(-2000); });
child.stdin.write(prompt, "utf8");
child.stdin.end();
child.on("close", () => {
  const body = Buffer.concat(out).toString("utf8").trim() || errTail.trim() || "(no output)";
  fs.writeFileSync(outFile, body, "utf8");
});
child.on("error", (e) => { fs.writeFileSync(outFile, "ERR:spawn " + e.message, "utf8"); });
"""


def _no_window_kwargs() -> dict:
    """屏蔽 ssh/scp 的控制台窗口。

    ssh.exe 与 scp.exe 都是控制台程序，不屏蔽的话每次调用都会新建
    一个黑色窗口一闪而过。控制台的对话功能会频繁调它们，
    用户看到的就是"不停弹黑框"。
    """
    if os.name != "nt":
        return {}
    si = subprocess.STARTUPINFO()
    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    si.wShowWindow = 0  # SW_HIDE
    return {"creationflags": 0x08000000, "startupinfo": si}


def _run(cmd: list[str], timeout: int = 60) -> tuple[int, str, str]:
    """执行命令。必须用二进制管道再手动解码：Windows 下 ssh/scp 的错误串是 GBK，
    而正常输出是 UTF-8，用 text=True 会在混合输出时抛 UnicodeDecodeError，
    那个异常发生在读取线程里，会静默吞掉结果。"""
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout,
                           **_no_window_kwargs())
    except subprocess.TimeoutExpired:
        return -1, "", f"超时 {timeout}s"
    except Exception as e:
        return -2, "", str(e)

    def dec(b: bytes) -> str:
        if not b:
            return ""
        for enc in ("utf-8", "gbk", "latin-1"):
            try:
                return b.decode(enc)
            except UnicodeDecodeError:
                continue
        return b.decode("utf-8", "replace")

    return p.returncode, dec(p.stdout), dec(p.stderr)


@dataclass
class ProbeResult:
    ok: bool
    hostname: str = ""
    node: str = ""
    has_binjs: bool = False
    can_chat: bool = False
    detail: str = ""


PROBE_PS1 = r"""$ErrorActionPreference='SilentlyContinue'
$binjs = Join-Path $env:USERPROFILE '.dsh\runtime\node_modules\@deepseek-ai\dsh\lib\bin.js'
Write-Output ('BINJS=' + (Test-Path $binjs))
$node = ''
foreach ($c in @(
  (Join-Path $env:USERPROFILE 'AppData\Local\Programs\node\node.exe'),
  'C:\Program Files\nodejs\node.exe',
  'C:\Program Files (x86)\nodejs\node.exe'
)) { if (Test-Path $c) { $node = $c; break } }
if (-not $node) {
  $cb = Join-Path $env:USERPROFILE '.cache\codex-runtimes'
  if (Test-Path $cb) {
    $f = Get-ChildItem $cb -Filter 'node.exe' -Recurse -Depth 6 | Select-Object -First 1
    if ($f) { $node = $f.FullName }
  }
}
Write-Output ('NODE=' + $node)
"""


def _ensure_remote(host: str) -> str | None:
    """把 runner 脚本放到远端，返回远端路径。"""
    local = os.path.join(tempfile.gettempdir(), "agent-runner.js")
    with open(local, "w", encoding="utf-8", newline="\n") as f:
        f.write(RUNNER_JS)
    _run(SSH_BASE + [f"<user>@{host}",
                     f'powershell -NoProfile -Command "New-Item -ItemType Directory -Force -Path {REMOTE_DIR} | Out-Null; 1"'],
         30)
    remote = f"{REMOTE_DIR}/runner.js"
    rc, _, err = _run(SCP_BASE + [local, f"<user>@{host}:{remote}"], 45)
    try:
        os.remove(local)
    except OSError:
        pass
    return remote if rc == 0 else None


def probe(host: str) -> ProbeResult:
    """探测目标机能否对话：有 node、有 dsh runtime。"""
    local = os.path.join(tempfile.gettempdir(), "agent-probe.ps1")
    with open(local, "w", encoding="ascii", newline="\r\n") as f:
        f.write(PROBE_PS1)
    rc, _, err = _run(SSH_BASE + [f"<user>@{host}",
                                  f'powershell -NoProfile -Command "New-Item -ItemType Directory -Force -Path {REMOTE_DIR} | Out-Null; 1"'],
                      30)
    remote = f"{REMOTE_DIR}/probe.ps1"
    rc, _, err = _run(SCP_BASE + [local, f"<user>@{host}:{remote}"], 45)
    try:
        os.remove(local)
    except OSError:
        pass
    if rc != 0:
        return ProbeResult(False, detail=f"上传探测脚本失败：{(err or '').strip()[:120]}")

    rc, out, err = _run(SSH_BASE + [f"<user>@{host}",
                                    f"powershell -NoProfile -ExecutionPolicy Bypass -File {remote}"], 90)
    if rc != 0:
        return ProbeResult(False, detail=(err or out).strip()[:160])

    d = {}
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()

    node = d.get("NODE", "")
    has_binjs = d.get("BINJS", "") == "True"
    hn = ""
    for line in out.splitlines():
        if line.startswith("HOSTNAME="):
            hn = line.split("=", 1)[1].strip()

    can = bool(node) and has_binjs
    detail = ""
    if not node:
        detail = "缺 node"
    elif not has_binjs:
        detail = "缺 dsh runtime"
    return ProbeResult(True, hn, node, has_binjs, can, detail)


RUN_RUNNER_PS1 = r"""param([string]$Node, [string]$Runner, [string]$BinJs, [string]$PromptFile, [string]$OutFile)
& $Node $Runner $BinJs $PromptFile $OutFile
exit 0
"""


def ask(host: str, prompt: str, timeout: int = 300) -> tuple[bool, str, float]:
    """发一句话给目标机上的 dsh，返回 (成功, 回答或错误, 耗时秒)。"""
    prompt = (prompt or "").strip()
    if not prompt:
        return False, "内容为空", 0.0

    # 中文可以正常透传（2026-11-10 实测：UTF-8 文件经 scp 上传后
    # 远端 base64 回读与本地逐字节一致）。原来的 isascii() 拦截已移除。
    # 若仍出现乱码，先查目标机 .credentials.yaml 是否完好。

    remote_runner = _ensure_remote(host)
    if not remote_runner:
        return False, "无法上传执行脚本到目标机", 0.0

    pr = probe(host)
    if not pr.ok:
        return False, pr.detail or "目标机不可达", 0.0
    if not pr.can_chat:
        return False, f"该机器无法对话：{pr.detail}", 0.0

    stamp = int(time.time() * 1000)
    local_prompt = os.path.join(tempfile.gettempdir(), f"agent-prompt-{stamp}.txt")
    with open(local_prompt, "w", encoding="utf-8", newline="\n") as f:
        f.write(prompt)

    remote_prompt = f"{REMOTE_DIR}/prompt-{stamp}.txt"
    remote_out = f"{REMOTE_DIR}/answer-{stamp}.txt"

    t0 = time.time()
    rc, _, err = _run(SCP_BASE + [local_prompt, f"<user>@{host}:{remote_prompt}"], 60)
    try:
        os.remove(local_prompt)
    except OSError:
        pass
    if rc != 0:
        return False, f"上传失败：{(err or '').strip()[:160]}", time.time() - t0

    # 把「怎么调 node」也写进脚本传过去。
    #
    # 不能在 ssh 命令行里拼 `& "C:\...\node.exe" ...`：ssh 把整串交给远端
    # PowerShell 解析，路径里的 `/` `@` 会触发 "表达式或语句中包含意外的标记"，
    # 而且多层引号转义几乎无法调试。脚本文件是唯一稳的路径。
    local_run = os.path.join(tempfile.gettempdir(), "agent-run.ps1")
    with open(local_run, "w", encoding="ascii", newline="\r\n") as f:
        f.write(RUN_RUNNER_PS1)
    remote_run = f"{REMOTE_DIR}/run.ps1"
    rc, _, err = _run(SCP_BASE + [local_run, f"<user>@{host}:{remote_run}"], 45)
    try:
        os.remove(local_run)
    except OSError:
        pass
    if rc != 0:
        return False, f"上传执行器失败：{(err or '').strip()[:160]}", time.time() - t0

    args = (f'-Node "{pr.node}" -Runner "{remote_runner}" '
            f'-BinJs "C:/Users/<user>/.dsh/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js" '
            f'-PromptFile "{remote_prompt}" -OutFile "{remote_out}"')
    rc, out, err = _run(
        SSH_BASE + [f"<user>@{host}",
                    f"powershell -NoProfile -ExecutionPolicy Bypass -File {remote_run} {args}"],
        timeout)

    # 结果从文件拉回（scp 是纯字节传输）
    local_answer = os.path.join(tempfile.gettempdir(), f"agent-answer-{stamp}.txt")
    rc2, _, err2 = _run(SCP_BASE + [f"<user>@{host}:{remote_out}", local_answer], 120)
    elapsed = time.time() - t0
    if rc2 != 0:
        tail = (err or out or "").strip()
        # 屏蔽 SSH 的 post-quantum 告警噪音
        tail = "\n".join(l for l in tail.splitlines() if not l.startswith("**"))
        return False, f"取回结果失败：{tail[:200]}", elapsed

    try:
        with open(local_answer, "rb") as f:
            body = f.read().decode("utf-8", "replace").strip()
    finally:
        try:
            os.remove(local_answer)
        except OSError:
            pass

    if body.startswith("ERR:"):
        return False, body, elapsed
    return True, body, elapsed
