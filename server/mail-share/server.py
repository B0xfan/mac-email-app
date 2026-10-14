#!/usr/bin/env python3
"""Audrey Mail share-link service. Stores ONE email as plain text per link and serves it as a read-only web page.
Email content is untrusted: it is stored as text, stripped of control/direction characters and HTML-escaped on output.
Links expire after 30 days and are then deleted from disk. The Mac authenticates with the same key it got from the
mail-timing service (checked by asking that service, on loopback). Python standard library only."""
import base64, hashlib, html, json, os, re, secrets, sqlite3, threading, time, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

E = os.environ.get
API = "/api/mail-share"
TOK_RE = re.compile(r"^[A-Za-z0-9_-]{32}$")
TTL = lambda: int(E("LINK_SECONDS", str(30 * 86400)))
MAX_LINKS, MAX_REQ = 500, 716800   # 700 KB: 150k characters of non-English text can need 3-4 bytes each
LIMITS = {"subject": 300, "from": 500, "to": 1000, "date": 100, "body": 150000}
BAD = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\xad\u200b-\u200f\u061c\u202a-\u202e\u2060\u2066-\u2069\u2028\u2029\ufeff]")   # controls (C0, C1), zero-width, soft hyphen, text-direction tricks

CSS = ("body{margin:0;padding:24px 16px;font:15px/1.45 -apple-system,system-ui,sans-serif;background:#f2f6f6;color:#0f2326}"
       "main{max-width:760px;margin:0 auto;background:#fff;border:1px solid #cfdcdc;border-radius:12px;padding:14px 18px}"
       ".ban{background:#a9d4d6;border-radius:9px;padding:6px 12px;font-size:13px;margin:0 0 12px}"
       "h1{font-size:20px;margin:0}.meta{color:#4a6063;font-size:13px;margin:4px 0 12px;overflow-wrap:anywhere}"
       ".body{white-space:pre-wrap;overflow-wrap:anywhere;font-size:14px}.end{color:#4a6063;font-size:12px;margin-top:16px}"
       "@media(prefers-color-scheme:dark){body{background:#0b1517;color:#eaf4f4}main{background:#17292c;border-color:#2a4044}"
       ".ban{background:#2f6b72}.meta,.end{color:#9db3b6}}")
CSP = "default-src 'none'; style-src 'sha256-%s'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" % base64.b64encode(hashlib.sha256(CSS.encode()).digest()).decode()
HEAD = f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow,noarchive"><title>%s</title><style>{CSS}</style></head><body><main>'

def db():
    c = sqlite3.connect(E("DB_PATH", "data/share.db"), timeout=10)
    c.execute("PRAGMA secure_delete=ON")   # deleted emails are overwritten on disk, not just unlinked
    c.execute("PRAGMA journal_mode=TRUNCATE")   # rollback journal emptied after each write, so deleted text does not linger there
    c.execute("CREATE TABLE IF NOT EXISTS links(tok_hash TEXT PRIMARY KEY, subject TEXT, sender TEXT, recipients TEXT, date TEXT, body TEXT, expires INTEGER)")
    return c

def purge(now=None):
    c = db()
    try:
        with c: c.execute("DELETE FROM links WHERE expires <= ?", (int(now or time.time()),))
    finally: c.close()

def worker():
    while True:
        try: purge()
        except Exception as e: print("purge error:", type(e).__name__, flush=True)
        time.sleep(60)

def page(status_title, inner): return (HEAD % html.escape(status_title) + inner + "</main></body></html>").encode()
def th(t): return hashlib.sha256(t.encode()).hexdigest()

class Unavailable(Exception): pass

