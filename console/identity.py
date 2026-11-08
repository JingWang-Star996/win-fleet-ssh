# -*- coding: utf-8 -*-
"""
机器身份解析（identity）

问题：目标机的 IP 每次重启都可能变（DHCP / 不同网段 / UU 隧道）。
      用 IP 当唯一标识，地址一变记录就失效。

方案：用几个稳定的硬件/系统标识拼出机器码，作为主键；
      同时记录"当前所有已知地址"，连不上就换下一个试。

机器码字段的稳定性排序（实测经验）：
  1. MachineGuid        HKLM\SOFTWARE\Microsoft\Cryptography —— 重装系统才变
  2. BIOS 序列号        重装系统不变，换主板才变
  3. 系统盘的 VolumeID  格式化才变
  4. 主机名             可以手动改，但通常稳定
  5. 各网卡 MAC         虚拟网卡会变，物理网卡较稳

单一字段都不够可靠，所以合成一个短码：
  machineId = sha256(MachineGuid + BIOS序列号)[:16]
这样做的好处：
  - 即使某个字段缺失，还有其它字段保底
  - 短码便于人读和写进文件名
"""
from __future__ import annotations

import hashlib
import json
import re
import socket
import subprocess
from dataclasses import dataclass, field, asdict
from typing import Any

SSH_EXE = r"C:\Windows\System32\OpenSSH\ssh.exe"


# ---------------------------------------------------------------- 采集
def _run(cmd: list[str], timeout: int = 20) -> str:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           encoding="utf-8", errors="replace")
        return (p.stdout or "") + (p.stderr or "")
    except Exception:
        return ""


def collect_local() -> dict[str, Any]:
    """采集本机的身份信息。失败字段留空，不抛异常。"""
    info: dict[str, Any] = {}

    # MachineGuid
    out = _run(["powershell", "-NoProfile", "-Command",
                "(Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Cryptography' -Name MachineGuid).MachineGuid"])
    m = re.search(r"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})", out)
    info["machineGuid"] = m.group(1).lower() if m else ""

    # BIOS 序列号
    out = _run(["powershell", "-NoProfile", "-Command",
                "(Get-CimInstance Win32_BIOS).SerialNumber"])
    bios = out.strip().splitlines()
    info["biosSerial"] = (bios[0].strip() if bios else "")

    # 系统盘卷 ID
    out = _run(["powershell", "-NoProfile", "-Command",
                "(Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='C:'\").VolumeSerialNumber"])
    info["volumeSerial"] = out.strip().splitlines()[0].strip() if out.strip() else ""

    # 主机名
    info["hostname"] = socket.gethostname()

    # 物理网卡 MAC（排除虚拟）
    out = _run(["powershell", "-NoProfile", "-Command",
                "Get-NetAdapter -Physical -ErrorAction SilentlyContinue | "
                "Where-Object {$_.Status -eq 'Up'} | Select-Object -First 1 -ExpandProperty MacAddress"])
    info["mac"] = out.strip().splitlines()[0].strip() if out.strip() else ""

    info["machineId"] = make_id(info)
    return info


