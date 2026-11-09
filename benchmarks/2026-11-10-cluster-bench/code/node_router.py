# -*- coding: utf-8 -*-
"""节点路由器：按能力把任务派给合适的节点。

这是 SA 现在完全没有的一层，也是「异构集群」的地基。

设计取舍
    1. 能力用声明式（nodes.json），不用动态探测
       —— 动态探测准确但复杂，先用声明式验证可行性
    2. 路由用「能力子集匹配 + 负载最小优先」
       —— 简单可解释，出问题时能一眼看出为什么选它
    3. 无解时明确报错，不猜
       —— 集群里没有 video 能力就报错，硬派只会浪费时间

对外接口
    Router.load()                  加载注册表
    Router.route(requires, exact=) 选一个节点
    Router.explain(requires)       给出路由理由（调试用）
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field


@dataclass
class Node:
    name: str
    host: str
    role: str
    capabilities: set[str] = field(default_factory=set)
    cpu: str = ""
    cores: int = 0
    models: list[str] = field(default_factory=list)
    max_concurrent: int = 1
    notes: str = ""

    # 运行时状态（不来自 json）
    online: bool = True
    inflight: int = 0

    def can(self, requires: set[str]) -> bool:
        return requires <= self.capabilities

    def load(self) -> float:
        """负载率 0..1。用于挑选最空闲的节点。"""
        cap = max(1, self.max_concurrent)
        return min(1.0, self.inflight / cap)

    def free_slots(self) -> int:
        return max(0, self.max_concurrent - self.inflight)


class Router:
    def __init__(self, nodes: dict[str, Node]):
        self.nodes = nodes

    @classmethod
    def load(cls, path: str | None = None) -> "Router":
        if path is None:
            # 本文件在 <控制台根>/node_router.py，注册表在 <控制台根>/config/nodes.json
            here = os.path.dirname(os.path.abspath(__file__))
            path = os.path.join(here, "config", "nodes.json")
        raw = json.load(open(path, encoding="utf-8"))
        nodes: dict[str, Node] = {}
        for name, d in (raw.get("nodes") or {}).items():
            nodes[name] = Node(
                name=name,
                host=d.get("host", ""),
                role=d.get("role", ""),
                capabilities=set(d.get("capabilities") or []),
                cpu=d.get("cpu", ""),
                cores=int(d.get("cores") or 0),
                models=list(d.get("models") or []),
                max_concurrent=int(d.get("maxConcurrent") or 1),
                notes=d.get("notes", ""),
            )
        return cls(nodes)

    def candidates(self, requires: set[str]) -> list[Node]:
        """有能力做这件事、且在线、且有空闲槽的节点。"""
        return [n for n in self.nodes.values()
                if n.online and n.can(requires) and n.free_slots() > 0]

    def route(self, requires: set[str], exact: bool = False) -> Node | None:
        """挑一个节点。

        exact=False：能力是超集即可（节点会的比要求多，可以干）
        exact=True ：能力必须完全相等（用于测试严格匹配）
        """
        req = set(requires)
        pool = self.candidates(req)
        if exact:
            pool = [n for n in pool if n.capabilities == req]
        if not pool:
            return None
        # 优先：负载低 -> 并发余量大 -> 名字（稳定排序，便于复现）
        pool.sort(key=lambda n: (n.load(), -n.free_slots(), n.name))
        return pool[0]

    def explain(self, requires: set[str]) -> dict:
        """给出完整的路由决策理由，用于调试和测试断言。"""
        req = set(requires)
        all_nodes = list(self.nodes.values())
        capable = [n for n in all_nodes if n.can(req)]
        online = [n for n in capable if n.online]
        with_slot = [n for n in online if n.free_slots() > 0]
        chosen = self.route(req)

        return {
            "requires": sorted(req),
            "total": len(all_nodes),
            "capable": [n.name for n in capable],
            "online": [n.name for n in online],
            "has_slot": [n.name for n in with_slot],
            "chosen": chosen.name if chosen else None,
            "reason": (
                f"chose {chosen.name} (load={chosen.load():.2f}, "
                f"free={chosen.free_slots()}/{chosen.max_concurrent})"
                if chosen else
                self._no_route_reason(req, capable, online, with_slot)
            ),
        }

    def _no_route_reason(self, req, capable, online, with_slot) -> str:
        all_caps = set()
        for n in self.nodes.values():
            all_caps |= n.capabilities
        missing = req - all_caps
        if missing:
            return f"no node has capability: {sorted(missing)}"
        if not capable:
            # 关键情况：没有任何单节点能覆盖全部能力，
            # 但集群合起来能覆盖 —— 这需要多节点协作，不是"无解"
            coverable = req <= all_caps
            if coverable:
                return (f"no single node covers all of {sorted(req)}; "
                        f"cluster can cover it via multiple nodes "
                        f"(use plan() to split)")
            return "no node satisfies the full capability set"
        if not online:
            return f"capable nodes are offline: {[n.name for n in capable]}"
        if not with_slot:
            return f"capable nodes are all busy: {[n.name for n in online]}"
        return "unknown"

    # ------------------------------------------------------------ 多节点协作
    def plan(self, requires: set[str], exclusive: bool = False) -> list[dict]:
        """把一组能力需求拆给多个节点。

        为什么需要这个
            单个节点的能力往往覆盖不了复杂任务。
            「算力 + 生图」需要两台机器，SA 完全没有这个概念。
            这个函数给出最小节点集合，是异构协作的入口。

        exclusive=True
            每个能力独占一个节点（即使某节点能干多件事也不复用），
            用于测试「能力隔离」场景。

        算法
            贪心集合覆盖：每轮选能覆盖最多未满足能力的节点。
            节点数很少（<100），贪心足够；不引入整数规划复杂度。
        """
        remaining = set(requires)
        # 只考虑在线且有空槽的
        pool = [n for n in self.nodes.values() if n.online and n.free_slots() > 0]
        plan: list[dict] = []
        used: set[str] = set()

        while remaining:
            best = None
            best_cover: set[str] = set()
            for n in pool:
                if exclusive and n.name in used:
                    continue
                cover = n.capabilities & remaining
                if len(cover) > len(best_cover):
                    best, best_cover = n, cover
            if best is None or not best_cover:
                break
            plan.append({
                "node": best.name,
                "host": best.host,
                "covers": sorted(best_cover),
            })
            remaining -= best_cover
            used.add(best.name)

        return plan

    def explain_plan(self, requires: set[str], exclusive: bool = False) -> dict:
        req = set(requires)
        plan = self.plan(req, exclusive)
        covered = set()
        for step in plan:
            covered |= set(step["covers"])
        return {
            "requires": sorted(req),
            "plan": plan,
            "nodeCount": len(plan),
            "covered": sorted(covered),
            "uncovered": sorted(req - covered),
            "feasible": req <= covered,
        }


# ---------------------------------------------------------------- 自测
if __name__ == "__main__":
    r = Router.load()
    print(f"已加载 {len(r.nodes)} 个节点\n")

    print("=== 节点能力一览 ===")
    for n in sorted(r.nodes.values(), key=lambda x: x.name):
        caps = ", ".join(sorted(n.capabilities))
        print(f"  {n.name:18} {n.role:12} [{caps}]  并发{n.max_concurrent}")

    print()
    print("=== 单节点路由 ===")
    single_tests = [
        (["compute"], "纯算力"),
        (["code"], "写代码"),
        (["summarize"], "汇总"),
        (["code", "review"], "代码审查"),
        (["image"], "生图"),
        (["video"], "生视频"),
    ]
    ok_count = 0
    for req, desc in single_tests:
        e = r.explain(set(req))
        mark = "OK  " if e["chosen"] else "无解 "
        if e["chosen"]:
            ok_count += 1
        print(f"  {mark} {desc:12} -> {e['chosen'] or '-':18} {e['reason']}")
    print(f"  单节点路由: {ok_count}/{len(single_tests)}")

    print()
    print("=== 多节点协作（单节点覆盖不了时）===")
    multi_tests = [
        (["compute", "image"], "算力+生图"),
        (["code", "summarize"], "写码+汇总"),
        (["compute", "code", "summarize", "image"], "全流程"),
        (["compute", "video", "image"], "算力+视频+图"),
    ]
    for req, desc in multi_tests:
        ep = r.explain_plan(set(req))
        mark = "OK  " if ep["feasible"] else "缺能力"
        print(f"  {mark} {desc:14} requires={sorted(req)}")
        print(f"       需要 {ep['nodeCount']} 个节点:")
        for step in ep["plan"]:
            print(f"         - {step['node']:18} 承担 {step['covers']}")
        if ep["uncovered"]:
            print(f"       缺: {ep['uncovered']}")

    print()
    print("=== 关键发现 ===")
    ep = r.explain_plan({"compute", "image"})
    single = r.route({"compute", "image"})
    print(f"  compute+image 单节点可行: {single is not None}")
    print(f"  多节点方案节点数: {ep['nodeCount']}")
    print(f"  -> 结论：复杂任务必须靠多节点协作，SA 当前无此能力")
