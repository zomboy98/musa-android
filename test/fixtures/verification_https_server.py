"""Synthetic HTTPS navigation fixture. Never use real provider URLs or grants.

Run two listeners (9443 origin, 9444 foreign origin) with a certificate trusted
by the disposable test device. Does not disable TLS or modify device trust.
"""
import argparse
import html
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

STATE = "musa-fixture-state"
GRANT = "synthetic-invalid-grant"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Do not print request targets, queries, headers or bodies.

    def page(self, content, status=200):
        body = ("<!doctype html><meta name=viewport content='width=device-width'>"
                "<title>MUSA synthetic fixture</title>" + content).encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/foreign":
            self.page("<h1>FOREIGN ORIGIN REACHED</h1>")
            return
        if path in ("/redirect307", "/redirect308"):
            self.send_response(int(path[-3:]))
            self.send_header("Location", self.server.foreign_origin + "/foreign")
            self.end_headers()
            return
        if path == "/timeout":
            self.page("<h1>Wait for app timeout</h1><p>No callback is sent.</p>")
            return
        if path == "/forbidden":
            self.page("<h1>Synthetic 403 content remains visible</h1>", 403)
            return
        callback = "mornye://musa-session-grant?state={}&grant=" + GRANT
        links = "".join(
            f"<p><a href='{html.escape(callback.format(state), quote=True)}'>{label}</a></p>"
            for state, label in [(STATE, "Matching synthetic state (backend must reject grant)"),
                                 ("foreign-fixture-state", "Foreign state: panel must stay open")]
        )
        self.page("<h1>MUSA synthetic verification</h1><p>No CAPTCHA, no real session.</p>" + links +
                  "<p><a href='/redirect307'>GET redirect 307 to foreign origin</a></p>"
                  "<p><a href='/redirect308'>GET redirect 308 to foreign origin</a></p>"
                  "<p><a href='/forbidden'>Renderable HTTP 403</a></p>"
                  "<p><a href='/timeout'>Timeout without callback</a></p>" +
                  f"<form method=post action='{self.server.foreign_origin}/foreign'>"
                  "<input name=fixture value=synthetic><button>Direct foreign POST</button></form>" +
                  "".join(f"<form method=post action='/redirect{code}'><input name=fixture value=synthetic>"
                          f"<button>POST redirect {code}</button></form>" for code in (307, 308)))

    def do_POST(self):
        self.rfile.read(min(int(self.headers.get("Content-Length", "0")), 4096))
        # Count only synthetic arrivals, without preserving any request data.
        self.server.post_count += 1
        if urlsplit(self.path).path in ("/redirect307", "/redirect308"):
            self.do_GET()
        else:
            self.page("<h1>FOREIGN POST REACHED</h1>")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--host", default="localhost", help="Certificate hostname")
    args = parser.parse_args()
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(args.cert, args.key)
    servers = []
    for port in (9443, 9444):
        server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        server.socket = tls.wrap_socket(server.socket, server_side=True)
        server.foreign_origin = f"https://{args.host}:9444"
        server.post_count = 0
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    print("Synthetic HTTPS fixture ready on loopback ports 9443 and 9444; no request logs.")
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        for server in servers:
            server.shutdown()
        print("POST arrival counts (origin, foreign):", *(s.post_count for s in servers))


if __name__ == "__main__":
    main()
