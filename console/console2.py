# -*- coding: utf-8 -*-
"""
机器登记与审计控制台 v2

核心变化：以「机器码」为主键，而不是 IP。
  - 表格里显示机器码短号（如 a1b2c3d4e5f6a7b8）
  - 每台机器有地址簿，IP 变了自动往簿里加，档案不丢
  - 连接时按优先级逐个地址尝试（Tailscale > LAN > 其它）
  - 提供「扫描识别」：输入一段 IP/网段，自动识别出机器码并归并

启动：双击 启动控制台.bat
"""
from __future__ import annotations

import csv
import threading
import tkinter as tk
from datetime import datetime
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

import identity
import heartbeat
import probe
import registry2 as registry

# ---------------------------------------------------------------- 主题
BG         = "#1e1f22"
BG_PANEL   = "#2b2d30"
BG_INPUT   = "#313338"
FG         = "#dfe1e5"
FG_DIM     = "#9aa0a6"
ACCENT     = "#4a9eff"
OK_GREEN   = "#3fb950"
WARN_AMBER = "#d29922"
ERR_RED    = "#f85149"
BORDER     = "#3a3d41"

FONT_UI    = ("Microsoft YaHei UI", 10)
FONT_BOLD  = ("Microsoft YaHei UI", 10, "bold")
FONT_TITLE = ("Microsoft YaHei UI", 16, "bold")
FONT_MONO  = ("Consolas", 9)
FONT_SMALL = ("Microsoft YaHei UI", 9)

ROLE_CHOICES = ["开发机", "测试机", "构建机", "编译机", "演示机", "服务器", "待分配"]
OS_CHOICES   = ["Windows", "Linux", "macOS"]
KIND_CHOICES = ["lan", "tailscale", "uu", "dns", "wan", "manual"]


