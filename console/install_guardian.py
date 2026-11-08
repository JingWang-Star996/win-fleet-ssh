# -*- coding: utf-8 -*-
"""
在目标机上安装守护进程（ssh-guardian）。

守护进程的作用：即使 SSH 挂了，它也会自动把它拉起来，
不需要人回到那台机器前操作。

注册成计划任务：
  - 开机启动（SYSTEM 身份，不需要登录）
  - 每 10 分钟检查一次（万一看门狗进程本身挂了）

注意：守护进程用 SYSTEM 身份运行不影响它拉 sshd ——
sshd 由它启动时会继承 SYSTEM，但实测 SYSTEM 跑 sshd 在某些机器会崩，
所以守护脚本内部会优先用「用户身份前台进程」兜底，
并配合 S4U 任务（如果可用）。
"""
import sys
import subprocess
from pathlib import Path

GUARDIAN_LOCAL = r"C:\ProgramData\ssh-guardian\ssh-guardian.ps1"
TASK_NAME = "SshGuardian"


def run(cmd: list[str], timeout: int = 60) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           encoding="utf-8", errors="replace")
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except Exception as exc:  # noqa: BLE001
        return -1, str(exc)


def main() -> int:
    src = sys.argv[1] if len(sys.argv) > 1 else ""
    if not src or not Path(src).exists():
        print(f"用法: {sys.argv[0]} <ssh-guardian.ps1 路径>")
        return 1

    # 1. 复制到固定位置
    target = Path(GUARDIAN_LOCAL)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(Path(src).read_text(encoding="utf-8-sig"), encoding="utf-8-sig")
    print(f"[OK] 已复制: {target}")

    # 2. 创建启动器（VBS 隐藏窗口）
    vbs = target.parent / "guardian-launch.vbs"
    vbs.write_text(
        'Set sh = CreateObject("WScript.Shell")\r\n'
        f'sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{target}""", 0, False\r\n',
        encoding="ascii",
    )
    print(f"[OK] 启动器: {vbs}")

    # 3. 注册计划任务
    rc, out = run(["schtasks.exe", "/delete", "/tn", TASK_NAME, "/f"])
    tr = f'wscript.exe "{vbs}"'
    rc, out = run([
        "schtasks.exe", "/create", "/tn", TASK_NAME, "/tr", tr,
        "/sc", "minute", "/mo", "10", "/ru", "SYSTEM", "/rl", "HIGHEST", "/f",
    ])
    if rc != 0:
        print(f"[FAIL] 注册失败: {out.strip()}")
        return 2
    print(f"[OK] 计划任务已注册: {TASK_NAME}（每 10 分钟）")

    # 4. 补开机触发器
    rc, xml = run(["schtasks.exe", "/query", "/tn", TASK_NAME, "/xml"])
    if rc == 0 and "<Triggers>" in xml:
        boot = "<BootTrigger><Enabled>true</Enabled><Delay>PT1M</Delay></BootTrigger>"
        new_xml = xml.replace("<Triggers>", "<Triggers>" + boot, 1)
        tmp = Path(r"C:\Windows\Temp\guardian-task.xml")
        # 计划任务 XML 需要 UTF-16
        tmp.write_text(new_xml, encoding="utf-16")
        rc2, out2 = run(["schtasks.exe", "/create", "/tn", TASK_NAME, "/xml", str(tmp), "/f"])
        print(f"{'[OK]' if rc2 == 0 else '[WARN]'} 开机触发器: {'已添加' if rc2 == 0 else out2.strip()[:100]}")
        try:
            tmp.unlink()
        except OSError:
            pass

    # 5. 立即启动一次
    run(["schtasks.exe", "/run", "/tn", TASK_NAME])
    print("[OK] 已触发首次运行")

    # 6. 验证
    rc, q = run(["schtasks.exe", "/query", "/tn", TASK_NAME, "/fo", "LIST"])
    print("\n任务状态:")
    for line in q.splitlines():
        if any(k in line for k in ("TaskName", "Status", "任务名", "状态")):
            print(f"  {line.strip()}")

    print(f"\n守护日志: {target.parent / 'guardian.log'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
