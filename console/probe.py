# -*- coding: utf-8 -*-
"""
SSH / TCP 探测。

判断标准（踩过坑之后的分级）：
  refused  → 端口没开
  timeout  → 防火墙/网络拦截
  open-no-banner → 端口开着但进程僵死（能握手、读不到 SSH banner）
  ssh-ok   → 读到 SSH banner，协议层正常
  auth-fail → banner 正常但认证失败
"""
from __future__ import annotations

import socket
import subprocess
from dataclasses import dataclass, field

SSH_EXE = r"C:\Windows\System32\OpenSSH\ssh.exe"


@dataclass
class ProbeResult:
    level: str = "unknown"      # refused / timeout / open-no-banner / ssh-ok / auth-fail / error
    ok: bool = False
    banner: str = ""
    detail: str = ""
    whoami: str = ""
    hostname: str = ""
    latency_ms: int = 0
    extra: dict = field(default_factory=dict)

    @property
    def label(self) -> str:
        return {
            "ssh-ok": "正常",
            "auth-fail": "认证失败",
            "open-no-banner": "端口通但无响应",
            "timeout": "超时",
            "refused": "拒绝连接",
            "error": "异常",
            "unknown": "未检测",
        }.get(self.level, self.level)


def read_banner(host: str, port: int, timeout: float = 5.0) -> tuple[str, str, int]:
    """连上去读第一行。返回 (level, banner, 耗时ms)。

    这是唯一可靠的健康判断：sshd 正常时一定会立刻发 SSH- 开头的标识。
    只看 TCP 是否连得通会误判「僵死进程」为正常。
    """
    import time

    t0 = time.monotonic()
    sock = None
    try:
        sock = socket.create_connection((host, port), timeout=timeout)
        sock.settimeout(timeout)
        try:
            data = sock.recv(256)
        except socket.timeout:
            return "open-no-banner", "", int((time.monotonic() - t0) * 1000)
        except ConnectionResetError:
            return "open-no-banner", "", int((time.monotonic() - t0) * 1000)

        ms = int((time.monotonic() - t0) * 1000)
        if not data:
            return "open-no-banner", "", ms
        text = data.decode("utf-8", errors="replace").strip()
        if text.startswith("SSH-"):
            return "ssh-ok", text, ms
        return "open-no-banner", text[:80], ms
    except socket.timeout:
        return "timeout", "", int((time.monotonic() - t0) * 1000)
    except ConnectionRefusedError:
        return "refused", "", int((time.monotonic() - t0) * 1000)
    except OSError as exc:
        return "error", str(exc)[:100], int((time.monotonic() - t0) * 1000)
    finally:
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass


def probe(host: str, port: int = 22, user: str = "", timeout: float = 8.0,
          do_auth: bool = True) -> ProbeResult:
    """两级探测：先读 banner，再（可选）尝试真实 SSH 登录。"""
    res = ProbeResult()

    if not host:
        res.level, res.detail = "error", "未填写 IP"
        return res

    level, banner, ms = read_banner(host, port, timeout)
    res.level = level
    res.banner = banner
    res.latency_ms = ms

    if level != "ssh-ok":
        res.detail = {
            "refused": f"TCP {port} 拒绝连接（端口未开放）",
            "timeout": f"TCP {port} 超时（可能被防火墙拦截）",
            "open-no-banner": f"TCP {port} 可连但未返回 SSH banner（进程可能僵死）",
        }.get(level, banner or "未知错误")
        return res

    res.detail = f"banner: {banner}"

    if not do_auth or not user:
        res.ok = True
        return res

    # 真实登录测试
    try:
        cmd = [
            SSH_EXE, "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8", "-p", str(port), f"{user}@{host}",
            "echo __OK__; hostname; whoami",
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=25,
                              encoding="utf-8", errors="replace")
        out = (proc.stdout or "") + (proc.stderr or "")

        if "__OK__" in out:
            res.level = "ssh-ok"
            res.ok = True
            lines = [ln.strip() for ln in (proc.stdout or "").splitlines() if ln.strip()]
            if len(lines) >= 2:
                res.hostname = lines[1]
            if len(lines) >= 3:
                res.whoami = lines[2]
            res.detail = (f"登录成功 {user}@{res.hostname}" if res.hostname
                          else f"登录成功 {user}@{host}")
        elif "Permission denied" in out:
            res.level = "auth-fail"
            res.ok = False
            res.detail = f"认证失败：{user}@{host}（密钥未授权或用户名不对）"
        elif "Connection reset" in out:
            res.level = "auth-fail"
            res.ok = False
            res.detail = "认证阶段被重置（服务端进程崩溃，如 lookup_sid 问题）"
        else:
            res.level = "auth-fail"
            res.ok = False
            first = next((ln for ln in out.splitlines() if ln.strip()), "")
            res.detail = f"登录异常：{first[:120]}"
    except subprocess.TimeoutExpired:
        res.level = "auth-fail"
        res.ok = False
        res.detail = "SSH 登录超时"
    except FileNotFoundError:
        res.level = "error"
        res.ok = False
        res.detail = f"找不到 ssh.exe：{SSH_EXE}"
    except Exception as exc:  # noqa: BLE001
        res.level = "error"
        res.ok = False
        res.detail = f"探测异常：{exc}"

    return res


def run_remote(host: str, port: int, user: str, command: str,
               timeout: int = 60) -> tuple[int, str]:
    """在远端执行命令，返回 (退出码, 输出)。"""
    cmd = [
        SSH_EXE,
        "-o", "StrictHostKeyChecking=no",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-p", str(port),
        f"{user}@{host}",
        command,
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              encoding="utf-8", errors="replace")
        return proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except subprocess.TimeoutExpired:
        return -1, "命令超时"
    except Exception as exc:  # noqa: BLE001
        return -1, f"执行异常：{exc}"
