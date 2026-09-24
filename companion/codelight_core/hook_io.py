from __future__ import annotations

import json
import os
import socket
import time


WINDOWS_HOOK_HOST = "127.0.0.1"
WINDOWS_HOOK_PORT = 8766


def _connect_hook_socket(socket_path: str, timeout: float):
    """Connect to the local hook transport.

    Unix/macOS/Linux keep using the existing Unix-domain socket. Windows
    falls back to a loopback-only TCP socket because some Windows Python
    builds don't expose AF_UNIX.
    """
    if hasattr(socket, "AF_UNIX"):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        address = socket_path
    else:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        address = (WINDOWS_HOOK_HOST, WINDOWS_HOOK_PORT)

    sock.settimeout(timeout)
    sock.connect(address)
    return sock


def send_json(socket_path: str, payload: dict, *, timeout: float,
              newline: bool = False) -> bool:
    """Best-effort fire-and-forget JSON send to the local daemon."""
    sock = None
    try:
        sock = _connect_hook_socket(socket_path, timeout)
        raw = json.dumps(payload)
        if newline:
            raw += "\n"
        sock.sendall(raw.encode())
        return True
    except Exception:
        return False
    finally:
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass


def request_json(socket_path: str, payload: dict, *, connect_timeout: float,
                 response_timeout: float, max_bytes: int) -> dict | None:
    """Send a JSON request and read one newline-delimited JSON response."""
    sock = None
    try:
        sock = _connect_hook_socket(socket_path, connect_timeout)
        sock.sendall((json.dumps(payload) + "\n").encode())

        sock.settimeout(response_timeout)
        buf = b""
        while b"\n" not in buf and len(buf) < max_bytes:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
        if not buf.strip():
            return None
        data = json.loads(buf.decode())
        return data if isinstance(data, dict) else None
    except Exception:
        return None
    finally:
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass


def read_json_message(conn, *, max_bytes: int) -> dict | None:
    """Read one JSON object from a socket, stopping at newline/EOF/max_bytes."""
    try:
        raw = b""
        while b"\n" not in raw and len(raw) < max_bytes:
            chunk = conn.recv(4096)
            if not chunk:
                break
            raw += chunk
        if not raw.strip():
            return None
        line = raw.split(b"\n", 1)[0]
        data = json.loads(line.decode())
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def write_monitor_state(
    state_dir: str,
    *,
    session_id: str,
    state: str,
    agent_id: str,
    hook_event: str = "",
) -> None:
    """Fallback state file used when the daemon socket is unavailable."""
    os.makedirs(state_dir, exist_ok=True)
    path = os.path.join(state_dir, f"{session_id}.json")
    if state == "ended":
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        return
    try:
        with open(path, "w") as f:
            json.dump({
                "state": state,
                "time": time.time(),
                "session_id": session_id,
                "agent_id": agent_id,
                "hook_event": hook_event,
            }, f)
    except Exception:
        pass
