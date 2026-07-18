"""Shared MCP stdio client for the live integration harnesses.

Replaces each harness's hand-rolled Popen wrapper with one that survives the real
failure modes: a server that dies mid-run (BrokenPipeError / stdout EOF), a server
that stalls (bounded reads with a monotonic deadline), and stray stdout traffic
(id-matched responses, notifications and non-JSON lines skipped). stderr is drained
continuously into a bounded ring so a chatty server can't block on a full pipe, and
its tail is attached to every failure for diagnosis.
"""
import json
import os
import selectors
import subprocess
import time

_STDERR_KEEP = 64 * 1024


class ServerDied(Exception):
    """The server process closed its pipes or exited mid-conversation."""


class RpcTimeout(Exception):
    """No matching response arrived before the deadline."""


class TestAbort(Exception):
    """A precondition the rest of a test section depends on was not met."""


def first(items, what):
    """items[0], or TestAbort naming what was expected — guards tool results that
    may be an error dict or an empty list rather than the expected match list."""
    if isinstance(items, list) and items:
        return items[0]
    raise TestAbort(f"expected at least one {what}, got {items!r}")


class MCPServer:
    def __init__(self, argv, timeout=30.0):
        self.p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, bufsize=0)
        self.timeout = timeout
        self._id = 0
        self._buf = b""
        self._stderr = b""
        self._sel = selectors.DefaultSelector()
        self._sel.register(self.p.stdout, selectors.EVENT_READ, "out")
        self._sel.register(self.p.stderr, selectors.EVENT_READ, "err")

    def stderr_tail(self):
        """Decoded tail of the server's stderr ring, for failure diagnostics."""
        return self._stderr.decode("utf-8", "replace")

    def _read_line(self, deadline):
        while True:
            newline_at = self._buf.find(b"\n")
            if newline_at >= 0:
                line, self._buf = self._buf[:newline_at], self._buf[newline_at + 1:]
                return line.decode("utf-8", "replace")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RpcTimeout(f"no response before deadline; stderr tail:\n{self.stderr_tail()}")
            for key, _ in self._sel.select(remaining):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if key.data == "err":
                    if chunk:
                        self._stderr = (self._stderr + chunk)[-_STDERR_KEEP:]
                    else:
                        # stderr EOF: the fd stays ready forever — unregister it or
                        # this loop spins until the deadline on every later read.
                        self._sel.unregister(key.fileobj)
                elif chunk:
                    self._buf += chunk
                else:
                    raise ServerDied(f"server closed stdout; stderr tail:\n{self.stderr_tail()}")

    def _response_for(self, request_id, timeout):
        deadline = time.monotonic() + timeout
        while True:
            line = self._read_line(deadline)
            if not line.strip():
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue  # stray non-JSON on stdout — skip, keep waiting
            if not isinstance(msg, dict) or "method" in msg or msg.get("id") != request_id:
                continue  # notification, server-initiated request, or stale reply
            return msg

    def _send(self, obj):
        try:
            self.p.stdin.write((json.dumps(obj) + "\n").encode("utf-8"))
            self.p.stdin.flush()
        except (BrokenPipeError, OSError) as e:
            raise ServerDied(f"stdin write failed ({e}); stderr tail:\n{self.stderr_tail()}") from e

    def rpc(self, method, params=None, timeout=None):
        """Send a request and return its id-matched response envelope."""
        self._id += 1
        req = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            req["params"] = params
        self._send(req)
        return self._response_for(self._id, self.timeout if timeout is None else timeout)

    def notify(self, method, params=None):
        """Send a notification (no id, no response expected)."""
        note = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            note["params"] = params
        self._send(note)

    def call(self, name, arguments, timeout=None):
        """tools/call helper: unwrap content[0].text, parsing JSON payloads."""
        resp = self.rpc("tools/call", {"name": name, "arguments": arguments}, timeout=timeout)
        if "error" in resp:
            raise TestAbort(f"tools/call {name}: JSON-RPC error {resp['error']}")
        try:
            text = resp["result"]["content"][0]["text"]
        except (KeyError, IndexError, TypeError):
            raise TestAbort(f"tools/call {name}: unexpected response shape {resp!r}")
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return {"_text": text}

    def _drain_pipes(self, budget=1.0):
        # Bounded, non-blocking drain: read whatever's already buffered on both pipes so a large
        # shutdown flush (>64 KiB) can't block the server on a full pipe while we wait for it to
        # exit. Never reads to EOF (that could block forever if the server doesn't exit) — it just
        # empties what's ready within `budget` seconds.
        import select
        fds = [p.fileno() for p in (self.p.stdout, self.p.stderr)]
        deadline = time.monotonic() + budget
        while fds:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            ready, _, _ = select.select(fds, [], [], remaining)
            if not ready:
                break
            for fd in ready:
                try:
                    if not os.read(fd, 65536):
                        fds.remove(fd)   # EOF on this pipe
                except OSError:
                    fds.remove(fd)

    def close(self):
        try:
            self.p.stdin.close()  # EOF lets a well-behaved server exit on its own
        except Exception:
            pass
        self._drain_pipes()
        try:
            self.p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.p.terminate()
            try:
                self.p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait()
        self._sel.close()
        for pipe in (self.p.stdout, self.p.stderr):
            try:
                pipe.close()
            except Exception:
                pass
