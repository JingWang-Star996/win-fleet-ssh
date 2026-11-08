# -*- coding: utf-8 -*-
"""
机器登记册 v2 —— 以机器码为主键，地址可漂移。

与 v1 的关键区别：
  v1: 每台机器一个 ip 字段，IP 变了就认不出。
  v2: 每台机器一个 machineId（机器码）+ 一个地址簿（多个候选地址）。
      连接时按地址簿逐个尝试，成功一个就把其它地址标记为备选。
      IP 变了只需往地址簿里加新地址，档案不变。

文件结构：
  {
    "schema": 2,
    "machines": { "<machineId>": { ...MachineRecord... } },
    "audit": [ ... ]
  }
"""
from __future__ import annotations

import json
import os
import shutil
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any

import identity

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
REGISTRY = DATA_DIR / "registry.json"
BACKUP_DIR = DATA_DIR / "backups"


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def empty() -> dict[str, Any]:
    return {"schema": 2, "machines": {}, "audit": []}


# ---------------------------------------------------------------- 读写
def load() -> dict[str, Any]:
    """读登记册。自动从 v1 迁移。"""
    if not REGISTRY.exists():
        return empty()
    try:
        with REGISTRY.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        try:
            bad = DATA_DIR / f"registry.broken-{datetime.now():%Y%m%d-%H%M%S}.json"
            shutil.copy2(REGISTRY, bad)
        except OSError:
            pass
        return empty()

    # v1 是列表，v2 是字典 —— 自动迁移
    if data.get("schema", 1) == 1 or isinstance(data.get("machines"), list):
        data = _migrate_v1(data)
        try:
            save(data)
        except Exception:
            pass

    data.setdefault("schema", 2)
    data.setdefault("machines", {})
    data.setdefault("audit", [])
    return data


def _migrate_v1(old: dict) -> dict[str, Any]:
    """把 v1 的列表结构转成 v2 的机器码索引结构。

    v1 没有机器码，迁移时用旧 id/name 生成一个"临时码"，
    并在备注里标注，等下次真正连上时再换成真实机器码。
    """
    import hashlib

    new = empty()
    for m in old.get("machines", []) or []:
        name = (m.get("name") or "").strip()
        ip = (m.get("ip") or "").strip()
        # 用 name+ip 合成临时码，并打上 legacy 前缀便于识别
        seed = f"legacy:{name}|{ip}".lower()
        tid = "legacy-" + hashlib.sha256(seed.encode()).hexdigest()[:10]

        rec = identity.MachineRecord(
            machineId=tid,
            hostname=name,
            role=m.get("role", ""),
            owner=m.get("owner", ""),
            project=m.get("project", ""),
            os=m.get("os", "Windows"),
            deployed=bool(m.get("deployed")),
            deployMode=m.get("deployMode", ""),
            dsh=bool(m.get("dsh")),
            dshVerified=bool(m.get("dshVerified")),
            user=m.get("user", ""),
            notes=(m.get("notes", "") + " [从未验证机器码，待连接后自动升级]").strip(),
            firstSeen=m.get("createdAt", now_iso()),
            lastSeen=m.get("lastSeen", ""),
        )
        if ip and ip not in ("(UU)", ""):
            try:
                port = int(m.get("port") or 22)
            except (TypeError, ValueError):
                port = 22
            rec.add_address(ip, port, "lan", "迁移自 v1")
        new["machines"][tid] = rec.to_dict()

    new["audit"] = old.get("audit", []) or []
    new["audit"].append({
        "time": now_iso(), "machine": "-", "action": "migrate",
        "result": "ok", "detail": f"从 v1 迁移 {len(new['machines'])} 台机器",
    })
    return new


def save(data: dict[str, Any]) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(DATA_DIR), prefix=".registry-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp, REGISTRY)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def backup() -> Path | None:
    if not REGISTRY.exists():
        return None
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    dst = BACKUP_DIR / f"registry-{datetime.now():%Y%m%d-%H%M%S}.json"
    shutil.copy2(REGISTRY, dst)
    return dst


# ---------------------------------------------------------------- 查询
def all_machines(data: dict) -> list[dict]:
    return list(data.get("machines", {}).values())


