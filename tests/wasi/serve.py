"""Dev harness: serves the converter page or the play page (web/build.sh's
out dir) and disc files for the page's test mode, then waits for the
browser's result.

    python3 tests/wasi/serve.py <page dir> <result.json> <disc file>... [--host H] [--port P] [--arch A]
    python3 tests/wasi/serve.py <page dir> <result.json> --pick [--host H] [--port P] [--arch A]
    python3 tests/wasi/serve.py <page dir> <result.json> --play <module.wasm> [<disc file>...] [--env K=V]... [--no-input] [--store url] [--seconds N] [--no-isolate] [--net ROOM]

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
The page copies the disc files into the browser's storage (OPFS) and reads
them from there, as a picked disc is; --store url reads them by URL instead.
The page runs it until it exits or for --seconds, then posts each file the
module wrote, and ring.pcm (every sample it queued for the audio device),
to /file/<name>, which the server writes beside <result.json>, and then its
state ({isolated, frames, capture, audio, sabUpload, done, store, firstPresentMs,
files, log, errors, ...}), which the server writes to <result.json>.
Every response carries COOP, COEP and CORP, so the page is
cross-origin isolated by the headers; --no-isolate leaves them out, so the
page has to isolate itself through web/sw.js as on a static host.

With --net ROOM (and --play) it prints two URLs, players 1 and 2 of a
netplay session in that room (play.js ?net=ROOM&player=N): open one in each
of two pages. Each page posts its files under p<N>/ and its state to
<result>.p<N>.json, and the server exits once both have. The pages find
each other through /signal?room=R&peer=N: a POST queues a message (an SDP
offer or answer) for the other peer, a GET waits up to SIGNAL_WAIT s for
one of its own (204 when none came). It is for development only, not a
server to expose: it answers only loopback clients, from its own page.

The server takes a POST only from its own page (Sec-Fetch-Site same-origin,
or an Origin of this server), of at most 1 GiB (64 KiB on /signal).
"""

import argparse
import hashlib
import json
import os
import re
import sys
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlsplit

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
parser.add_argument("--store", choices=["url"])
parser.add_argument("--no-isolate", action="store_true")
parser.add_argument("--net", metavar="ROOM")
args = parser.parse_args()
if not args.discs and not args.pick and not args.play:
    parser.error("give a disc file, --pick, or --play")
if args.net is not None and (not args.play or not re.fullmatch(r"[\w-]{1,64}", args.net)):
    parser.error("--net takes a room name (letters, digits, - and _) and needs --play")
for kv in args.env:
    if kv.partition("=")[0] == "":
        parser.error(f"--env {kv}: not K=V")
discs = {os.path.basename(d): os.path.abspath(d) for d in args.discs}
blob = bytearray()
CSP = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'"
POST_MAX = 1 << 30  # the largest body a POST may carry
SIGNAL_MAX = 64 << 10  # the largest signal message
SIGNAL_WAIT = 20  # seconds a signal GET waits for a message
SIGNAL_QUEUE = 16  # messages waiting for one peer, at most
ROOMS_MAX = 8
signals = threading.Condition()
rooms = {}  # room -> {peer: [messages waiting for it]}
reported = set()  # with --net, the players whose state came


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
        if urlsplit(self.path).path == "/signal":
            self.signal(None)
        elif not self.disc(True):
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

    # /signal (see the top): data is a POST's body, None for a GET.
    def signal(self, data):
        if self.client_address[0] not in ("127.0.0.1", "::1", "::ffff:127.0.0.1") or not self.same_origin():
            self.send_error(403)
            return
        q = parse_qs(urlsplit(self.path).query)
        room, peer = q.get("room", [""])[0], q.get("peer", [""])[0]
        if not re.fullmatch(r"[\w-]{1,64}", room) or peer not in ("1", "2"):
            self.send_error(400)
            return
        if data is not None:
            try:
                json.loads(data)
            except ValueError:
                self.send_error(400)
                return
        with signals:
            if room not in rooms:
                if len(rooms) >= ROOMS_MAX:
                    self.send_error(503)
                    return
                rooms[room] = {"1": [], "2": []}
            box = rooms[room]
            if data is not None:
                other = "2" if peer == "1" else "1"
                if len(box[other]) >= SIGNAL_QUEUE:
                    self.send_error(503)
                    return
                box[other].append(data)
                signals.notify_all()
                msg = None
            else:
                signals.wait_for(lambda: box[peer], timeout=SIGNAL_WAIT)
                msg = box[peer].pop(0) if box[peer] else None
        if msg is None:
            self.send_response(204)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(msg)))
        self.end_headers()
        self.wfile.write(msg)

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
        path = urlsplit(self.path).path
        if n > (SIGNAL_MAX if path == "/signal" else POST_MAX):
            self.send_error(413)
            return
        data = self.rfile.read(n)
        if path == "/signal":
            self.signal(data)
            return
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
        result = args.result
        if args.net is not None:
            player = parse_qs(urlsplit(self.path).query).get("player", [""])[0]
            if player not in ("1", "2"):
                return
            stem, ext = os.path.splitext(args.result)
            result = f"{stem}.p{player}{ext}"
        with open(result, "w") as f:
            json.dump(report, f, indent=1)
        if blob:
            with open(os.path.splitext(args.result)[0] + ".bin", "wb") as f:
                f.write(blob)
        print(f"result: {result}", flush=True)
        if args.net is not None:
            reported.add(player)
            if len(reported) < 2:
                return
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
    if args.store:
        query += "&store=" + args.store
    if args.seconds:
        query += f"&seconds={args.seconds}"
elif args.pick:
    query = "pick=1"
else:
    query = "test=" + quote("disc/" + os.path.basename(args.discs[0]))
if args.arch:
    query += "&arch=" + args.arch
host = "127.0.0.1" if args.host == "0.0.0.0" else args.host
if args.net is None:
    print(f"http://{host}:{args.port}/{page}?{query}", flush=True)
else:
    for player in (1, 2):
        print(f"http://{host}:{args.port}/{page}?{query}&net={args.net}&player={player}", flush=True)
server.serve_forever()
