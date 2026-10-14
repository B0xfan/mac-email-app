#!/usr/bin/env python3
"""Self-check with a pretend key check and made-up emails. Run: python3 -I test_server.py   (no network)"""
import json, os, sys, tempfile, threading, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

auth = {"up": True, "key": "goodkey"}
class A(BaseHTTPRequestHandler):   # pretend mail-timing: accepts one key
    def log_message(self, *a): pass
    def do_GET(self):
        ok = self.headers.get("Authorization") == "Bearer " + auth["key"]
        code = 500 if not auth["up"] else 200 if ok else 401
        self.send_response(code); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")
asv = ThreadingHTTPServer(("127.0.0.1", 0), A); threading.Thread(target=asv.serve_forever, daemon=True).start()
DB = tempfile.mkdtemp() + "/t.db"
os.environ.update(AUTH_URL=f"http://127.0.0.1:{asv.server_port}/jobs", DB_PATH=DB, PUBLIC_BASE="https://x.example")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import server
ms = ThreadingHTTPServer(("127.0.0.1", 0), server.H); threading.Thread(target=ms.serve_forever, daemon=True).start()
B = f"http://127.0.0.1:{ms.server_port}"

def req(method, path, body=None, key="goodkey", raw=None):
    h = {"Authorization": "Bearer " + key} if key else {}
    r = urllib.request.Request(B + path, raw if raw is not None else json.dumps(body).encode() if body is not None else None, method=method, headers=h)
    try:
        with urllib.request.urlopen(r) as x: return x.status, x.read(), x.headers
    except urllib.error.HTTPError as e: return e.code, e.read(), e.headers
fails = 0
def check(name, ok):
    global fails; fails += (not ok); print(("PASS " if ok else "FAIL ") + name)

M = {"subject": "Venue walkthrough on Thursday", "from": "Priya Raman <priya@example.com>", "to": "John Hesch <john@example.com>", "date": "Today, 8:38 AM", "body": "Can you make it at 10?\nI will bring the floor plan."}
L = "/api/mail-share/links"
check("no key refused", req("POST", L, M, key=None)[0] == 401)
check("wrong key refused", req("POST", L, M, key="bad")[0] == 401)
s, b, _ = req("POST", L, M); j = json.loads(b); tok = j.get("token", "")
check("upload gives a 32-character token and a url", s == 200 and len(tok) == 32 and j["url"] == "https://x.example/e/" + tok)
check("expiry is 30 days", abs(j["expires_at"] - time.time() - 30 * 86400) < 5)
s, b, h = req("GET", "/e/" + tok, key=None); t = b.decode()
check("page opens with no key and shows the email", s == 200 and "Venue walkthrough on Thursday" in t and "Priya Raman" in t and "I will bring the floor plan." in t and "John Hesch shared this email with you" in t)
check("noindex / no-referrer / no-framing / CSP headers", "noindex" in h["X-Robots-Tag"] and h["Referrer-Policy"] == "no-referrer" and "frame-ancestors 'none'" in h["Content-Security-Policy"] and "default-src 'none'" in h["Content-Security-Policy"] and h["X-Frame-Options"] == "DENY")
check("no script, no remote content on the page", "<script" not in t and "http" not in t.replace("</html>", ""))
evil = dict(M, subject="<script>alert(1)</script>", body='<img src=x onerror=alert(1)> <a href="javascript:x">hi</a>‮gnp.exe', **{"from": '"><svg onload=1>'})
s, b, _ = req("POST", L, evil); et = json.loads(b)["token"]; t = req("GET", "/e/" + et, key=None)[1].decode()
check("hostile HTML is escaped, direction trick removed", "<script>alert" not in t and "<img" not in t and "<svg" not in t and "&lt;script&gt;" in t and "&lt;img" in t and "‮" not in t)
check("bad / unknown token gives the short page", all(req("GET", p, key=None)[0] == 404 and b"ended" in req("GET", p, key=None)[1] for p in ("/e/" + "A" * 32, "/e/short", "/e/")))
check("bad field type / missing field refused", req("POST", L, dict(M, body=5))[0] == 400 and req("POST", L, {"subject": "x"})[0] == 400 and req("POST", L, raw=b"nope")[0] == 400)
check("too-long body refused (413)", req("POST", L, dict(M, body="x" * 150001))[0] == 413)
import http.client
hc = http.client.HTTPConnection("127.0.0.1", ms.server_port); hc.putrequest("POST", L); hc.putheader("Authorization", "Bearer goodkey"); hc.putheader("Content-Length", "800000"); hc.endheaders()
check("oversize request (over 700 KB) refused (413) before the body is read", hc.getresponse().status == 413); hc.close()
auth["up"] = False
check("key check down -> 503, not open", req("POST", L, M)[0] == 503); auth["up"] = True
s, b, _ = req("DELETE", "/api/mail-share/links/" + tok); check("delete works", s == 200 and json.loads(b)["status"] == "deleted" and req("GET", "/e/" + tok, key=None)[0] == 404)
check("delete again is harmless; needs key", json.loads(req("DELETE", "/api/mail-share/links/" + tok)[1])["status"] == "none" and req("DELETE", "/api/mail-share/links/" + et, key=None)[0] == 401)
secret = "ZXQ-unique-body-marker"
s, b, _ = req("POST", L, dict(M, body=secret)); xt = json.loads(b)["token"]
check("email is on disk before expiry", secret.encode() in open(DB, "rb").read())
real = time.time; time.time = lambda: real() + 30 * 86400 + 5
check("expired link shows the short page even before the sweep", req("GET", "/e/" + xt, key=None)[0] == 404)
server.purge()
time.time = real
check("purge removes expired email text from the disk file", secret.encode() not in open(DB, "rb").read())
check("non-English body near the character limit accepted (bytes over the old 256 KB cap)", req("POST", L, raw=json.dumps(dict(M, body="\u4f60\U0001F600" * 74900), ensure_ascii=False).encode())[0] == 200)   # 149,800 characters, about 525 KB as UTF-8
s, b, _ = req("POST", L, raw=json.dumps(M).replace("Venue", "\\ud800").encode())
check("lone surrogate -> clean 400 'not valid text'", s == 400 and json.loads(b) == {"error": "subject is not valid text"})
s, b, _ = req("POST", L, dict(M, subject="a\u200bb\u200cc\u200dd\u2060e\ufefff\u00adg\u0085h\u009bi")); t = req("GET", "/e/" + json.loads(b)["token"], key=None)[1].decode()
check("zero-width, soft hyphen and C1 controls removed", "<h1>abcdefghi</h1>" in t)
big = "QJV-journal-marker-" + "y" * 100000
s, b, _ = req("POST", L, dict(M, body=big)); bt = json.loads(b)["token"]
check("100 KB email on disk before delete", s == 200 and big[:40].encode() in open(DB, "rb").read())
req("DELETE", "/api/mail-share/links/" + bt)
jr = open(DB + "-journal", "rb").read() if os.path.exists(DB + "-journal") else b""
check("after delete: text gone from db file and journal", b"QJV-journal-marker" not in open(DB, "rb").read() and b"QJV-journal-marker" not in jr)
auth["key"] = "newkey"
check("replaced key refused at once (no cache)", req("POST", L, M)[0] == 401 and req("POST", L, M, key="newkey")[0] == 200)
auth["key"] = "goodkey"
server.MAX_LINKS = 1
check("link cap -> 429", req("POST", L, M)[0] in (200, 429) and req("POST", L, M)[0] == 429)
print("FAILS:", fails); sys.exit(1 if fails else 0)
