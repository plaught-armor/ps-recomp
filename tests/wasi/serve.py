"""Dev harness: serves the converter page or the play page (web/build.sh's
out dir) and disc files for the page's test mode, then waits for the
browser's result.

    python3 tests/wasi/serve.py <page dir> <result.json> <disc file>... [--host H] [--port P] [--arch A]
    python3 tests/wasi/serve.py <page dir> <result.json> --pick [--host H] [--port P] [--arch A]
    python3 tests/wasi/serve.py <page dir> <result.json> --play <module.wasm> [<disc file>...] [--env K=V]... [--no-input] [--seconds N] [--no-isolate]

Open the printed URL in any browser. The page converts the first disc file,
read by HTTP Range requests, posts the blob and its report, and the server
writes the report (plus its own sha256 of the blob) to <result.json>, the
blob beside it as <result>.bin, and exits. Only the named disc files are
served, under /disc/<name>.

With --pick the URL opens the page's pick mode instead: pick the disc in the
page as a user would (read through File.slice), press Convert, and the page
posts the same report. Every response carries the page's Content Security
Policy as a header, which also covers the Worker (the page's meta tag does
not).

With --play the URL opens play.html's test mode on <module.wasm> (a file in
the page dir: play.wasm, or the gate program tests/wasi/host built there),
on the disc files given (the module opens the .cue among them, else the
only one), with each --env variable in its environment. --no-input stops
the page's fake button and key presses, which change what the module does.
The page runs it until it exits or for --seconds, then posts each file the
module wrote, and ring.pcm (every sample it queued for the audio device),
to /file/<name>, which the server writes beside <result.json>, and then its
state ({isolated, frames, capture, audio, sabUpload, done, firstPresentMs,
files, log, errors, ...}), which the server writes to <result.json>.
Every response carries COOP, COEP and CORP, so the page is
cross-origin isolated by the headers; --no-isolate leaves them out, so the
page has to isolate itself through web/sw.js as on a static host.

The server takes a POST only from its own page (Sec-Fetch-Site same-origin,
or an Origin of this server), of at most 1 GiB.
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
parser.add_argument("discs", nargs="*")
parser.add_argument("--pick", action="store_true")
parser.add_argument("--host", default="127.0.0.1")
parser.add_argument("--port", type=int, default=8765)
parser.add_argument("--arch")
parser.add_argument("--play", metavar="MODULE")
parser.add_argument("--seconds", type=int)
parser.add_argument("--env", action="append", default=[], metavar="K=V")
parser.add_argument("--no-input", action="store_true")
parser.add_argument("--no-isolate", action="store_true")
args = parser.parse_args()
if not args.discs and not args.pick and not args.play:
    parser.error("give a disc file, --pick, or --play")
for kv in args.env:
    if kv.partition("=")[0] == "":
        parser.error(f"--env {kv}: not K=V")
discs = {os.path.basename(d): os.path.abspath(d) for d in args.discs}
blob = bytearray()
CSP = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'"
POST_MAX = 1 << 30  # the largest body a POST may carry


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=args.page, **k)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", CSP)
        if not args.no_isolate:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            self.send_header("Cross-Origin-Resource-Policy", "same-origin")
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

    # Whether a POST comes from the page itself: another site open in the
    # same browser must not write files here.
    def same_origin(self):
        if self.headers.get("Sec-Fetch-Site") == "same-origin":
            return True
        origins = {f"http://{h}:{args.port}" for h in (args.host, "127.0.0.1", "localhost")}
        return self.headers.get("Origin") in origins

    def do_POST(self):
        if not self.same_origin():
            self.send_error(403)
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
        except ValueError:
            n = -1
        if n < 0:
            self.send_error(400)
            return
        if n > POST_MAX:
            self.send_error(413)
            return
        data = self.rfile.read(n)
        path = urlsplit(self.path).path
        if path.startswith("/file/"):
            self.file(unquote(path[len("/file/"):]), data)
            return
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

    # A file the play page sends back, written beside the result file under
    # its name; a name that leaves that directory, or is not a file name, is
    # refused.
    def file(self, name, data):
        rel = os.path.normpath(name)
        if name == "" or "\0" in name or rel == "." or os.path.isabs(rel) or rel == ".." or rel.startswith(".." + os.sep):
            self.send_error(400)
            return
        to = os.path.join(os.path.dirname(os.path.abspath(args.result)), rel)
        try:
            os.makedirs(os.path.dirname(to), exist_ok=True)
            with open(to, "wb") as f:
                f.write(data)
        except (OSError, ValueError):
            self.send_error(400)
            return
        self.send_response(204)
        self.end_headers()
        print(f"file: {to} ({len(data)} bytes)", flush=True)


module = args.play or "recomp.wasm"
if not os.path.isfile(os.path.join(args.page, module)):
    sys.exit(f"{args.page}: no {module} (run web/build.sh)")
server = ThreadingHTTPServer((args.host, args.port), Handler)
page = "index.html"
if args.play:
    page = "play.html"
    query = "test=1&wasm=" + quote(args.play)
    for d in args.discs:
        query += "&disc=" + quote("disc/" + os.path.basename(d))
    for kv in args.env:
        query += "&env=" + quote(kv, safe="")
    if args.no_input:
        query += "&input=0"
    if args.seconds:
        query += f"&seconds={args.seconds}"
elif args.pick:
    query = "pick=1"
else:
    query = "test=" + quote("disc/" + os.path.basename(args.discs[0]))
if args.arch:
    query += "&arch=" + args.arch
host = "127.0.0.1" if args.host == "0.0.0.0" else args.host
print(f"http://{host}:{args.port}/{page}?{query}", flush=True)
server.serve_forever()