def collect_remote(host: str, port: int, user: str, timeout: int = 25) -> dict[str, Any]:
    """通过 SSH 采集目标机身份。连不上返回空 dict。

    踩过的坑：
      把 PS 命令直接作为 ssh 的最后一个参数时，引号会被 ssh 和远端
      cmd 双重解析，容易丢掉引号导致命令被拆开。
      实测用 -EncodedCommand 最稳（Base64，零解析），但本地安全策略
      可能拦。折中方案：写成单行的 reg query / wmic 等原生命令，
      只用最简单的引号，并用固定前缀标记输出行。
    """
    if not host or not user:
        return {}

    # 每条都是无嵌套引号的简单命令，用 echo 加固定前缀
    # 注意：远端默认 shell 可能是 cmd 或 powershell，这里显式走 cmd /c
    ps = (
        "$g='';"
        "try{$g=(Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Cryptography' -ErrorAction Stop).MachineGuid}catch{};"
        "$b='';try{$b=(Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber}catch{};"
        "$v='';try{$v=(Get-CimInstance Win32_LogicalDisk -Filter \\\"DeviceID='C:'\\\" -ErrorAction SilentlyContinue).VolumeSerialNumber}catch{};"
        "$m='';try{$m=(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {$_.Status -eq 'Up'} | Select-Object -First 1).MacAddress}catch{};"
        "Write-Output ('ID_GUID=' + $g);"
        "Write-Output ('ID_BIOS=' + $b);"
        "Write-Output ('ID_VOL=' + $v);"
        "Write-Output ('ID_MAC=' + $m);"
        "Write-Output ('ID_HOST=' + $env:COMPUTERNAME)"
    )

    # 把 PS 脚本写到临时文件再执行，彻底避免引号问题
    # 做法：用 printf 风格的 echo 逐行写文件在远端太脆弱，
    # 改为把脚本 base64 后让远端解码执行 —— 这是唯一零解析的方式。
    import base64
    b64 = base64.b64encode(ps.encode("utf-16-le")).decode("ascii")

    # 远端：写 base64 到临时文件，再用 -EncodedCommand 执行
    remote_cmd = (
        f"powershell -NoProfile -EncodedCommand {b64}"
    )

    cmd = [
        SSH_EXE,
        "-o", "StrictHostKeyChecking=no",
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={max(5, timeout // 2)}",
        "-p", str(port),
        f"{user}@{host}",
        remote_cmd,
    ]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 10,
                           encoding="utf-8", errors="replace")
        out = (p.stdout or "")

        info: dict[str, Any] = {
            "machineGuid": "", "biosSerial": "", "volumeSerial": "",
            "mac": "", "hostname": "",
        }
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("ID_GUID="):
                info["machineGuid"] = line[8:].strip().lower()
            elif line.startswith("ID_BIOS="):
                info["biosSerial"] = line[8:].strip()
            elif line.startswith("ID_VOL="):
                info["volumeSerial"] = line[7:].strip()
            elif line.startswith("ID_MAC="):
                info["mac"] = line[7:].strip()
            elif line.startswith("ID_HOST="):
                info["hostname"] = line[8:].strip()

        if not any([info["machineGuid"], info["biosSerial"], info["volumeSerial"]]):
            return {}
        info["machineId"] = make_id(info)
        return info
    except Exception:
        return {}


def make_id(info: dict[str, Any]) -> str:
    """由稳定字段合成短机器码。

    策略：按可靠性依次尝试，只要拿到一个足够独特的字段就生成。
    这样即使某台机器取不到 BIOS，也不会导致生成失败。

    注意：很多品牌机/组装机的 BIOS 序列号是 "Default string"、
    "To be filled by O.E.M." 这类占位值，多台机器会重复。
    这类值必须排除，否则会让不同机器算出相同机器码。
    """
    JUNK = {
        "", "default string", "to be filled by o.e.m.", "none", "n/a",
        "system serial number", "0", "unknown", "not specified",
        "chassis serial number", "base board serial number",
    }

    def clean(v: Any) -> str:
        s = (str(v) if v is not None else "").strip()
        return "" if s.lower() in JUNK else s

    guid = clean(info.get("machineGuid"))
    bios = clean(info.get("biosSerial"))
    vol = clean(info.get("volumeSerial"))
    mac = clean(info.get("mac"))

    # 归一化 MAC：统一大写、去掉分隔符，避免格式差异导致码漂移
    if mac:
        mac = re.sub(r"[^0-9A-Fa-f]", "", mac).upper()
        # 排除虚拟网卡前缀（VMware 00:50:56 / 00:0C:29 / 00:05:69，
        # VirtualBox 08:00:27，Hyper-V 00:15:5D）
        VIRTUAL_PREFIXES = ("005056", "000C29", "000569", "080027", "00155D")
        if any(mac.startswith(p) for p in VIRTUAL_PREFIXES):
            mac = ""

    # ============================================================
    # 关键：GUID + MAC 组合
    # ============================================================
    # 2026-11-06 踩的坑：用同一个系统镜像克隆出来的机器，
    # MachineGuid 完全相同（NODE-01 和 NODE-02 都是 8ebba3f3-...），
    # 只按 GUID 算会导致机器码撞车，登记时互相覆盖。
    #
    # 实测四台机器：GUID 有两台相同，但 MAC 各不相同。
    # 所以：GUID 为主 + MAC 为区分符，两者都参与哈希。
    #
    # 为什么不掺 BIOS/VolumeSerial：
    #   实测同一台机器的 BIOS 可能是 "Default string" 占位值，
    #   被工具改写后会让机器码漂移，档案认不出老机器。
    #   MAC 相对稳定（换网卡才变），且克隆机必然不同。
    if guid:
        seed = "guid:" + guid
        if mac:
            seed += "|mac:" + mac
        return hashlib.sha256(seed.encode("utf-8")).hexdigest()[:16]

    # 没有 GUID：mac 优先，其次 BIOS/VOL
    if mac:
        return hashlib.sha256(("mac:" + mac).encode("utf-8")).hexdigest()[:16]
    if bios or vol:
        seed = "hw:" + "|".join(p for p in (bios, vol) if p)
        return hashlib.sha256(seed.encode("utf-8")).hexdigest()[:16]

    # 全都没有，退化到主机名（不稳定，但总比没有好）
    seed = "fallback:" + (info.get("hostname") or "unknown")
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()[:16]


# ---------------------------------------------------------------- 地址簿
# 地址用普通 dict 存储，字段固定，便于直接落 JSON：
#   { "host": str, "port": int, "kind": str, "note": str,
#     "lastOk": str, "lastTry": str, "failCount": int }
ADDR_FIELDS = ("host", "port", "kind", "note", "lastOk", "lastTry", "failCount")


def new_address(host: str, port: int = 22, kind: str = "lan", note: str = "") -> dict:
    return {
        "host": host.strip(), "port": int(port), "kind": kind, "note": note,
        "lastOk": "", "lastTry": "", "failCount": 0,
    }


@dataclass
class MachineRecord:
    """一台机器的完整档案。主键是 machineId，不是 IP。"""
    machineId: str
    hostname: str = ""
    addresses: list[dict] = field(default_factory=list)
    role: str = ""
    owner: str = ""
    project: str = ""
    os: str = "Windows"
    deployed: bool = False
    deployMode: str = ""
    dsh: bool = False
    dshVerified: bool = False
    user: str = ""
    notes: str = ""
    firstSeen: str = ""
    lastSeen: str = ""
    identity: dict = field(default_factory=dict)   # 原始采集字段
    online: bool = False
    onlineAddress: str = ""

    def add_address(self, host: str, port: int = 22, kind: str = "lan", note: str = "") -> None:
        host = (host or "").strip()
        if not host:
            return
        for a in self.addresses:
            if a.get("host") == host and int(a.get("port", 22)) == int(port):
                if note:
                    a["note"] = note
                if kind and kind != "manual":
                    a["kind"] = kind
                return
        self.addresses.append(new_address(host, port, kind, note))

    def best_address(self) -> dict | None:
        """挑最可能连上的地址：优先最近成功的，其次失败次数少的。"""
        if not self.addresses:
            return None

        def score(a: dict) -> tuple:
            ok = 1 if a.get("lastOk") else 0
            fails = -(a.get("failCount") or 0)
            # tailscale 地址比 LAN 更稳定，同等条件下优先
            kind_rank = 2 if a.get("kind") == "tailscale" else (1 if a.get("kind") == "lan" else 0)
            return (ok, kind_rank, fails)

        return sorted(self.addresses, key=score, reverse=True)[0]

    def ordered_addresses(self) -> list[dict]:
        """全部地址按优先级排序，供逐个尝试。"""
        return sorted(
            self.addresses,
            key=lambda a: (
                1 if a.get("lastOk") else 0,
                2 if a.get("kind") == "tailscale" else (1 if a.get("kind") == "lan" else 0),
                -(a.get("failCount") or 0),
            ),
            reverse=True,
        )

    def to_dict(self) -> dict:
        return asdict(self)


def from_dict(d: dict) -> MachineRecord:
    allowed = {f for f in MachineRecord.__dataclass_fields__}
    return MachineRecord(**{k: v for k, v in d.items() if k in allowed})
