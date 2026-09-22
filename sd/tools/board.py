#!/usr/bin/env python3
"""
board.py —— 通过 telnet 在开发板上执行命令（本项目的"远程手"）

用法：
    python3 tools/board.py 'ls -l /dev/beep'          # 跑一条命令
    python3 tools/board.py --timeout 40 'reboot'      # 长命令
    python3 tools/board.py --raw    'dmesg | tail -20'

背景：
    板子由 /etc/nfs-net.sh 开机启动 BusyBox telnetd（`telnetd -l /bin/sh`），
    无密码 root shell，只在 192.168.10.0/24 这条 host-only 实验网里可达。
    本脚本自己处理 telnet IAC 协商（一律拒绝），发命令、读到哨兵行为止。
"""
import argparse
import re
import socket
import sys
import time

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240
SENTINEL = "__BOARD_DONE__"


def filter_iac(data: bytes, sock: socket.socket) -> bytes:
    """去掉 telnet 协商字节，并一律回绝对方选项（我们只要裸数据）。"""
    out = bytearray()
    i = 0
    while i < len(data):
        b = data[i]
        if b != IAC:
            out.append(b)
            i += 1
            continue
        if i + 1 >= len(data):
            break
        cmd = data[i + 1]
        if cmd == IAC:
            out.append(IAC)
            i += 2
            continue
        if cmd in (DO, DONT, WILL, WONT):
            opt = data[i + 2] if i + 2 < len(data) else 0
            try:
                if cmd == DO:
                    sock.sendall(bytes([IAC, WONT, opt]))
                elif cmd == WILL:
                    sock.sendall(bytes([IAC, DONT, opt]))
            except OSError:
                pass
            i += 3
            continue
        if cmd == SB:                       # 子协商，整段丢掉
            j = data.find(bytes([IAC, SE]), i)
            i = (j + 2) if j != -1 else len(data)
            continue
        i += 2
    return bytes(out)


def run(host: str, port: int, command: str, timeout: float, raw: bool) -> int:
    try:
        s = socket.create_connection((host, port), timeout=8)
    except OSError as e:
        print(f"✗ 连不上 {host}:{port} —— {e}", file=sys.stderr)
        print("  → 板子上有没有跑 telnetd？先执行： sh /mnt/nfs/root/45_install_hook.sh",
              file=sys.stderr)
        return 2

    s.settimeout(1.0)
    time.sleep(0.4)                          # 等服务端把 IAC 协商发过来
    s.sendall((command + "\n" + f"echo {SENTINEL}$?\n").encode())

    buf = bytearray()
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        if not chunk:
            break
        buf += filter_iac(chunk, s)
        if SENTINEL.encode() in buf:
            break
    s.close()

    text = bytes(buf).decode("utf-8", "replace")
    text = text.replace("\r\n", "\n").replace("\r", "")

    # telnet 会把我们发的命令回显一遍，所以 __BOARD_DONE__ 会出现两次：
    # 一次是回显里的字面量 "__BOARD_DONE__$?"，一次是真正展开的结果。
    # 取【最后一个】后面紧跟数字的匹配才是真的。
    rc = None
    body = text
    last = None
    for m in re.finditer(r"__BOARD_DONE__(\d+)", text):
        last = m
    if last is not None:
        rc = last.group(1)
        body = text[:last.start()]

    # 去掉服务端回显：我们发的命令 + 哨兵那条
    lines = body.split("\n")
    head = command.strip()[:24]
    cleaned = []
    for ln in lines:
        if head and ln.startswith(head):
            continue
        if ln.startswith(f"echo {SENTINEL}"):
            continue
        cleaned.append(ln)
    out = "\n".join(cleaned).strip("\n")

    if raw:
        sys.stdout.write(out + "\n")
    else:
        if out:
            sys.stdout.write(out + "\n")
    if rc is not None:
        print(f"[exit={rc}]")
    elif not raw:
        print("(超时：没看到哨兵，输出可能被截断)", file=sys.stderr)
    return int(rc) if (rc or "").isdigit() else 0


def main() -> int:
    ap = argparse.ArgumentParser(description="在开发板上跑一条命令（走 telnet）")
    ap.add_argument("command", help="要在板子上执行的 shell 命令")
    ap.add_argument("--host", default="192.168.10.2")
    ap.add_argument("--port", type=int, default=23)
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--raw", action="store_true", help="原样输出，不整理")
    a = ap.parse_args()
    return run(a.host, a.port, a.command, a.timeout, a.raw)


if __name__ == "__main__":
    sys.exit(main())
