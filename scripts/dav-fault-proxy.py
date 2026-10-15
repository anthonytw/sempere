#!/usr/bin/env python3
"""A fault-injecting HTTP proxy for the WebDAV sync stress tests (docs/ci.md "Sync stress").

    scripts/dav-fault-proxy.py --listen 127.0.0.1:8766 --upstream http://127.0.0.1:8765 [--seed N]

Forwards every request to the upstream server (wsgidav in scripts/sync-stress.sh) and can, per test:
add latency, cap bandwidth, reset the connection in the middle of a request or response body, answer
5xx at random or by rule, stall, or drip a response; it counts every request. Standard library only.

Control (never forwarded), JSON in and out:
    GET  /__proxy__/stats    {"total", "byMethod", "faults", "requests": [[method, path, status, fault, range], ...]}
                             (status -1: reset before an answer, -2: stalled; range: the Range header or null)
    POST /__proxy__/config   replaces the configuration (below); keeps the counters
    POST /__proxy__/reset    clears the counters and the configuration
Configuration:
    {"latencyMs": 0, "bytesPerSecond": 0,           # 0 = unlimited; both directions
     "errorRate": 0.0, "errorStatus": 503, "seed": 1, # random 5xx on any request
     "rules": [{"method": "GET", "path": "/att/",   # method ("*" = any) and a regex searched in the path
                "action": "reset" | "status" | "stall" | "drip" | "delay",
                "direction": "response" | "request",  # reset: cut the response body, or the request body
                "afterBytes": 0, "status": 503, "delayMs": 0, "bytesPerSecond": 64, "stallSeconds": 600,
                "skip": 0, "times": 1, "probability": 1.0}]}
A rule applies to its matching requests after the first `skip`, `times` times (-1: always), each with
`probability` (the seeded generator). The first rule that fires wins; one that does not fire counts
nothing. A reset closes the client's socket with SO_LINGER 0 (a TCP RST), as a dropped link would.
"""

import argparse
import http.client
import json
import random
import re
import socket
import struct
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOP = {"connection", "keep-alive", "proxy-connection", "transfer-encoding", "te", "trailer", "upgrade"}


class State:
    def __init__(self, seed):
        self.lock = threading.Lock()
        self.reset(seed)

    def reset(self, seed=1):
        with self.lock:
            self.config = {"seed": seed}
            self.rules = []
            self.rng = random.Random(seed)
            self.total = 0
            self.by_method = {}
            self.faults = 0
            self.requests = []

    def configure(self, config):
        with self.lock:
            self.config = config
            self.rng = random.Random(config.get("seed", 1))
            self.rules = []
            for r in config.get("rules", []):
                rule = dict(r)
                rule["_re"] = re.compile(r.get("path", ""))
                rule["_seen"] = 0
                rule["_left"] = r.get("times", 1)
                self.rules.append(rule)

    def count(self, method, path, range_header):
        """Counts a request; returns (fault rule or None, its index in the request log)."""
        with self.lock:
            self.total += 1
            self.by_method[method] = self.by_method.get(method, 0) + 1
            self.requests.append([method, path, 0, None, range_header])
            index = len(self.requests) - 1
            rate = self.config.get("errorRate", 0.0)
            if rate and self.rng.random() < rate:
                self.faults += 1
                self.requests[index][3] = "random-status"
                return {"action": "status", "status": self.config.get("errorStatus", 503)}, index
            for rule in self.rules:
                if rule.get("method", "*") not in ("*", method) or not rule["_re"].search(path):
                    continue
                rule["_seen"] += 1
                if rule["_seen"] <= rule.get("skip", 0) or rule["_left"] == 0:
                    continue
                if self.rng.random() >= rule.get("probability", 1.0):
                    continue
                if rule["_left"] > 0:
                    rule["_left"] -= 1
                self.faults += 1
                self.requests[index][3] = rule.get("action")
                return rule, index
            return None, index

    def finish(self, index, status):
        with self.lock:
            self.requests[index][2] = status

    def stats(self):
        with self.lock:
            return {"total": self.total, "byMethod": dict(self.by_method), "faults": self.faults,
                    "requests": [list(r) for r in self.requests]}