class FleetConsole(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("机器登记与审计控制台  ·  机器码识别")
        self.geometry("1420x800")
        self.minsize(1200, 680)
        self.configure(bg=BG)

        self.data = registry.load()
        self.current: dict | None = None
        self._threads: list[threading.Thread] = []
        self._dirty = False
        self._probing: set[str] = set()

        # 心跳接收端：目标机主动上报，解决 IP 漂移
        self.hb = heartbeat.HeartbeatServer(port=heartbeat.DEFAULT_PORT,
                                            on_update=self._on_heartbeat)
        self._hb_ok = False
        self._hb_msg = ""

        self._build_style()
        self._build_ui()
        self._start_heartbeat()
        self._refresh_table()
        self._refresh_audit()
        self.protocol("WM_DELETE_WINDOW", self._on_close)

    # ------------------------------------------------------------ 样式
    def _build_style(self) -> None:
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure(".", background=BG, foreground=FG, font=FONT_UI)
        style.configure("TFrame", background=BG)
        style.configure("Panel.TFrame", background=BG_PANEL)
        style.configure("TLabel", background=BG, foreground=FG, font=FONT_UI)
        style.configure("Panel.TLabel", background=BG_PANEL, foreground=FG)
        style.configure("Dim.TLabel", background=BG, foreground=FG_DIM, font=FONT_SMALL)
        style.configure("Title.TLabel", background=BG, foreground=FG, font=FONT_TITLE)
        style.configure("TButton", background=BG_INPUT, foreground=FG, borderwidth=0,
                        focusthickness=0, padding=(12, 6), font=FONT_UI)
        style.map("TButton",
                  background=[("active", "#3d4046"), ("pressed", "#4a4d53")],
                  foreground=[("disabled", FG_DIM)])
        style.configure("Accent.TButton", background=ACCENT, foreground="#ffffff", font=FONT_BOLD)
        style.map("Accent.TButton", background=[("active", "#3a8ee6")])
        style.configure("TEntry", fieldbackground=BG_INPUT, foreground=FG,
                        insertcolor=FG, borderwidth=0, padding=6)
        style.configure("TCombobox", fieldbackground=BG_INPUT, foreground=FG,
                        background=BG_INPUT, arrowcolor=FG, borderwidth=0, padding=4)
        style.map("TCombobox", fieldbackground=[("readonly", BG_INPUT)],
                  foreground=[("readonly", FG)])
        style.configure("Treeview", background=BG_PANEL, foreground=FG,
                        fieldbackground=BG_PANEL, borderwidth=0, rowheight=28, font=FONT_UI)
        style.configure("Treeview.Heading", background=BG_INPUT, foreground=FG_DIM,
                        borderwidth=0, font=FONT_BOLD, padding=(8, 6))
        style.map("Treeview.Heading", background=[("active", "#3d4046")])
        style.map("Treeview", background=[("selected", "#2f5f8f")],
                  foreground=[("selected", "#ffffff")])
        style.configure("TNotebook", background=BG, borderwidth=0)
        style.configure("TNotebook.Tab", background=BG_INPUT, foreground=FG_DIM,
                        padding=(16, 8), borderwidth=0, font=FONT_UI)
        style.map("TNotebook.Tab",
                  background=[("selected", BG_PANEL)],
                  foreground=[("selected", FG)])
        style.configure("TScrollbar", background=BG_INPUT, troughcolor=BG,
                        borderwidth=0, arrowcolor=FG_DIM)

    # ------------------------------------------------------------ 布局
    def _build_ui(self) -> None:
        top = ttk.Frame(self, padding=(16, 12))
        top.pack(fill="x")
        ttk.Label(top, text="机器登记与审计控制台", style="Title.TLabel").pack(side="left")
        self.lbl_summary = ttk.Label(top, text="", style="Dim.TLabel")
        self.lbl_summary.pack(side="left", padx=(20, 0))

        btn = ttk.Frame(top)
        btn.pack(side="right")
        ttk.Button(btn, text="全部检测", style="Accent.TButton",
                   command=self._probe_all).pack(side="left", padx=4)
        ttk.Button(btn, text="扫描识别", command=self._scan_dialog).pack(side="left", padx=4)
        ttk.Button(btn, text="导出 CSV", command=self._export_csv).pack(side="left", padx=4)
        ttk.Button(btn, text="导出 Markdown", command=self._export_md).pack(side="left", padx=4)

        ttk.Separator(self, orient="horizontal").pack(fill="x")

        body = ttk.Frame(self, padding=(16, 12))
        body.pack(fill="both", expand=True)

        left = ttk.Frame(body)
        left.pack(side="left", fill="both", expand=True)

        # 机器码短号放在最前，因为它是主键
        cols = ("code", "hostname", "addr", "os", "role", "deployed", "status", "owner", "project")
        heads = {
            "code":     ("机器码",   160),
            "hostname": ("主机名",   130),
            "addr":     ("当前地址", 175),
            "os":       ("系统",      75),
            "role":     ("职能",      90),
            "deployed": ("本套件",    70),
            "status":   ("状态",     155),
            "owner":    ("责任人",    80),
            "project":  ("项目",      70),
        }
        wrap = ttk.Frame(left)
        wrap.pack(fill="both", expand=True)
        self.tree = ttk.Treeview(wrap, columns=cols, show="headings", selectmode="browse")
        for c in cols:
            text, width = heads[c]
            self.tree.heading(c, text=text, anchor="w")
            # 机器码/地址/主机名给足宽度，否则会被截断
            minw = {"code": 160, "addr": 175, "hostname": 130, "status": 155}.get(c, width)
            self.tree.column(c, width=width, minwidth=minw, anchor="w",
                             stretch=(c == "status"))
        vsb = ttk.Scrollbar(wrap, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=vsb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        vsb.pack(side="right", fill="y")
        self.tree.bind("<<TreeviewSelect>>", self._on_select)
        self.tree.bind("<Double-1>", lambda _e: self._probe_selected())
        self.tree.tag_configure("ok", foreground=OK_GREEN)
        self.tree.tag_configure("warn", foreground=WARN_AMBER)
        self.tree.tag_configure("err", foreground=ERR_RED)
        self.tree.tag_configure("dim", foreground=FG_DIM)
        self.tree.tag_configure("legacy", foreground="#b07cd6")

        bar = ttk.Frame(left, padding=(0, 10, 0, 0))
        bar.pack(fill="x")
        ttk.Button(bar, text="＋ 登记新机器", style="Accent.TButton",
                   command=self._add_machine).pack(side="left", padx=(0, 6))
        ttk.Button(bar, text="检测选中", command=self._probe_selected).pack(side="left", padx=6)
        ttk.Button(bar, text="添加地址", command=self._add_address).pack(side="left", padx=6)
        ttk.Button(bar, text="复制 SSH", command=self._copy_ssh).pack(side="left", padx=6)
        ttk.Button(bar, text="删除", command=self._delete_machine).pack(side="right")

        self.lbl_hint = ttk.Label(
            left,
            text="机器码 = sha256(MachineGuid) 前16位，重装系统才变 · 地址可漂移，双击行可检测",
            style="Dim.TLabel")
        self.lbl_hint.pack(fill="x", pady=(8, 0))

        # 心跳状态：目标机主动上报，解决 IP 漂移
        self.lbl_hb = tk.Label(left, text="心跳未启动", bg=BG, fg=FG_DIM,
                               font=FONT_SMALL, anchor="w")
        self.lbl_hb.pack(fill="x", pady=(2, 0))

        # 右侧
        right = ttk.Frame(body, width=430)
        right.pack(side="right", fill="y", padx=(16, 0))
        right.pack_propagate(False)
        self.notebook = ttk.Notebook(right)
        self.notebook.pack(fill="both", expand=True)
        self._build_detail_tab()
        self._build_address_tab()
        self._build_audit_tab()

    def _build_detail_tab(self) -> None:
        tab = ttk.Frame(self.notebook, padding=14)
        self.notebook.add(tab, text="机器详情")

        self.vars: dict[str, tk.Variable] = {}
        rows = [
            ("hostname", "主机名", "entry"),
            ("role", "职能", "combo"),
            ("owner", "责任人", "entry"),
            ("project", "项目", "entry"),
            ("os", "操作系统", "combo"),
            ("user", "登录用户", "entry"),
            ("deployMode", "部署方式", "combo"),
        ]
        for i, (key, label, kind) in enumerate(rows):
            ttk.Label(tab, text=label, style="Panel.TLabel").grid(
                row=i, column=0, sticky="w", pady=5, padx=(0, 10))
            var = tk.StringVar()
            self.vars[key] = var
            if kind == "combo":
                choices = {"os": OS_CHOICES, "role": ROLE_CHOICES,
                           "deployMode": ["service", "logonTask", "standalone"]}.get(key, [])
                w = ttk.Combobox(tab, textvariable=var, values=choices, state="readonly")
            else:
                w = ttk.Entry(tab, textvariable=var)
            w.grid(row=i, column=1, sticky="ew", pady=5)

        r = len(rows)
        ttk.Label(tab, text="机器码", style="Panel.TLabel").grid(
            row=r, column=0, sticky="nw", pady=5, padx=(0, 10))
        self.lbl_code = tk.Label(tab, text="—", bg=BG_PANEL, fg=ACCENT, font=FONT_MONO,
                                 anchor="w", justify="left", wraplength=260)
        self.lbl_code.grid(row=r, column=1, sticky="ew", pady=5)

        r += 1
        ttk.Label(tab, text="身份依据", style="Panel.TLabel").grid(
            row=r, column=0, sticky="nw", pady=5, padx=(0, 10))
        self.lbl_ident = tk.Label(tab, text="—", bg=BG_PANEL, fg=FG_DIM, font=FONT_SMALL,
                                  anchor="w", justify="left", wraplength=260)
        self.lbl_ident.grid(row=r, column=1, sticky="ew", pady=5)

        r += 1
        ttk.Label(tab, text="备注", style="Panel.TLabel").grid(
            row=r, column=0, sticky="nw", pady=5, padx=(0, 10))
        self.txt_notes = tk.Text(tab, height=4, bg=BG_INPUT, fg=FG, bd=0,
                                 insertbackground=FG, font=FONT_UI, wrap="word",
                                 padx=8, pady=6)
        self.txt_notes.grid(row=r, column=1, sticky="ew", pady=5)

        r += 1
        ttk.Label(tab, text="最近检测", style="Panel.TLabel").grid(
            row=r, column=0, sticky="nw", pady=5, padx=(0, 10))
        self.lbl_status = tk.Label(tab, text="未检测", bg=BG_PANEL, fg=FG_DIM,
                                   font=FONT_SMALL, anchor="w", justify="left", wraplength=260)
        self.lbl_status.grid(row=r, column=1, sticky="ew", pady=5)

        r += 1
        btns = ttk.Frame(tab)
        btns.grid(row=r, column=0, columnspan=2, sticky="ew", pady=(14, 0))
        ttk.Button(btns, text="保存", style="Accent.TButton",
                   command=self._save_current).pack(side="left")
        ttk.Button(btns, text="检测", command=self._probe_selected).pack(side="left", padx=8)
        ttk.Button(btns, text="重新采集机器码",
                   command=self._recollect_identity).pack(side="left")

        tab.columnconfigure(1, weight=1)

    def _build_address_tab(self) -> None:
        tab = ttk.Frame(self.notebook, padding=10)
        self.notebook.add(tab, text="地址簿")

        ttk.Label(tab, text="按优先级排列，检测时从上往下试",
                  style="Panel.TLabel").pack(anchor="w", pady=(0, 8))

        wrap = ttk.Frame(tab)
        wrap.pack(fill="both", expand=True)
        cols = ("host", "port", "kind", "status")
        self.tree_addr = ttk.Treeview(wrap, columns=cols, show="headings", height=12)
        for c, (t, w) in {"host": ("地址", 150), "port": ("端口", 55),
                          "kind": ("类型", 80), "status": ("状态", 110)}.items():
            self.tree_addr.heading(c, text=t)
            self.tree_addr.column(c, width=w, anchor="w")
        vsb = ttk.Scrollbar(wrap, orient="vertical", command=self.tree_addr.yview)
        self.tree_addr.configure(yscrollcommand=vsb.set)
        self.tree_addr.pack(side="left", fill="both", expand=True)
        vsb.pack(side="right", fill="y")
        self.tree_addr.tag_configure("ok", foreground=OK_GREEN)
        self.tree_addr.tag_configure("fail", foreground=ERR_RED)
        self.tree_addr.tag_configure("dim", foreground=FG_DIM)

        btns = ttk.Frame(tab, padding=(0, 8, 0, 0))
        btns.pack(fill="x")
        ttk.Button(btns, text="＋ 添加", command=self._add_address).pack(side="left")
        ttk.Button(btns, text="删除选中", command=self._del_address).pack(side="left", padx=6)
        ttk.Button(btns, text="逐个测试", command=self._test_addresses).pack(side="left")

    def _build_audit_tab(self) -> None:
        tab = ttk.Frame(self.notebook, padding=10)
        self.notebook.add(tab, text="审计日志")

        bar = ttk.Frame(tab)
        bar.pack(fill="x", pady=(0, 8))
        ttk.Label(bar, text="只看当前机器", style="Panel.TLabel").pack(side="left")
        self.var_audit_filter = tk.BooleanVar(value=False)
        ttk.Checkbutton(bar, variable=self.var_audit_filter,
                        command=self._refresh_audit).pack(side="left", padx=8)

        wrap = ttk.Frame(tab)
        wrap.pack(fill="both", expand=True)
        self.audit = tk.Text(wrap, bg=BG_INPUT, fg=FG, bd=0, font=FONT_MONO,
                             wrap="word", padx=8, pady=8, state="disabled")
        vsb = ttk.Scrollbar(wrap, orient="vertical", command=self.audit.yview)
        self.audit.configure(yscrollcommand=vsb.set)
        self.audit.pack(side="left", fill="both", expand=True)
        vsb.pack(side="right", fill="y")
        self.audit.tag_configure("time", foreground=FG_DIM)
        self.audit.tag_configure("ok", foreground=OK_GREEN)
        self.audit.tag_configure("err", foreground=ERR_RED)
        self.audit.tag_configure("act", foreground=ACCENT)

    # ------------------------------------------------------------ 表格
    def _refresh_table(self) -> None:
        sel = self.current.get("machineId") if self.current else None
        self.tree.delete(*self.tree.get_children())

        machines = registry.all_machines(self.data)
        for m in machines:
            mid = m.get("machineId", "")
            status, tag = self._status_cell(m)
            if mid.startswith("legacy-"):
                tag = "legacy"
            addr = m.get("onlineAddress") or ""
            if not addr:
                best = self._best_addr(m)
                addr = f"{best['host']}:{best['port']}" if best else "—"
            self.tree.insert("", "end", iid=mid,
                             values=(
                                 mid[:16],
                                 m.get("hostname", "") or "—",
                                 addr,
                                 m.get("os", ""),
                                 m.get("role", "") or "—",
                                 "已部署" if m.get("deployed") else "未部署",
                                 status,
                                 m.get("owner", "") or "—",
                                 m.get("project", "") or "—",
                             ), tags=(tag,))

        total = len(machines)
        dep = sum(1 for m in machines if m.get("deployed"))
        online = sum(1 for m in machines if m.get("online"))
        legacy = sum(1 for m in machines if (m.get("machineId") or "").startswith("legacy-"))
        txt = f"共 {total} 台 · 已部署 {dep} · 在线 {online}"
        if legacy:
            txt += f" · {legacy} 台待升级机器码"
        self.lbl_summary.config(text=txt)

        if sel and self.tree.exists(sel):
            self.tree.selection_set(sel)
            self.tree.focus(sel)

    def _best_addr(self, m: dict) -> dict | None:
        try:
            return identity.from_dict(m).best_address()
        except Exception:
            return None

    def _status_cell(self, m: dict) -> tuple[str, str]:
        if m.get("machineId", "").startswith("legacy-"):
            return "待验证机器码", "legacy"
        if m.get("online"):
            return f"在线 · {m.get('onlineAddress','')}", "ok"
        p = m.get("_probe")
        if p:
            if p.get("ok"):
                return f"正常 {p.get('latency_ms','')}ms", "ok"
            if p.get("level") == "auth-fail":
                return "认证失败", "warn"
            return f"不可达 · {p.get('label','')}", "err"
        seen = (m.get("lastSeen") or "").replace("T", " ")
        if seen:
            return f"离线 · 上次 {seen[5:16]}", "dim"
        return "未检测", "dim"

    # ------------------------------------------------------------ 心跳
    def _start_heartbeat(self) -> None:
        ok, msg = self.hb.start()
        self._hb_ok = ok
        self._hb_msg = msg
        if ok:
            ips = heartbeat.local_reachable_ips()
            lan = next((i for i in ips if i.startswith("10.")), ips[0] if ips else "?")
            self.lbl_hb.config(
                text=f"心跳接收 {heartbeat.DEFAULT_PORT} · {lan}:{heartbeat.DEFAULT_PORT}",
                fg=OK_GREEN)
            return

        # 启动失败：最常见原因是端口被别的进程占了
        self.lbl_hb.config(text=f"心跳未启动：{msg}", fg=ERR_RED)
        self._diagnose_port_conflict()

    def _diagnose_port_conflict(self) -> None:
        """端口被占时，查清是谁占的并弹窗告知。

        2026-11-06 踩的坑：测试用的接收端占着 18765，
        控制台启动失败但只在角落标红，看起来像「新机器不显示」，
        排查花了很久。现在直接告诉用户是谁占的、怎么处理。
        """
        port = heartbeat.DEFAULT_PORT
        owner_info = ""
        try:
            import subprocess
            out = subprocess.run(
                ["powershell", "-NoProfile", "-Command",
                 f"$c=Get-NetTCPConnection -LocalPort {port} -State Listen -ErrorAction SilentlyContinue | "
                 f"Select-Object -First 1; if($c){{$p=Get-CimInstance Win32_Process -Filter "
                 f"\"ProcessId=$($c.OwningProcess)\" -ErrorAction SilentlyContinue; "
                 f"Write-Output \"$($c.OwningProcess)|$($p.Name)|$($p.CommandLine)\"}}"],
                capture_output=True, text=True, timeout=15,
                encoding="utf-8", errors="replace")
            line = (out.stdout or "").strip()
            if line:
                parts = line.split("|", 2)
                pid = parts[0] if len(parts) > 0 else "?"
                name = parts[1] if len(parts) > 1 else "?"
                cmd = parts[2][:120] if len(parts) > 2 else ""
                owner_info = f"PID {pid}  {name}\n{cmd}"
        except Exception:
            pass

        if owner_info:
            messagebox.showwarning(
                "心跳端口被占用",
                f"端口 {port} 已被其它进程占用，控制台收不到新机器的心跳。\n\n"
                f"占用者：\n{owner_info}\n\n"
                f"处理：关掉那个进程后重启控制台。\n"
                f"（如果是自己遗留的测试接收端，可以用任务管理器结束它）",
                parent=self)
        else:
            messagebox.showwarning(
                "心跳端口被占用",
                f"端口 {port} 已被占用，控制台收不到新机器的心跳。\n\n"
                f"请用「资源监视器」或 netstat -ano 查谁占用 {port}，\n"
                f"关掉后重启控制台。",
                parent=self)

    def _on_heartbeat(self, payload: dict) -> None:
        """收到心跳。可能在 HTTP 线程里。

        重要：数据更新（写登记册）必须在这里同步完成，
        不能依赖 after() —— after() 需要 mainloop 在跑，
        若 UI 尚未进入 mainloop（或正在关闭），它会失败。
        数据写盘是心跳的核心价值，UI 只是展示，顺序不能反。
        """
        # 1) 先写数据（不碰 Tk，任何线程都安全）
        try:
            self._apply_heartbeat(payload)
        except Exception:
            import traceback
            try:
                p = Path(__file__).resolve().parent / "data" / "heartbeat-debug.log"
                with p.open("a", encoding="utf-8") as f:
                    f.write(f"[{datetime.now():%H:%M:%S}] apply failed\n")
                    for ln in traceback.format_exc().splitlines()[-5:]:
                        f.write(f"  {ln}\n")
            except Exception:
                pass

        # 2) 再请求刷新 UI（失败不影响已落盘的数据）
        try:
            self.after(0, self._refresh_after_heartbeat)
        except (RuntimeError, tk.TclError):
            # UI 不在 mainloop 里：尝试直接刷新，仍失败就跳过
            try:
                self._refresh_after_heartbeat()
            except Exception:
                pass

    def _refresh_after_heartbeat(self) -> None:
        """心跳后的 UI 刷新。全部包起来，UI 出问题不能影响数据。"""
        try:
            self._refresh_table()
            if self.current:
                mid = self.current.get("machineId")
                fresh = registry.find_by_id(self.data, mid) if mid else None
                if fresh:
                    self.current = fresh
                    self._refresh_addresses()
            self._refresh_audit()
        except Exception:
            pass

    def _apply_heartbeat(self, payload: dict) -> None:
        """用心跳数据更新登记册：识别机器码，把 IP 加进地址簿。

        这是 IP 漂移的最终解法——机器自己说"我在这个地址"，
        不需要源端去扫描或猜测。
        """
        def dbg(msg: str) -> None:
            try:
                p = Path(__file__).resolve().parent / "data" / "heartbeat-debug.log"
                with p.open("a", encoding="utf-8") as f:
                    f.write(f"    {msg}\n")
            except Exception:
                pass

        try:
            self._apply_heartbeat_inner(payload, dbg)
        except Exception as exc:
            import traceback
            dbg(f"EXCEPTION: {exc}")
            for ln in traceback.format_exc().splitlines()[-6:]:
                dbg(f"  {ln}")

    def _apply_heartbeat_inner(self, payload: dict, dbg) -> None:
        ident = payload.get("identity") or {}
        dbg(f"ident keys={list(ident.keys())} guid={ident.get('machineGuid','')[:8]}")
        if not ident.get("machineGuid") and not ident.get("biosSerial"):
            dbg("no identity fields, skip")
            return

        try:
            mid = identity.make_id(ident)
        except Exception as exc:
            dbg(f"make_id failed: {exc}")
            return
        dbg(f"machineId={mid}")

        data = self.data
        rec = registry.find_by_id(data, mid)
        created = False

        if not rec:
            # 可能是 legacy 记录：按主机名尝试升级
            hostname = (payload.get("hostname") or "").lower()
            for lid, lm in list(data["machines"].items()):
                if lid.startswith("legacy-") and (lm.get("hostname") or "").lower() == hostname:
                    data["machines"].pop(lid)
                    lm["machineId"] = mid
                    lm["identity"] = ident
                    lm["notes"] = (lm.get("notes", "") or "").replace(
                        " [从未验证机器码，待连接后自动升级]", " [心跳自动升级]")
                    data["machines"][mid] = lm
                    registry.log_action(data, mid, "upgrade", "ok",
                                        f"心跳识别，{lid} → {mid}")
                    rec = lm
                    dbg(f"upgraded legacy {lid} -> {mid}")
                    break

        if not rec:
            rec = {
                "machineId": mid,
                "hostname": payload.get("hostname", ""),
                "addresses": [],
                "role": "", "owner": "", "project": "",
                "os": payload.get("os") or "Windows",
                "deployed": bool(payload.get("sshOk")),
                "deployMode": "service" if (payload.get("serviceState") == "Running") else "",
                "dsh": False, "dshVerified": False,
                "user": (payload.get("user") or "").split("\\")[-1],
                "notes": "由心跳自动发现",
                "firstSeen": registry.now_iso(),
                "lastSeen": registry.now_iso(),
                "identity": ident,
                "online": True,
                "onlineAddress": "",
            }
            data["machines"][mid] = rec
            created = True
            registry.log_action(data, mid, "discover", "ok",
                                f"心跳自动登记 {payload.get('hostname')}")

        # 更新身份与状态
        rec["identity"] = ident
        if payload.get("hostname"):
            rec["hostname"] = payload["hostname"]
        if payload.get("os"):
            rec["os"] = payload["os"]
        if payload.get("serviceState") == "Running":
            rec["deployMode"] = "service"
            rec["deployed"] = True
        if payload.get("sshOk"):
            rec["deployed"] = True

        # 把所有上报的 IP 加进地址簿
        port = int(payload.get("sshPort") or 22)
        added = 0
        for item in payload.get("ips", []) or []:
            ip = (item.get("ip") if isinstance(item, dict) else str(item)) or ""
            if not ip or ip.startswith("127.") or ip.startswith("169.254."):
                continue
            kind = "tailscale" if ip.startswith("100.") else "lan"
            before = len(rec.get("addresses") or [])
            registry.touch_address(
                data, mid, ip, port,
                ok=bool(payload.get("sshOk")), kind=kind,
                note=item.get("alias", "") if isinstance(item, dict) else "")
            rec2 = registry.find_by_id(data, mid)
            if rec2 and len(rec2.get("addresses") or []) > before:
                added += 1

        # 用真实来源 IP 作为"确认可达"的地址
        src_ip = payload.get("_from", "")
        if src_ip:
            registry.touch_address(data, mid, src_ip, port, True, "lan", "心跳来源")

        registry.log_action(data, mid, "heartbeat", "ok",
                            f"{payload.get('hostname')} @ {src_ip} "
                            f"ips={len(payload.get('ips', []))} 新增={added}")

        # 只落盘，不刷 UI —— UI 刷新由调用方在合适线程处理。
        # 数据写盘是心跳的核心价值，不能被 UI 状态影响。
        self._persist()

    def _on_select(self, _evt=None) -> None:
        sel = self.tree.selection()
        if not sel:
            return
        m = registry.get(self.data, sel[0])
        if not m:
            return
        if self._dirty and not messagebox.askyesno("未保存", "当前修改尚未保存，放弃？", parent=self):
            return
        self.current = m
        self._load_to_form(m)
        self._refresh_addresses()
        self._refresh_audit()
        self._dirty = False

    def _load_to_form(self, m: dict) -> None:
        for key, var in self.vars.items():
            var.set(str(m.get(key, "") or ""))
        self.txt_notes.delete("1.0", "end")
        self.txt_notes.insert("1.0", m.get("notes", "") or "")

        mid = m.get("machineId", "")
        self.lbl_code.config(text=mid or "—",
                             fg="#b07cd6" if mid.startswith("legacy-") else ACCENT)

        ident = m.get("identity") or {}
        parts = []
        if ident.get("machineGuid"):
            parts.append(f"GUID {ident['machineGuid'][:8]}…")
        if ident.get("biosSerial"):
            parts.append(f"BIOS {ident['biosSerial'][:16]}")
        if ident.get("volumeSerial"):
            parts.append(f"VOL {ident['volumeSerial']}")
        self.lbl_ident.config(text="\n".join(parts) if parts else "（未采集，请用「重新采集机器码」）")

        p = m.get("_probe")
        if p:
            color = OK_GREEN if p.get("ok") else (WARN_AMBER if p.get("level") == "auth-fail" else ERR_RED)
            self.lbl_status.config(text=p.get("detail", ""), fg=color)
        else:
            self.lbl_status.config(text="未检测", fg=FG_DIM)

    def _refresh_addresses(self) -> None:
        self.tree_addr.delete(*self.tree_addr.get_children())
        if not self.current:
            return
        try:
            rec = identity.from_dict(self.current)
            addrs = rec.ordered_addresses()
        except Exception:
            addrs = self.current.get("addresses", []) or []

        for a in addrs:
            if a.get("lastOk"):
                st, tag = f"可用 {a['lastOk'][5:16]}", "ok"
            elif a.get("failCount"):
                st, tag = f"失败 {a['failCount']} 次", "fail"
            else:
                st, tag = "未测试", "dim"
            self.tree_addr.insert("", "end", values=(
                a.get("host", ""), a.get("port", 22), a.get("kind", ""), st), tags=(tag,))

    # ------------------------------------------------------------ 详情操作
    def _save_current(self) -> None:
        if not self.current:
            messagebox.showinfo("提示", "请先选择一台机器", parent=self)
            return
        before = dict(self.current)
        for key, var in self.vars.items():
            self.current[key] = var.get().strip()
        self.current["notes"] = self.txt_notes.get("1.0", "end").strip()

        changes = [f"{k}: {before.get(k,'')} → {self.current.get(k,'')}"
                   for k in ("hostname", "role", "owner", "project", "os", "user", "deployMode")
                   if str(before.get(k, "")) != str(self.current.get(k, ""))]
        if changes:
            registry.log_action(self.data, self.current["machineId"], "edit", "ok", "; ".join(changes))

        self._persist()
        self._refresh_table()
        self._refresh_audit()
        self._dirty = False

    def _recollect_identity(self) -> None:
        """通过 SSH 重新采集机器码。用于把 legacy 记录升级成真实机器码。"""
        if not self.current:
            return
        best = self._best_addr(self.current)
        if not best:
            messagebox.showinfo("提示", "这台机器没有记录任何地址", parent=self)
            return
        user = self.current.get("user") or ""
        if not user:
            messagebox.showinfo("提示", "请先在「登录用户」里填写用户名", parent=self)
            return

        self.lbl_status.config(text="正在采集机器码…", fg=WARN_AMBER)
        mid_before = self.current["machineId"]

        def work():
            info = identity.collect_remote(best["host"], int(best["port"]), user)
            self.after(0, lambda: self._recollect_done(info, mid_before, best))

        threading.Thread(target=work, daemon=True).start()

    def _recollect_done(self, info: dict, mid_before: str, addr: dict) -> None:
        if not info or not info.get("machineId"):
            self.lbl_status.config(text="采集失败：连不上或权限不足", fg=ERR_RED)
            registry.log_action(self.data, mid_before, "recollect", "fail", "机器码采集失败")
            self._persist()
            self._refresh_audit()
            return

        new_id = info["machineId"]

        if mid_before == new_id:
            self.current["identity"] = info
            self.lbl_status.config(text=f"机器码已确认：{new_id}", fg=OK_GREEN)
        else:
            # 换主键：删旧建新
            old = self.data["machines"].pop(mid_before, None)
            if old:
                old["machineId"] = new_id
                old["identity"] = info
                if info.get("hostname"):
                    old["hostname"] = info["hostname"]
                old["notes"] = (old.get("notes", "") or "").replace(
                    " [从未验证机器码，待连接后自动升级]", " [已升级为真实机器码]")
                self.data["machines"][new_id] = old
                self.current = old

            self.lbl_status.config(text=f"机器码已升级：{mid_before} → {new_id}", fg=OK_GREEN)
            registry.log_action(self.data, new_id, "upgrade", "ok",
                                f"{mid_before} -> {new_id}（经 {addr['host']}）")

        self._persist()
        self._refresh_table()
        self._load_to_form(self.current)
        self._refresh_audit()

    def _add_machine(self) -> None:
        dlg = AddMachineDialog(self)
        self.wait_window(dlg)
        if not dlg.result:
            return

        r = dlg.result
        host = r["ip"]
        port = int(r["port"])

        # 先尝试采集真实机器码
        self.lbl_summary.config(text="正在识别机器码…")
        info = {}
        if r.get("user"):
            info = identity.collect_remote(host, port, r["user"])

        if info.get("machineId"):
            mid = info["machineId"]
            rec, created = registry.resolve_or_create(self.data, info)
            rec["role"] = r["role"]
            rec["owner"] = r["owner"]
            rec["project"] = r["project"]
            rec["notes"] = r["notes"]
            rec["user"] = r["user"]
            kind = "tailscale" if host.startswith("100.") else "lan"
            registry.touch_address(self.data, mid, host, port, True, kind)
            registry.log_action(self.data, mid, "register", "ok",
                                f"按机器码登记 {info.get('hostname','')} @ {host}:{port}")
            msg = f"已按机器码登记\n{mid}"
        else:
            # 采集失败：用临时码建记录，等以后升级
            import hashlib
            seed = f"manual:{r['name']}|{host}".lower()
            mid = "legacy-" + hashlib.sha256(seed.encode()).hexdigest()[:10]
            if registry.find_by_id(self.data, mid):
                messagebox.showwarning("重复", "已存在同名记录", parent=self)
                self.lbl_summary.config(text="")
                return
            rec = identity.MachineRecord(
                machineId=mid, hostname=r["name"], role=r["role"], owner=r["owner"],
                project=r["project"], notes=(r["notes"] + " [未采集到机器码]").strip(),
                user=r["user"], firstSeen=registry.now_iso(),
            ).to_dict()
            self.data["machines"][mid] = rec
            registry.touch_address(self.data, mid, host, port, False, "lan")
            registry.log_action(self.data, mid, "register", "warn",
                                f"机器码采集失败，先用临时码登记 {host}:{port}")
            msg = "已登记（机器码采集失败，稍后可重新采集）"

        self._persist()
        self._refresh_table()
        self._refresh_audit()
        self.lbl_summary.config(text=msg)
        if self.tree.exists(mid):
            self.tree.selection_set(mid)

    def _delete_machine(self) -> None:
        if not self.current:
            return
        name = self.current.get("hostname") or self.current.get("machineId")
        if not messagebox.askyesno("删除", f"确定删除「{name}」？\n审计日志会保留。", parent=self):
            return
        mid = self.current["machineId"]
        registry.remove(self.data, mid)
        registry.log_action(self.data, mid, "delete", "ok", f"删除 {name}")
        self.current = None
        self._persist()
        self._refresh_table()
        self._refresh_addresses()
        self._refresh_audit()
        for var in self.vars.values():
            var.set("")
        self.txt_notes.delete("1.0", "end")
        self.lbl_code.config(text="—")
        self.lbl_ident.config(text="—")
        self.lbl_status.config(text="未检测", fg=FG_DIM)

    # ------------------------------------------------------------ 地址
    def _add_address(self) -> None:
        if not self.current:
            messagebox.showinfo("提示", "请先选择一台机器", parent=self)
            return
        dlg = AddAddressDialog(self)
        self.wait_window(dlg)
        if not dlg.result:
            return
        r = dlg.result
        registry.touch_address(self.data, self.current["machineId"],
                               r["host"], r["port"], False, r["kind"], r["note"])
        registry.log_action(self.data, self.current["machineId"], "address", "ok",
                            f"添加地址 {r['host']}:{r['port']}（{r['kind']}）")
        self._persist()
        self._refresh_addresses()
        self._refresh_table()
        self._refresh_audit()

    def _del_address(self) -> None:
        if not self.current:
            return
        sel = self.tree_addr.selection()
        if not sel:
            messagebox.showinfo("提示", "请先在列表里选择一个地址", parent=self)
            return
        vals = self.tree_addr.item(sel[0], "values")
        host, port = vals[0], int(vals[1])
        addrs = self.current.get("addresses", [])
        keep = [a for a in addrs if not (a.get("host") == host and int(a.get("port", 22)) == port)]
        if len(keep) == len(addrs):
            return
        if len(keep) == 0:
            messagebox.showwarning("不能删", "至少要保留一个地址", parent=self)
            return
        self.current["addresses"] = keep
        registry.log_action(self.data, self.current["machineId"], "address", "ok",
                            f"删除地址 {host}:{port}")
        self._persist()
        self._refresh_addresses()
        self._refresh_table()
        self._refresh_audit()

    def _test_addresses(self) -> None:
        if not self.current:
            return
        mid = self.current["machineId"]
        user = self.current.get("user") or ""
        addrs = list(self.current.get("addresses", []) or [])
        if not addrs:
            messagebox.showinfo("提示", "这台机器没有记录任何地址", parent=self)
            return

        self.lbl_status.config(text=f"正在逐个测试 {len(addrs)} 个地址…", fg=WARN_AMBER)

        def work():
            results = []
            for a in identity.from_dict(self.current).ordered_addresses():
                res = probe.probe(a["host"], int(a.get("port", 22)), user)
                results.append((a, res))
                self.after(0, lambda a=a, res=res: self._addr_result(a, res, mid))
                if res.ok:
                    break
            self.after(0, lambda: self._addr_done(results, mid))

        threading.Thread(target=work, daemon=True).start()

    def _addr_result(self, a: dict, res, mid: str) -> None:
        registry.touch_address(self.data, mid, a["host"], int(a.get("port", 22)),
                               res.ok, a.get("kind", "lan"))
        self._persist()
        self._refresh_addresses()
        self._refresh_table()

    def _addr_done(self, results: list, mid: str) -> None:
        ok = [r for r in results if r[1].ok]
        if ok:
            a, res = ok[0]
            self.lbl_status.config(text=f"可用地址：{a['host']}:{a['port']} — {res.detail}", fg=OK_GREEN)
            if self.current and self.current.get("machineId") == mid:
                self.current["_probe"] = {
                    "level": res.level, "label": res.label, "ok": res.ok,
                    "detail": res.detail, "latency_ms": res.latency_ms,
                }
        else:
            self.lbl_status.config(text=f"{len(results)} 个地址全部不可用", fg=ERR_RED)
            registry.mark_offline(self.data, mid)
            self._persist()

    # ------------------------------------------------------------ 检测
    def _probe_selected(self) -> None:
        if not self.current:
            messagebox.showinfo("提示", "请先选择一台机器", parent=self)
            return
        self._start_probe([self.current])

    def _probe_all(self) -> None:
        machines = registry.all_machines(self.data)
        if not machines:
            messagebox.showinfo("提示", "还没有登记任何机器", parent=self)
            return
        self._start_probe(machines)

    def _start_probe(self, machines: list[dict]) -> None:
        self.lbl_summary.config(text=f"正在检测 {len(machines)} 台…")
        for m in machines:
            t = threading.Thread(target=self._probe_worker, args=(m,), daemon=True)
            t.start()
            self._threads.append(t)

    def _probe_worker(self, m: dict) -> None:
        """按地址簿优先级逐个尝试，第一个通的就停。"""
        mid = m.get("machineId", "")
        user = m.get("user", "")
        try:
            ordered = identity.from_dict(m).ordered_addresses()
        except Exception:
            ordered = m.get("addresses", []) or []

        if not ordered:
            self.after(0, lambda: self._probe_finish(mid, None, None, "没有可用地址"))
            return

        last = None
        for a in ordered:
            try:
                res = probe.probe(a["host"], int(a.get("port", 22)), user)
            except Exception as exc:  # noqa: BLE001
                res = probe.ProbeResult(level="error", ok=False, detail=str(exc))
            last = (a, res)

            # 记录这次尝试
            try:
                self.after(0, lambda a=a, res=res: self._record_attempt(mid, a, res))
            except (RuntimeError, tk.TclError):
                pass

            if res.ok:
                self.after(0, lambda a=a, res=res: self._probe_finish(mid, a, res, None))
                return

        self.after(0, lambda: self._probe_finish(
            mid, last[0] if last else None, last[1] if last else None,
            f"{len(ordered)} 个地址全部不可用"))

    def _record_attempt(self, mid: str, a: dict, res) -> None:
        try:
            registry.touch_address(self.data, mid, a["host"], int(a.get("port", 22)),
                                   res.ok, a.get("kind", "lan"))
            m = registry.find_by_id(self.data, mid)
            if m is not None:
                m["_probe"] = {
                    "level": res.level, "label": res.label, "ok": res.ok,
                    "detail": res.detail, "latency_ms": res.latency_ms,
                }
                if not res.ok:
                    m["online"] = False
            self._persist()
            self._refresh_table()
        except Exception:
            pass

    def _probe_finish(self, mid: str, addr: dict | None, res, err: str | None) -> None:
        m = registry.find_by_id(self.data, mid)
        if err:
            if m is not None:
                m["online"] = False
                m["_probe"] = {"level": "unreachable", "label": "不可达",
                               "ok": False, "detail": err, "latency_ms": 0}
            registry.log_action(self.data, mid, "probe", "fail", err)
        else:
            detail = f"{addr['host']}:{addr['port']} — {res.detail}"
            registry.log_action(self.data, mid, "probe", "ok", detail)
            if m is not None:
                m["_probe"] = {"level": res.level, "label": res.label, "ok": res.ok,
                               "detail": detail, "latency_ms": res.latency_ms}

        self._persist()
        self._refresh_table()
        if self.current and self.current.get("machineId") == mid:
            if err:
                self.lbl_status.config(text=err, fg=ERR_RED)
            else:
                color = OK_GREEN if res.ok else (WARN_AMBER if res.level == "auth-fail" else ERR_RED)
                self.lbl_status.config(text=f"{addr['host']}:{addr['port']} — {res.detail}", fg=color)
            self._refresh_addresses()
        self._refresh_audit()

    # ------------------------------------------------------------ 扫描识别
    def _scan_dialog(self) -> None:
        dlg = ScanDialog(self)
        self.wait_window(dlg)
        if not dlg.result:
            return
        hosts = dlg.result["hosts"]
        port = dlg.result["port"]
        user = dlg.result["user"]
        if not hosts:
            return

        self.lbl_summary.config(text=f"正在扫描识别 {len(hosts)} 个地址…")

        def work():
            found = []
            for h in hosts:
                res = probe.probe(h, port, user, do_auth=False)
                if not res.ok:
                    continue
                info = identity.collect_remote(h, port, user) if user else {}
                found.append((h, res, info))
                self.after(0, lambda h=h, res=res, info=info: self._scan_hit(h, res, info, port))
            self.after(0, lambda: self._scan_done(len(hosts), found))

        threading.Thread(target=work, daemon=True).start()

    def _scan_hit(self, host: str, res, info: dict, port: int) -> None:
        if info.get("machineId"):
            rec, created = registry.resolve_or_create(self.data, info)
            kind = "tailscale" if host.startswith("100.") else "lan"
            registry.touch_address(self.data, rec["machineId"], host, port, True, kind)

            note = "新发现" if created else "已有记录，补地址"
            registry.log_action(self.data, rec["machineId"], "scan", "ok",
                                f"{host}:{port} -> {rec['machineId']}（{note}）")
            self._persist()
            self._refresh_table()
            self._refresh_audit()

    def _scan_done(self, total: int, found: list) -> None:
        identified = sum(1 for _, _, i in found if i.get("machineId"))
        self.lbl_summary.config(
            text=f"扫描完成：{total} 个地址，{len(found)} 个可连，{identified} 个识别出机器码")
        messagebox.showinfo(
            "扫描完成",
            f"扫描 {total} 个地址\n可连 {len(found)} 个\n识别出机器码 {identified} 个\n\n"
            + ("\n".join(f"  {h} → {(i.get('hostname') or '?')}" for h, _, i in found[:12])
               if found else "（没有发现可连接的机器）"),
            parent=self)

    # ------------------------------------------------------------ 导出
    def _export_csv(self) -> None:
        path = filedialog.asksaveasfilename(
            parent=self, defaultextension=".csv",
            initialfile=f"机器清单-{datetime.now():%Y%m%d}.csv",
            filetypes=[("CSV", "*.csv")])
        if not path:
            return
        try:
            with open(path, "w", encoding="utf-8-sig", newline="") as f:
                w = csv.writer(f)
                w.writerow(["机器码", "主机名", "首要地址", "全部地址", "系统", "职能",
                            "责任人", "项目", "已部署", "部署方式", "在线", "最近在线", "备注"])
                for m in registry.all_machines(self.data):
                    best = self._best_addr(m)
                    addrs = "; ".join(f"{a['host']}:{a['port']}" for a in (m.get("addresses") or []))
                    w.writerow([
                        m.get("machineId", ""), m.get("hostname", ""),
                        f"{best['host']}:{best['port']}" if best else "",
                        addrs, m.get("os", ""), m.get("role", ""), m.get("owner", ""),
                        m.get("project", ""), "是" if m.get("deployed") else "否",
                        m.get("deployMode", ""), "是" if m.get("online") else "否",
                        m.get("lastSeen", ""), m.get("notes", ""),
                    ])
            messagebox.showinfo("导出", f"已导出到：\n{path}", parent=self)
        except OSError as exc:
            messagebox.showerror("导出失败", str(exc), parent=self)

    def _export_md(self) -> None:
        path = filedialog.asksaveasfilename(
            parent=self, defaultextension=".md",
            initialfile=f"机器清单-{datetime.now():%Y%m%d}.md",
            filetypes=[("Markdown", "*.md")])
        if not path:
            return
        lines = [
            "# 机器清单", "",
            f"> 导出于 {datetime.now():%Y-%m-%d %H:%M}　主键为机器码，IP 变更不影响识别", "",
            "| 机器码 | 主机名 | 首要地址 | 职能 | 责任人 | 项目 | 已部署 | 在线 |",
            "|---|---|---|---|---|---|---|---|",
        ]
        for m in registry.all_machines(self.data):
            best = self._best_addr(m)
            lines.append(
                f"| `{m.get('machineId','')}` | {m.get('hostname','')} "
                f"| {best['host'] + ':' + str(best['port']) if best else '—'} "
                f"| {m.get('role','') or '—'} | {m.get('owner','') or '—'} "
                f"| {m.get('project','') or '—'} "
                f"| {'是' if m.get('deployed') else '否'} "
                f"| {'是' if m.get('online') else '否'} |")
        try:
            Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")
            messagebox.showinfo("导出", f"已导出到：\n{path}", parent=self)
        except OSError as exc:
            messagebox.showerror("导出失败", str(exc), parent=self)

    # ------------------------------------------------------------ 其它
    def _refresh_audit(self) -> None:
        self.audit.configure(state="normal")
        self.audit.delete("1.0", "end")

        entries = self.data.get("audit", [])
        if self.var_audit_filter.get() and self.current:
            entries = registry.audit_for(self.data, self.current["machineId"])

        for e in reversed(entries[-400:]):
            ts = (e.get("time") or "")[:19].replace("T", " ")
            mach = (e.get("machine") or "-")[:16]
            act = e.get("action") or "-"
            res = e.get("result") or "-"
            det = e.get("detail") or ""
            self.audit.insert("end", ts + "  ", "time")
            self.audit.insert("end", f"{mach:<17}", "act")
            self.audit.insert("end", f"{act:<10}", "act")
            self.audit.insert("end", f"{res:<6}", "ok" if res == "ok" else "err")
            self.audit.insert("end", det + "\n")

        self.audit.configure(state="disabled")
        self.audit.see("end")

    def _copy_ssh(self) -> None:
        if not self.current:
            return
        best = self._best_addr(self.current)
        if not best:
            messagebox.showinfo("提示", "这台机器没有记录地址", parent=self)
            return
        user = self.current.get("user") or "用户"
        port = int(best.get("port", 22))
        cmd = (f"ssh {user}@{best['host']}" if port == 22
               else f"ssh -p {port} {user}@{best['host']}")
        self.clipboard_clear()
        self.clipboard_append(cmd)
        messagebox.showinfo("已复制", cmd, parent=self)

    def _persist(self) -> None:
        clean = {
            "schema": 2,
            "machines": {
                mid: {k: v for k, v in m.items() if not k.startswith("_")}
                for mid, m in self.data.get("machines", {}).items()
            },
            "audit": self.data.get("audit", []),
        }
        registry.save(clean)

    def _on_close(self) -> None:
        if self._dirty and not messagebox.askyesno("未保存", "当前修改尚未保存，放弃？", parent=self):
            return
        try:
            self.hb.stop()
        except Exception:
            pass
        self._persist()
        self.destroy()


# ================================================================ 对话框
class AddMachineDialog(tk.Toplevel):
    def __init__(self, master: tk.Misc) -> None:
        super().__init__(master)
        self.title("登记新机器")
        self.configure(bg=BG)
        self.resizable(False, False)
        self.transient(master)
        self.result: dict | None = None

        f = ttk.Frame(self, padding=20)
        f.pack(fill="both", expand=True)

        ttk.Label(f, text="填写地址和用户后，会自动通过 SSH 采集机器码",
                  style="Dim.TLabel").grid(row=0, column=0, columnspan=2, sticky="w", pady=(0, 12))

        self.vars: dict[str, tk.Variable] = {}
        fields = [
            ("name", "名称（备注用）", "entry", ""),
            ("ip", "地址 *", "entry", ""),
            ("port", "SSH 端口", "entry", "22"),
            ("user", "登录用户 *", "entry", ""),
            ("role", "职能", "combo", ROLE_CHOICES),
            ("owner", "责任人", "entry", ""),
            ("project", "项目", "entry", ""),
        ]
        for i, (key, label, kind, extra) in enumerate(fields, start=1):
            ttk.Label(f, text=label).grid(row=i, column=0, sticky="w", pady=5, padx=(0, 12))
            var = tk.StringVar(value=extra if isinstance(extra, str) else "")
            self.vars[key] = var
            w = (ttk.Combobox(f, textvariable=var, values=extra, state="readonly", width=28)
                 if kind == "combo" else ttk.Entry(f, textvariable=var, width=30))
            w.grid(row=i, column=1, sticky="ew", pady=5)

        r = len(fields) + 1
        ttk.Label(f, text="备注").grid(row=r, column=0, sticky="nw", pady=5, padx=(0, 12))
        self.txt = tk.Text(f, height=3, width=30, bg=BG_INPUT, fg=FG, bd=0,
                           insertbackground=FG, font=FONT_UI, padx=6, pady=4, wrap="word")
        self.txt.grid(row=r, column=1, sticky="ew", pady=5)

        r += 1
        btns = ttk.Frame(f)
        btns.grid(row=r, column=0, columnspan=2, sticky="e", pady=(14, 0))
        ttk.Button(btns, text="取消", command=self.destroy).pack(side="right", padx=(8, 0))
        ttk.Button(btns, text="登记", style="Accent.TButton",
                   command=self._ok).pack(side="right")

        self.grab_set()
        self.update_idletasks()
        px, py = master.winfo_rootx(), master.winfo_rooty()
        pw, ph = master.winfo_width(), master.winfo_height()
        self.geometry(f"+{px + (pw - self.winfo_width())//2}+{py + (ph - self.winfo_height())//3}")

    def _ok(self) -> None:
        ip = self.vars["ip"].get().strip()
        if not ip:
            messagebox.showerror("必填", "地址必填", parent=self)
            return
        try:
            port = int(self.vars["port"].get().strip() or 22)
        except ValueError:
            messagebox.showerror("端口", "端口必须是数字", parent=self)
            return
        self.result = {
            "name": self.vars["name"].get().strip() or ip,
            "ip": ip, "port": port,
            "user": self.vars["user"].get().strip(),
            "role": self.vars["role"].get().strip(),
            "owner": self.vars["owner"].get().strip(),
            "project": self.vars["project"].get().strip(),
            "notes": self.txt.get("1.0", "end").strip(),
        }
        self.destroy()


class AddAddressDialog(tk.Toplevel):
    def __init__(self, master: tk.Misc) -> None:
        super().__init__(master)
        self.title("添加地址")
        self.configure(bg=BG)
        self.resizable(False, False)
        self.transient(master)
        self.result: dict | None = None

        f = ttk.Frame(self, padding=20)
        f.pack(fill="both", expand=True)

        self.vars: dict[str, tk.Variable] = {}
        rows = [
            ("host", "地址 *", "entry", ""),
            ("port", "端口", "entry", "22"),
            ("kind", "类型", "combo", KIND_CHOICES),
            ("note", "说明", "entry", ""),
        ]
        for i, (k, label, kind, extra) in enumerate(rows):
            ttk.Label(f, text=label).grid(row=i, column=0, sticky="w", pady=5, padx=(0, 12))
            var = tk.StringVar(value="lan" if k == "kind" else (extra if isinstance(extra, str) else ""))
            self.vars[k] = var
            w = (ttk.Combobox(f, textvariable=var, values=extra, state="readonly", width=26)
                 if kind == "combo" else ttk.Entry(f, textvariable=var, width=28))
            w.grid(row=i, column=1, sticky="ew", pady=5)

        btns = ttk.Frame(f)
        btns.grid(row=len(rows), column=0, columnspan=2, sticky="e", pady=(14, 0))
        ttk.Button(btns, text="取消", command=self.destroy).pack(side="right", padx=(8, 0))
        ttk.Button(btns, text="添加", style="Accent.TButton",
                   command=self._ok).pack(side="right")

        self.grab_set()
        self.update_idletasks()
        px, py = master.winfo_rootx(), master.winfo_rooty()
        self.geometry(f"+{px + 200}+{py + 150}")

    def _ok(self) -> None:
        host = self.vars["host"].get().strip()
        if not host:
            messagebox.showerror("必填", "地址必填", parent=self)
            return
        try:
            port = int(self.vars["port"].get().strip() or 22)
        except ValueError:
            messagebox.showerror("端口", "端口必须是数字", parent=self)
            return
        self.result = {"host": host, "port": port,
                       "kind": self.vars["kind"].get().strip() or "manual",
                       "note": self.vars["note"].get().strip()}
        self.destroy()


class ScanDialog(tk.Toplevel):
    """扫描识别：给一段地址，自动找出机器码并归并。"""

    def __init__(self, master: tk.Misc) -> None:
        super().__init__(master)
        self.title("扫描识别")
        self.configure(bg=BG)
        self.resizable(False, False)
        self.transient(master)
        self.result: dict | None = None

        f = ttk.Frame(self, padding=20)
        f.pack(fill="both", expand=True)

        ttk.Label(f, text="输入地址，每行一个；支持网段如 192.0.2.1-254 或 192.0.2.0/24",
                  style="Dim.TLabel", wraplength=420, justify="left").grid(
            row=0, column=0, columnspan=2, sticky="w", pady=(0, 10))

        self.txt = tk.Text(f, height=8, width=52, bg=BG_INPUT, fg=FG, bd=0,
                           insertbackground=FG, font=FONT_MONO, padx=8, pady=6, wrap="none")
        self.txt.grid(row=1, column=0, columnspan=2, sticky="ew", pady=5)

        self.var_port = tk.StringVar(value="22")
        self.var_user = tk.StringVar(value="")
        ttk.Label(f, text="端口").grid(row=2, column=0, sticky="w", pady=5)
        ttk.Entry(f, textvariable=self.var_port, width=10).grid(row=2, column=1, sticky="w", pady=5)

        ttk.Label(f, text="登录用户").grid(row=3, column=0, sticky="w", pady=5)
        ttk.Entry(f, textvariable=self.var_user, width=24).grid(row=3, column=1, sticky="w", pady=5)

        ttk.Label(f, text="填了用户才会采集机器码；不填只做连通性检查",
                  style="Dim.TLabel").grid(row=4, column=0, columnspan=2, sticky="w", pady=(0, 8))

        btns = ttk.Frame(f)
        btns.grid(row=5, column=0, columnspan=2, sticky="e", pady=(10, 0))
        ttk.Button(btns, text="取消", command=self.destroy).pack(side="right", padx=(8, 0))
        ttk.Button(btns, text="开始扫描", style="Accent.TButton",
                   command=self._ok).pack(side="right")

        self.grab_set()
        self.update_idletasks()
        px, py = master.winfo_rootx(), master.winfo_rooty()
        self.geometry(f"+{px + 250}+{py + 120}")

    def _expand(self, text: str) -> list[str]:
        """支持：单个 IP / hostname / 192.0.2.1-254 / 192.0.2.0/24"""
        hosts: list[str] = []
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue

            # 网段 a.b.c.d/N
            if "/" in line:
                try:
                    import ipaddress
                    net = ipaddress.ip_network(line, strict=False)
                    for ip in net.hosts():
                        hosts.append(str(ip))
                    continue
                except ValueError:
                    pass

            # 范围 a.b.c.1-254
            if "-" in line and "." in line:
                head, _, tail = line.rpartition(".")
                if "-" in tail:
                    try:
                        lo, hi = tail.split("-", 1)
                        for i in range(int(lo), int(hi) + 1):
                            hosts.append(f"{head}.{i}")
                        continue
                    except ValueError:
                        pass

            hosts.append(line)

        # 去重保序，并限制上限避免误填大网段
        seen, out = set(), []
        for h in hosts:
            if h not in seen:
                seen.add(h)
                out.append(h)
        return out[:512]

    def _ok(self) -> None:
        hosts = self._expand(self.txt.get("1.0", "end"))
        if not hosts:
            messagebox.showerror("空", "没有解析出任何地址", parent=self)
            return
        try:
            port = int(self.var_port.get().strip() or 22)
        except ValueError:
            messagebox.showerror("端口", "端口必须是数字", parent=self)
            return
        self.result = {"hosts": hosts, "port": port, "user": self.var_user.get().strip()}
        self.destroy()


def main() -> None:
    app = FleetConsole()
    app.mainloop()


if __name__ == "__main__":
    main()