def get(data: dict, key: str) -> dict | None:
    """按 machineId、主机名或任一地址查找。"""
    k = (key or "").strip()
    if not k:
        return None
    kl = k.lower()

    machines = data.get("machines", {})
    if k in machines:
        return machines[k]

    for mid, m in machines.items():
        if mid.lower() == kl:
            return m
        if (m.get("hostname") or "").lower() == kl:
            return m
        for a in m.get("addresses", []) or []:
            if (a.get("host") or "").lower() == kl:
                return m
    return None


def find_by_id(data: dict, machine_id: str) -> dict | None:
    return data.get("machines", {}).get(machine_id)


def resolve_or_create(data: dict, collected: dict) -> tuple[dict, bool]:
    """用采集到的身份信息查找机器；找不到就新建。

    返回 (记录, 是否新建)。
    这是"机器码识别"的核心入口：只要机器码对得上，
    不管 IP 变成什么，都认为是同一台机器。
    """
    mid = collected.get("machineId") or ""
    if not mid:
        raise ValueError("采集结果缺少 machineId")

    machines = data.setdefault("machines", {})
    existing = machines.get(mid)

    # 若存在 legacy 临时码的同类记录，将其升级为真实机器码
    if not existing:
        hostname = (collected.get("hostname") or "").lower()
        for lid, lm in list(machines.items()):
            if lid.startswith("legacy-") and (lm.get("hostname") or "").lower() == hostname:
                # 升级：保留原有字段，换主键
                del machines[lid]
                lm["machineId"] = mid
                lm["identity"] = collected
                lm["notes"] = (lm.get("notes", "") or "").replace(
                    " [从未验证机器码，待连接后自动升级]", " [已升级为真实机器码]")
                machines[mid] = lm
                log_action(data, mid, "upgrade", "ok",
                           f"临时码 {lid} -> 真实机器码 {mid}")
                existing = lm
                break

    if existing:
        existing["identity"] = collected
        if collected.get("hostname"):
            existing["hostname"] = collected["hostname"]
        existing["lastSeen"] = now_iso()
        return existing, False

    rec = identity.MachineRecord(
        machineId=mid,
        hostname=collected.get("hostname", ""),
        identity=collected,
        firstSeen=now_iso(),
        lastSeen=now_iso(),
    )
    machines[mid] = rec.to_dict()
    return machines[mid], True


# ---------------------------------------------------------------- 修改
def touch_address(data: dict, machine_id: str, host: str, port: int,
                  ok: bool, kind: str = "lan", note: str = "") -> None:
    """记录一次地址尝试结果。"""
    m = find_by_id(data, machine_id)
    if not m:
        return

    rec = identity.from_dict(m)
    rec.add_address(host, port, kind, note)

    ts = now_iso()
    for a in rec.addresses:
        if a.get("host") == host and int(a.get("port", 22)) == int(port):
            a["lastTry"] = ts
            if ok:
                a["lastOk"] = ts
                a["failCount"] = 0
                rec.online = True
                rec.onlineAddress = f"{host}:{port}"
                rec.lastSeen = ts
            else:
                a["failCount"] = int(a.get("failCount") or 0) + 1
            break

    m.update(rec.to_dict())


def mark_offline(data: dict, machine_id: str) -> None:
    m = find_by_id(data, machine_id)
    if m:
        m["online"] = False
        m["onlineAddress"] = ""


def remove(data: dict, key: str) -> bool:
    m = get(data, key)
    if not m:
        return False
    data["machines"].pop(m["machineId"], None)
    return True


# ---------------------------------------------------------------- 审计
def log_action(data: dict, machine: str, action: str, result: str, detail: str = "") -> dict:
    entry = {
        "time": now_iso(),
        "machine": machine,
        "action": action,
        "result": result,
        "detail": detail,
    }
    audit = data.setdefault("audit", [])
    audit.append(entry)
    if len(audit) > 5000:
        data["audit"] = audit[-5000:]
    return entry


def audit_for(data: dict, key: str) -> list[dict]:
    k = (key or "").lower()
    out = []
    for e in data.get("audit", []):
        mk = (e.get("machine") or "").lower()
        if mk == k:
            out.append(e)
    return out
