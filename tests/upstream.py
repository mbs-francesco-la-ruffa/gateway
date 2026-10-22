# The app behind the gateway in tests/check.sh: answers with what it received, so the check
# can see which upstream a host reached and which headers arrived. NAME says which upstream it is.
import json
import os
import socket
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NAME = os.environ.get("NAME", "?")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Upstream", NAME)
        self.send_header("Set-Cookie", "upstream=1")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/sse":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            for i in range(3):
                self.wfile.write(f"data: {i}\n\n".encode())
                self.wfile.flush()
                time.sleep(1.5)
            self.close_connection = True
            return
        if self.path == "/stream":
            # A plain streamed body, the way a chatbot answers: no Content-Length and no event-stream type.
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Connection", "close")
            self.end_headers()
            for i in range(3):
                self.wfile.write(f"piece {i}\n".encode())
                self.wfile.flush()
                time.sleep(1.5)
            self.close_connection = True
            return
        if self.path == "/ws":
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
            self.end_headers()
            self.wfile.write(b"ws-data\n")
            self.wfile.flush()
            self.close_connection = True
            return
        if self.path == "/fail503":
            return self._json(503, {"upstream": NAME, "error": "503 from the app"})
        self._json(200, {
            "upstream": NAME,
            "path": self.path,
            "host": self.headers.get("Host"),
            "xfp": self.headers.get("X-Forwarded-Proto"),
            "xff": self.headers.get("X-Forwarded-For"),
        })

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        read = 0
        while read < length:
            chunk = self.rfile.read(min(1 << 20, length - read))
            if not chunk:
                break
            read += len(chunk)
        self._json(200, {"upstream": NAME, "path": self.path, "received": read})


class Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6


Server(("::", 8080), Handler).serve_forever()
