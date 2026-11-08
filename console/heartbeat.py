# -*- coding: utf-8 -*-
"""
心跳上报服务（receiver）

背景与约束：
  算力机器不能接入个人 Tailscale 网络（安全边界），
  而它们的 LAN IP 每次重启可能变化，
  共享目录也因凭据问题访问不了。

  实测发现：目标机能反向 ping 通源端（192.0.2.125）。
  因此采用「机器主动上报」模式：
    目标机上的心跳脚本定期 POST 自己的身份 + 当前所有 IP，
    源端在固定端口接收并更新登记册的地址簿。

  这样 IP 怎么变都能自动跟上，且不需要：
    - Tailscale（避免安全边界问题）
    - SMB 凭据（共享访问不了）
    - 源端主动扫描（扫描只能发现同网段）

接口：
  POST /heartbeat   body=JSON  {machineId, hostname, ips[], ...}
  GET  /health      健康检查
  GET  /machines    返回当前登记的机器（备查）
"""
from __future__ import annotations

import json
import socket
import threading
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable

DEFAULT_PORT = 18765


class HeartbeatStore:
    """线程安全的心跳数据存放处。"""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._data: dict[str, dict] = {}   # machineId -> 最新心跳

    def update(self, payload: dict) -> str:
        """存入心跳，返回识别出的 machineId（算不出则返回空串）。

        协议设计：目标机不上报 machineId（它不该实现哈希算法，
        避免两边算法漂移），由源端按 identity 计算。
        """
        mid = (payload.get("machineId") or "").strip()
        if not mid:
            try:
                import identity
                ident = payload.get("identity") or {}
                if ident:
                    mid = identity.make_id(ident)
            except Exception:
                mid = ""
        if not mid:
            return ""

        payload = dict(payload)
        payload["machineId"] = mid

        with self._lock:
            self._data[mid] = {
                **payload,
                "_received": datetime.now().astimezone().isoformat(timespec="seconds"),
                "_from": payload.get("_from", ""),
            }
        return mid

    def get(self, machine_id: str) -> dict | None:
        with self._lock:
            return self._data.get(machine_id)

    def all(self) -> dict[str, dict]:
        with self._lock:
            return dict(self._data)

    def snapshot(self) -> list[dict]:
        with self._lock:
            return list(self._data.values())


class _Handler(BaseHTTPRequestHandler):
    store: HeartbeatStore = None          # 由 factory 注入
    _callback = None                      # 心跳回调（闭包捕获，不拆绑定）
    token: str = ""

    # 静默默认日志（避免刷屏）
    def log_message(self, fmt: str, *args: Any) -> None:
        pass
    def _send(self, code: int, body: Any) -> None:
        raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        try:
            self.wfile.write(raw)
        except OSError:
            pass

    def do_GET(self) -> None:
        if self.path.startswith("/health"):
            self._send(200, {"ok": True, "time": datetime.now().isoformat()})
        elif self.path.startswith("/machines"):
            self._send(200, {"machines": self.store.snapshot()})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self) -> None:
        if not self.path.startswith("/heartbeat"):
            self._send(404, {"error": "not found"})
            return

        # 可选 token 校验
        if self.token:
            got = self.headers.get("X-Heartbeat-Token", "")
            if got != self.token:
                self._send(403, {"error": "bad token"})
                return

        try:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b"{}"
            payload = json.loads(raw.decode("utf-8", errors="replace"))
        except (ValueError, OSError):
            self._send(400, {"error": "bad json"})
            return

        payload["_from"] = self.client_address[0]
        mid = self.store.update(payload)

        # 回调处理。
        # 关键：不能对回调做 __func__ 拆绑定 —— 心跳回调是 FleetConsole
        # 的绑定方法，拆掉后调用会把 payload 当成 self，抛 TypeError；
        # 而异常若被静默吞掉，表现就是"心跳到了但界面毫无反应"。
        # 这里用闭包捕获回调本身，调用时就是一次普通函数调用。
        cb = self._callback
        if cb is not None:
            try:
                cb({**payload, "machineId": mid})
            except Exception as exc:
                try:
                    import tempfile
                    import os
                    p = os.path.join(tempfile.gettempdir(), "heartbeat-callback-error.log")
                    with open(p, "a", encoding="utf-8") as f:
                        f.write(f"{datetime.now():%H:%M:%S} callback error: "
                                f"{type(exc).__name__}: {exc}\n")
                except Exception:
                    pass

        self._send(200, {"ok": True, "received": mid})


class HeartbeatServer:
    """包一层，便于 GUI 里启停。"""

    def __init__(self, port: int = DEFAULT_PORT, token: str = "",
                 on_update: Callable[[dict], None] | None = None) -> None:
        self.port = port
        self.token = token
        self.on_update = on_update
        self.store = HeartbeatStore()
        self._httpd: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> tuple[bool, str]:
        if self._httpd:
            return True, f"已在 {self.port} 运行"
        try:
            # 回调用闭包捕获。直接放进类字典会变成未绑定函数，
            # 通过类访问再调用时语义会变（这是踩过的坑）。
            handler = type("H", (_Handler,), {
                "store": self.store,
                "_callback": self.on_update,
                "token": self.token,
            })
            self._httpd = ThreadingHTTPServer(("0.0.0.0", self.port), handler)
            self._httpd.daemon_threads = True
            self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
            self._thread.start()
            return True, f"已监听 0.0.0.0:{self.port}"
        except OSError as exc:
            self._httpd = None
            return False, f"监听失败：{exc}"

    def stop(self) -> None:
        if self._httpd:
            try:
                self._httpd.shutdown()
                self._httpd.server_close()
            except Exception:
                pass
            self._httpd = None
            self._thread = None

    @property
    def running(self) -> bool:
        return self._httpd is not None


def local_reachable_ips() -> list[str]:
    """本机所有可被外部访问的 IPv4 地址。"""
    ips: list[str] = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in ips and not ip.startswith("127."):
                ips.append(ip)
    except OSError:
        pass
    return ips
