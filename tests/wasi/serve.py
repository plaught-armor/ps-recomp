"""Dev harness: serves the converter page (web/build.sh's out dir) and disc
files for the page's test mode, then waits for the browser's result.

    python3 tests/wasi/serve.py <page dir> <result.json> <disc file>... [--host H] [--port P] [--arch A]

Open the printed URL in any browser. The page converts the first disc file,
read by HTTP Range requests, posts the blob and its report, and the server
writes the report (plus its own sha256 of the blob) to <result.json>, the
blob beside it as <result>.bin, and exits. Only the named disc files are
served, under /disc/<name>.
"""

import argparse
import hashlib
import json
import os
import sys
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote, urlsplit

parser = argparse.ArgumentParser()
parser.add_argument("page")
parser.add_argument("result")
parser.add_argument("discs", nargs="+")
parser.add_argument("--host", default="127.0.0.1")
parser.add_argument("--port", type=int, default=8765)
parser.add_argument("--arch")
args = parser.parse_args()
discs = {os.path.basename(d): os.path.abspath(d) for d in args.discs}
blob = bytearray()


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=args.page, **k)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def disc(self, body):
        path = unquote(urlsplit(self.path).path)
        if not path.startswith("/disc/"):
            return False
        name = path[len("/disc/"):]
        if name not in discs:
            self.send_error(404)
            return True
        size = os.path.getsize(discs[name])
        start, end = 0, size - 1
        r = self.headers.get("Range")
        if r:
            a, _, b = r.removeprefix("bytes=").partition("-")
            start, end = int(a), min(int(b) if b else size - 1, size - 1)
            if start > end:
                self.send_error(416)
                return True
        self.send_response(206 if r else 200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(end - start + 1))
        if r:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if body:
            with open(discs[name], "rb") as f:
                f.seek(start)
                left = end - start + 1
                while left > 0:
                    chunk = f.read(min(left, 1 << 20))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        return True

    def do_GET(self):
        if not self.disc(True):
            super().do_GET()

    def do_HEAD(self):
        if not self.disc(False):
            super().do_HEAD()

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        path = urlsplit(self.path).path
        if path not in ("/blob", "/result"):
            self.send_error(404)
            return
        self.send_response(204)
        self.end_headers()
        if path == "/blob":
            blob[:] = data
            return
        report = json.loads(data)
        report["server_sha256"] = hashlib.sha256(blob).hexdigest() if blob else None
        report["server_size"] = len(blob)
        with open(args.result, "w") as f:
            json.dump(report, f, indent=1)
        if blob:
            with open(os.path.splitext(args.result)[0] + ".bin", "wb") as f:
                f.write(blob)
        print(f"result: {args.result}", flush=True)
        threading.Thread(target=self.server.shutdown).start()


if not os.path.isfile(os.path.join(args.page, "recomp.wasm")):
    sys.exit(f"{args.page}: no recomp.wasm (run web/build.sh)")
server = ThreadingHTTPServer((args.host, args.port), Handler)
query = "test=" + quote("disc/" + os.path.basename(args.discs[0]))
if args.arch:
    query += "&arch=" + args.arch
host = "127.0.0.1" if args.host == "0.0.0.0" else args.host
print(f"http://{host}:{args.port}/index.html?{query}", flush=True)
server.serve_forever()
