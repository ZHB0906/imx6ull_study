#!/usr/bin/env python3
"""
board-telnet-login.py —— 带 login 的 telnet 执行器（给 new/ 的新 rootfs 用）

用法：
    python3 board-telnet-login.py 'uname -r'
    python3 board-telnet-login.py 'cat /etc/issue' --user root --pass root
    python3 board-telnet-login.py 'ls -l /' --host 192.168.10.2 --timeout 30

背景（为什么需要它）：
    old/tools/board.py 假设板子跑 BusyBox telnetd -l /bin/sh（无密码 shell）。
    但新 rootfs 里 dropbear 会先起 S50dropbear，端口 23 上是 BusyBox 的**登录式**
    telnetd（要 root 用户名+密码），所以 board.py 的命令会被当成用户名敲进去。
    这个脚本会**先登录**再执行命令。

    另一个前提：新 rootfs 是经 NFS 部署的，文件属主是 uid 1000（部署时不是 root，
    没法 chown），所以 dropbear 的公钥认证会被拒 —— 用密码登录（root/root，
    来自 BR2_TARGET_GENERIC_ROOT_PASSWD）绕开。
"""
import argparse
import re
import socket
import sys
import time

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240
SENTINEL = "__BOARD_DONE__"
BEGIN = "__BOARD_BEGIN__"


def filter_iac(data: bytes, sock: socket.socket) -> bytes:
    """剥掉 telnet 协商字节，并一律回绝对方选项。"""
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
            if i + 2 >= len(data):
                break
            opt = data[i + 2]
            reply = bytes([IAC, WONT if cmd in (DO, WILL) else DONT, opt])
            try:
                sock.sendall(reply)
            except OSError:
                pass
            i += 3
            continue
        if cmd == SB:
            j = i + 2
            while j + 1 < len(data) and not (data[j] == IAC and data[j + 1] == SE):
                j += 1
            i = j + 2
            continue
        i += 2
    return bytes(out)


class Board:
    def __init__(self, host, port=23, timeout=20):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(1.0)
        self.buf = b""
        self.timeout = timeout

    def _pull(self):
        try:
            data = self.sock.recv(4096)
        except socket.timeout:
            return b""
        except OSError:
            return b""
        if not data:
            return b""
        self.buf += filter_iac(data, self.sock)
        return data

    def read_until(self, patterns, timeout=None):
        """读到任意一个 pattern 出现（bytes 或 list），返回已读内容。"""
        if isinstance(patterns, (bytes, str)):
            patterns = [patterns]
        pats = [p.encode() if isinstance(p, str) else p for p in patterns]
        deadline = time.time() + (timeout or self.timeout)
        while time.time() < deadline:
            for p in pats:
                if p in self.buf:
                    idx = self.buf.index(p) + len(p)
                    chunk, self.buf = self.buf[:idx], self.buf[idx:]
                    return chunk
            self._pull()
        chunk, self.buf = self.buf, b""
        return chunk

    def send_line(self, line: str):
        self.sock.sendall(line.encode() + b"\r\n")

    def login(self, user, password):
        self.read_until([b"login:", b"#", b"$"], timeout=15)
        self.buf = b""
        self.send_line(user)
        self.read_until(b"Password:", timeout=10)
        self.buf = b""
        self.send_line(password)
        out = self.read_until([b"#", b"$"], timeout=15)
        self.buf = b""
        return out

    def run(self, cmd, timeout=25):
        # 用一对标记夹住输出，避免被命令回显/终端折行干扰
        self.send_line(f"echo {BEGIN}; {cmd}; echo {SENTINEL}")
        data = self.read_until(SENTINEL, timeout=timeout)
        text = data.decode("utf-8", "replace").replace("\r\n", "\n")
        if BEGIN in text:
            text = text.split(BEGIN, 1)[1]
        text = text.rsplit(SENTINEL, 1)[0]
        return text.strip("\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd")
    ap.add_argument("--host", default="192.168.10.2")
    ap.add_argument("--port", type=int, default=23)
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default="root")
    ap.add_argument("--timeout", type=int, default=20)
    a = ap.parse_args()

    try:
        b = Board(a.host, a.port, a.timeout)
        b.login(a.user, a.password)
        print(b.run(a.cmd, timeout=max(a.timeout, 25)))
    except OSError as e:
        print(f"✗ 连不上 {a.host}:{a.port} —— {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
