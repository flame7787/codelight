from __future__ import annotations

import os
import socket
from collections.abc import Callable
from typing import Any

from codelight_core import hook_io


LogCallback = Callable[[str], None]
MessageHandler = Callable[[Any, dict], bool]


def serve_hook_socket(
    *,
    socket_path: str,
    shutdown,
    handle_message: MessageHandler,
    log: LogCallback,
) -> None:
    """Accept hook events and dispatch parsed JSON messages.

    Unix/macOS/Linux use the original Unix-domain socket. Windows falls back
    to a loopback-only TCP listener on 127.0.0.1:8766.

    `handle_message` returns True when it takes ownership of the connection
    (permission/question hooks block on that connection until resolved).
    """
    use_unix_socket = hasattr(socket, "AF_UNIX")

    if use_unix_socket:
        os.makedirs(os.path.dirname(socket_path), exist_ok=True)
        try:
            os.unlink(socket_path)
        except FileNotFoundError:
            pass

        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(socket_path)
        log(f"[socket] listening on {socket_path}")
    else:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((hook_io.WINDOWS_HOOK_HOST, hook_io.WINDOWS_HOOK_PORT))
        log(
            f"[socket] listening on "
            f"{hook_io.WINDOWS_HOOK_HOST}:{hook_io.WINDOWS_HOOK_PORT}"
        )

    server.listen(32)
    server.settimeout(1.0)

    try:
        while not shutdown.is_set():
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue

            taken = False
            try:
                conn.settimeout(2.0)
                message = hook_io.read_json_message(conn, max_bytes=8192)
                if message is None:
                    continue
                taken = handle_message(conn, message)
            except Exception as e:
                log(f"[socket] error: {e}")
            finally:
                if not taken:
                    conn.close()
    finally:
        server.close()

        if use_unix_socket:
            try:
                os.unlink(socket_path)
            except FileNotFoundError:
                pass
