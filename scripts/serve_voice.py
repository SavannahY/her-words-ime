#!/usr/bin/env python3
"""Serve the local voice page and current language packs on 127.0.0.1 only."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import mimetypes
from pathlib import Path
import sys
from urllib.parse import urlsplit

try:
    from .compile_web_rules import build_payload, render_payload
    from .validate_packs import DEFAULT_MANIFEST, ValidationError
except ImportError:
    from compile_web_rules import build_payload, render_payload
    from validate_packs import DEFAULT_MANIFEST, ValidationError


WEB = Path(__file__).resolve().parents[1] / "web"
ASSETS = {"/": "index.html", "/index.html": "index.html",
          "/style.css": "style.css", "/app.mjs": "app.mjs",
          "/voice.mjs": "voice.mjs", "/rewrite.mjs": "rewrite.mjs"}


def make_handler(payload, directory=WEB):
    encoded_rules = render_payload(payload).encode("utf-8")

    class Handler(BaseHTTPRequestHandler):
        # No request log, form endpoint, telemetry, audio endpoint or input store.
        def log_message(self, *_args):
            pass

        def do_GET(self):
            self._serve(False)

        def do_HEAD(self):
            self._serve(True)

        def _serve(self, head):
            port = self.server.server_port
            if self.headers.get("Host") not in {"127.0.0.1:" + str(port), "localhost:" + str(port)}:
                self.send_error(403, "Local host required")
                return
            path = urlsplit(self.path).path
            if path == "/rules.json":
                content, mime = encoded_rules, "application/json"
            elif path in ASSETS:
                content = (directory / ASSETS[path]).read_bytes()
                mime = "text/javascript" if path.endswith(".mjs") else mimetypes.guess_type(ASSETS[path])[0]
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", (mime or "application/octet-stream") + "; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")
            self.end_headers()
            if not head:
                self.wfile.write(content)

        def do_POST(self):
            # Reject without reading or retaining the submitted body.
            self.close_connection = True
            self.send_error(405, "Read-only local service")

        do_PUT = do_POST
        do_PATCH = do_POST
        do_DELETE = do_POST

    return Handler


def create_server(port=8765, manifest=DEFAULT_MANIFEST):
    # Intentionally no --host option: never expose this tool to a network.
    return ThreadingHTTPServer(("127.0.0.1", port), make_handler(build_payload(manifest)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    args = parser.parse_args()
    try:
        server = create_server(args.port, args.manifest)
    except (ValidationError, OSError, ValueError) as error:
        print("Could not start local voice tool: " + str(error), file=sys.stderr)
        return 1
    print("她说 · 本地语音书写：http://127.0.0.1:{}".format(server.server_port), flush=True)
    print("浏览器可能把音频发送到其识别服务。本工具不接收音频或文字。Ctrl+C 停止。", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