class H(BaseHTTPRequestHandler):
    timeout = 30   # a stalled client cannot hold a thread forever
    def log_message(self, *a): pass
    def send(self, code, body, ctype, extra=()):
        self.send_response(code)
        for k, v in (("Content-Type", ctype), ("Content-Length", str(len(body))), ("X-Robots-Tag", "noindex, nofollow, noarchive"), ("Referrer-Policy", "no-referrer"),
                     ("Content-Security-Policy", CSP), ("X-Content-Type-Options", "nosniff"), ("X-Frame-Options", "DENY"), ("Cache-Control", "no-store")) + tuple(extra):
            self.send_header(k, v)
        self.end_headers(); self.wfile.write(body)
    def out(self, code, obj): self.send(code, json.dumps(obj).encode(), "application/json")
    def html(self, code, title, inner): self.send(code, page(title, inner), "text/html; charset=utf-8")
    def gone(self): self.html(404, "Link ended", "<h1>This link has ended</h1><p class=meta>Shared links work for 30 days, or until the sender turns them off.</p>")
    def authed(self):
        a = self.headers.get("Authorization") or ""
        k = a[7:] if a.startswith("Bearer ") else ""
        if not k or len(k) > 200: return False
        try:   # asked every time, so a replaced key stops working at once
            urllib.request.urlopen(urllib.request.Request(E("AUTH_URL", "http://127.0.0.1:8093/api/mail-timing/jobs"), headers={"Authorization": "Bearer " + k}), timeout=5).close()
        except urllib.error.HTTPError as e:
            if e.code == 401: return False
            raise Unavailable()
        except (urllib.error.URLError, OSError): raise Unavailable()
        return True
    def do_GET(self):
        try:
            path = self.path.split("?")[0]
            m = re.fullmatch(r"/e/([A-Za-z0-9_-]{32})", path)
            if not m: return self.gone() if path.startswith("/e/") else self.out(404, {})
            c = db()
            try: r = c.execute("SELECT subject,sender,recipients,date,body,expires FROM links WHERE tok_hash=? AND expires>?", (th(m[1]), int(time.time()))).fetchone()
            finally: c.close()
            if not r: return self.gone()
            e = html.escape
            until = time.strftime("%B %d, %Y", time.gmtime(r[5])).replace(" 0", " ")
            self.html(200, r[0] or "Shared email",
                f'<div class=ban>{e(E("SHARER", "John Hesch"))} shared this email with you. You can read it here. You cannot reply from this page.</div>'
                f'<h1>{e(r[0])}</h1><div class=meta>From {e(r[1])} &middot; To {e(r[2])} &middot; {e(r[3])}</div><div class=body>{e(r[4])}</div>'
                f'<div class=end>This link works until {until}. Text only: no attachments or pictures.</div>')
        except Exception as ex:
            print("request error:", type(ex).__name__, flush=True); self.out(500, {})
    def do_POST(self):
        try:
            if self.path.split("?")[0] != API + "/links": return self.out(404, {})
            if not self.authed(): return self.out(401, {"error": "bad key"})
            try: n = int(self.headers.get("Content-Length") or -1)
            except ValueError: n = -1
            if n < 0: raise ValueError("length needed")
            if n > MAX_REQ: return self.out(413, {"error": "email too large"})
            try: d = json.loads(self.rfile.read(n))
            except ValueError: raise ValueError("bad json")
            if not isinstance(d, dict): raise ValueError("bad json")
            f = {}
            for k, mx in LIMITS.items():
                v = d.get(k)
                if not isinstance(v, str): raise ValueError(k + " must be text")
                try: v.encode("utf-8")
                except UnicodeEncodeError: raise ValueError(k + " is not valid text")   # lone surrogate from a \ud800-style escape
                v = BAD.sub("", v)
                if len(v) > mx: return self.out(413, {"error": f"{k} too long (max {mx} characters)"})
                f[k] = v
            tok, now = secrets.token_urlsafe(24), int(time.time())   # 32 characters, 192 bits
            c = db()
            try:
                with c:
                    c.execute("BEGIN IMMEDIATE"); c.execute("DELETE FROM links WHERE expires <= ?", (now,))
                    if c.execute("SELECT COUNT(*) FROM links").fetchone()[0] >= MAX_LINKS: return self.out(429, {"error": "too many shared links"})
                    c.execute("INSERT INTO links(tok_hash,subject,sender,recipients,date,body,expires) VALUES(?,?,?,?,?,?,?)", (th(tok), f["subject"], f["from"], f["to"], f["date"], f["body"], now + TTL()))
            finally: c.close()
            self.out(200, {"token": tok, "url": E("PUBLIC_BASE", "https://audreypka.com") + "/e/" + tok, "expires_at": now + TTL()})
        except Unavailable: self.out(503, {"error": "key check unavailable, try again"})
        except ValueError as ex: self.out(400, {"error": str(ex)})
        except Exception as ex:
            print("request error:", type(ex).__name__, flush=True); self.out(500, {})
    def do_DELETE(self):
        try:
            m = re.fullmatch(API + r"/links/([A-Za-z0-9_-]{32})", self.path.split("?")[0])
            if not m: return self.out(404, {})
            if not self.authed(): return self.out(401, {"error": "bad key"})
            c = db()
            try:
                with c: n = c.execute("DELETE FROM links WHERE tok_hash=?", (th(m[1]),)).rowcount
            finally: c.close()
            self.out(200, {"status": "deleted" if n else "none"})
        except Unavailable: self.out(503, {"error": "key check unavailable, try again"})
        except Exception as ex:
            print("request error:", type(ex).__name__, flush=True); self.out(500, {})

def main():
    os.umask(0o077)   # emails on disk: owner-only files and folders
    os.makedirs(os.path.dirname(E("DB_PATH", "data/share.db")) or ".", exist_ok=True, mode=0o700)
    threading.Thread(target=worker, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", int(E("PORT", "8094"))), H).serve_forever()

if __name__ == "__main__": main()