class Throttle:
    """Sleeps so that the bytes passed through stay under `rate` per second (0: no limit)."""

    def __init__(self, rate):
        self.rate = rate
        self.start = time.monotonic()
        self.sent = 0

    def passed(self, n):
        if not self.rate:
            return
        self.sent += n
        ahead = self.sent / self.rate - (time.monotonic() - self.start)
        if ahead > 0:
            time.sleep(ahead)


def make_handler(state, upstream):
    up = urllib.parse.urlsplit(upstream)
    # One kept-alive upstream connection per handler thread: a new one per request runs a busy test
    # out of ephemeral ports (TIME_WAIT), and then nothing connects at all.
    local = threading.local()

    def upstream_request(method, path, body, headers):
        for attempt in (0, 1):
            conn = getattr(local, "conn", None)
            if conn is None:
                conn = local.conn = http.client.HTTPConnection(up.hostname, up.port, timeout=600)
            try:
                conn.request(method, path, body=body, headers=headers)
                return conn, conn.getresponse()
            except (http.client.HTTPException, OSError):
                conn.close()
                local.conn = None
                if attempt:
                    raise

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # quiet
            pass

        def rst(self):
            """Drops the connection with a TCP RST."""
            try:
                self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            except OSError:
                pass
            self.close_connection = True
            try:
                self.connection.close()
            except OSError:
                pass

        def read_body(self, limit=None, throttle=None):
            """The request body (Content-Length or chunked); stops after `limit` bytes when given."""
            out = bytearray()
            te = self.headers.get("Transfer-Encoding", "").lower()
            if "chunked" in te:
                while True:
                    line = self.rfile.readline(1 << 16)
                    if not line:
                        break
                    size = int(line.split(b";")[0].strip() or b"0", 16)
                    if size == 0:
                        while self.rfile.readline(1 << 16) not in (b"\r\n", b"\n", b""):
                            pass
                        break
                    left = size
                    while left:
                        want = min(left, 1 << 16)
                        if limit is not None:
                            want = min(want, limit - len(out))
                            if want <= 0:
                                return bytes(out), True
                        chunk = self.rfile.read(want)
                        if not chunk:
                            return bytes(out), True
                        out += chunk
                        left -= len(chunk)
                        if throttle:
                            throttle.passed(len(chunk))
                    self.rfile.readline(8)
                return bytes(out), False
            length = int(self.headers.get("Content-Length", "0") or "0")
            while len(out) < length:
                want = min(length - len(out), 1 << 16)
                if limit is not None:
                    want = min(want, limit - len(out))
                    if want <= 0:
                        return bytes(out), True
                chunk = self.rfile.read(want)
                if not chunk:
                    return bytes(out), True
                out += chunk
                if throttle:
                    throttle.passed(len(chunk))
            return bytes(out), False

        def reply(self, status, body=b"", ctype="text/plain"):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def control(self):
            path = urllib.parse.urlsplit(self.path).path
            body, _ = self.read_body()
            if path == "/__proxy__/stats":
                return self.reply(200, json.dumps(state.stats()).encode(), "application/json")
            if path == "/__proxy__/reset" and self.command == "POST":
                state.reset(json.loads(body or b"{}").get("seed", 1))
                return self.reply(204)
            if path == "/__proxy__/config" and self.command == "POST":
                try:
                    state.configure(json.loads(body or b"{}"))
                except (ValueError, re.error) as e:
                    return self.reply(400, str(e).encode())
                return self.reply(204)
            return self.reply(404)

        def handle_one_request(self):
            try:
                super().handle_one_request()
            except (ConnectionError, BrokenPipeError, socket.timeout, OSError):
                self.close_connection = True

        def proxy(self):
            path = urllib.parse.urlsplit(self.path).path
            if path.startswith("/__proxy__/"):
                return self.control()
            rule, index = state.count(self.command, urllib.parse.unquote(path), self.headers.get("Range"))
            config = state.config
            latency = config.get("latencyMs", 0)
            if latency:
                time.sleep(latency / 1000)
            rate = config.get("bytesPerSecond", 0)
            action = rule.get("action") if rule else None
            direction = rule.get("direction", "response") if rule else None
            if action == "delay":
                time.sleep(rule.get("delayMs", 0) / 1000)

            if action == "reset" and direction == "request":
                self.read_body(limit=rule.get("afterBytes", 0), throttle=Throttle(rate))
                state.finish(index, -1)
                return self.rst()
            body, _ = self.read_body(throttle=Throttle(rate))
            if action == "status":
                state.finish(index, rule.get("status", 503))
                self.close_connection = True
                self.send_response(rule.get("status", 503))
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
                return
            if action == "stall":
                deadline = time.monotonic() + rule.get("stallSeconds", 600)
                self.connection.settimeout(0.2)
                while time.monotonic() < deadline:
                    try:
                        if self.connection.recv(1, socket.MSG_PEEK) == b"":
                            break  # the client gave up
                    except socket.timeout:
                        continue
                    except OSError:
                        break
                state.finish(index, -2)
                return self.rst()

            headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
            if body or self.command in ("PUT", "POST", "PROPFIND", "PROPPATCH", "LOCK"):
                headers["Content-Length"] = str(len(body))
            try:
                conn, resp = upstream_request(self.command, self.path, body, headers)
            except (http.client.HTTPException, OSError) as e:
                state.finish(index, 502)
                return self.reply(502, str(e).encode())
            state.finish(index, resp.status)
            self.send_response_only(resp.status, resp.reason)
            length = resp.getheader("Content-Length")
            no_body = self.command == "HEAD" or resp.status in (204, 304) or 100 <= resp.status < 200
            data = None
            if length is None and not no_body:
                data = resp.read()
                length = str(len(data))
            for k, v in resp.getheaders():
                if k.lower() not in HOP and k.lower() != "content-length":
                    self.send_header(k, v)
            if not no_body:
                self.send_header("Content-Length", length)
            self.end_headers()
            if no_body:
                return
            cut = rule.get("afterBytes", 0) if action == "reset" else None
            drip = rule.get("bytesPerSecond", 64) if action == "drip" else rate
            throttle = Throttle(drip)
            sent = 0
            while True:
                chunk = data if data is not None else resp.read(1 << 14)
                if data is not None:
                    data = b""
                if not chunk:
                    break
                if action == "drip":
                    for i in range(0, len(chunk), 16):
                        self.wfile.write(chunk[i:i + 16])
                        self.wfile.flush()
                        throttle.passed(len(chunk[i:i + 16]))
                    sent += len(chunk)
                    continue
                if cut is not None and sent + len(chunk) >= cut:
                    self.wfile.write(chunk[: max(cut - sent, 0)])
                    self.wfile.flush()
                    conn.close()
                    local.conn = None
                    return self.rst()
                self.wfile.write(chunk)
                sent += len(chunk)
                throttle.passed(len(chunk))
            self.wfile.flush()

        do_GET = do_PUT = do_POST = do_DELETE = do_HEAD = do_OPTIONS = proxy
        do_PROPFIND = do_PROPPATCH = do_MKCOL = do_MOVE = do_COPY = do_LOCK = do_UNLOCK = proxy

    return Handler


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--listen", default="127.0.0.1:8766")
    p.add_argument("--upstream", required=True)
    p.add_argument("--seed", type=int, default=1)
    a = p.parse_args()
    host, port = a.listen.rsplit(":", 1)
    state = State(a.seed)
    class Server(ThreadingHTTPServer):
        daemon_threads = True
        request_queue_size = 128  # read by listen() in the constructor

    server = Server((host, int(port)), make_handler(state, a.upstream))
    print(f"fault proxy on http://{host}:{server.server_address[1]}/ -> {a.upstream}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
