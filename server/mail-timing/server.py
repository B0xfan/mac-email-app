#!/usr/bin/env python3
"""Audrey Mail timing service. Holds a scheduled Gmail DRAFT id and its send time; sends it through Gmail
(drafts.send) when the time comes and the Mac has not. The email itself stays in the Gmail draft, never here.
Never sends twice: Gmail consumes the draft on send, so any second attempt (this service, the Mac, a retry
after a timeout) gets 404 and is recorded as "gone". Python standard library only."""
import hashlib, json, os, re, secrets, sqlite3, threading, time, urllib.error, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

E = os.environ.get
PREFIX = "/api/mail-timing"
DRAFT_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}\Z")   # \Z, not $: "$" lets a trailing newline through
DEVICE_RE = re.compile(r"^[a-z0-9-]{1,20}\Z")   # "mac" (what an app that sends no name means) or "iphone"
MAX_DEVICES = 5; MAX_ORGANIZER_BODY = 65536; MAX_TIMING = 2000
GRACE = lambda: int(E("GRACE_SECONDS", "120"))   # the Mac, if awake, goes first; this is the backstop
MAX_PENDING = 200
_tokens = {}   # email -> (access token, expiry); memory only
_lock = threading.Lock()

def cfg_token_url(): return E("GOOGLE_TOKEN_URL", "https://oauth2.googleapis.com/token")
def cfg_gmail(): return E("GMAIL_BASE", "https://gmail.googleapis.com/gmail/v1/users/me")

SCHEMA = ["""CREATE TABLE IF NOT EXISTS devices(email TEXT NOT NULL, device TEXT NOT NULL, key_hash TEXT NOT NULL, refresh_token TEXT NOT NULL,
        client_id TEXT, signin_ok INTEGER NOT NULL DEFAULT 1, created INTEGER NOT NULL, PRIMARY KEY(email, device))""",   # client_id NULL = the Mac's Google key
  """CREATE TABLE IF NOT EXISTS organizer(email TEXT PRIMARY KEY, version INTEGER NOT NULL, doc TEXT NOT NULL, updated INTEGER NOT NULL)""",   # Smart Folders + saved searches: names, rules, search words
  """CREATE TABLE IF NOT EXISTS timing_view(email TEXT PRIMARY KEY, version INTEGER NOT NULL, doc TEXT NOT NULL, updated INTEGER NOT NULL)""",   # snooze + "no reply yet" state: message ids and times only
  """CREATE TABLE IF NOT EXISTS jobs(email TEXT NOT NULL, draft_id TEXT NOT NULL, send_at INTEGER NOT NULL,
        status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, retry_at INTEGER NOT NULL DEFAULT 0, claimed_at INTEGER,
        sent_id TEXT, thread_id TEXT, note TEXT, updated INTEGER NOT NULL, remind_at INTEGER, PRIMARY KEY(email, draft_id))""",
  """CREATE TABLE IF NOT EXISTS reminders(email TEXT NOT NULL, message_id TEXT NOT NULL, thread_id TEXT NOT NULL, remind_at INTEGER NOT NULL,
        status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, retry_at INTEGER NOT NULL DEFAULT 0, claimed_at INTEGER,
        note TEXT, updated INTEGER NOT NULL, PRIMARY KEY(email, message_id))"""]   # ids and times only, never email text

def db():
    c = sqlite3.connect(E("DB_PATH", "data/timing.db"), timeout=10); c.row_factory = sqlite3.Row
    try:
        c.execute("BEGIN IMMEDIATE")   # create + migrate in ONE transaction: a crash or a second starter can never see the new table without its copied rows
        fresh = c.execute("SELECT 1 FROM sqlite_master WHERE name='devices'").fetchone() is None
        for q in SCHEMA: c.execute(q)
        cols = [r[1] for r in c.execute("PRAGMA table_info(jobs)")]
        if "remind_at" not in cols: c.execute("ALTER TABLE jobs ADD COLUMN remind_at INTEGER")   # older database
        if "grace" not in cols: c.execute("ALTER TABLE jobs ADD COLUMN grace INTEGER")   # per-job head start; NULL = GRACE_SECONDS
        if fresh and c.execute("SELECT 1 FROM sqlite_master WHERE name='users'").fetchone():   # one sign-in per person before: that was the Mac. The old table stays untouched.
            c.execute("INSERT OR IGNORE INTO devices(email,device,key_hash,refresh_token,client_id,signin_ok,created) SELECT email,'mac',key_hash,refresh_token,NULL,signin_ok,created FROM users")
        c.commit()
    except BaseException: c.close(); raise
    return c

# ---- Google ----

class SignInGone(Exception): pass          # the saved sign-in no longer works (revoked, expired)
class Retry(Exception): pass               # network trouble, Google 5xx, rate limit: try again later
class SetupError(Retry): pass              # our own Google key setup is wrong for this device (invalid_client): another device may still work

def call(url, data=None, headers=None, method=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            b = json.loads(r.read() or b"{}")
            if not isinstance(b, dict): raise ValueError("not an object")
            return r.status, b
    except urllib.error.HTTPError as e:
        try: body = json.loads(e.read() or b"{}")
        except ValueError: body = {}
        return e.code, body if isinstance(body, dict) else {}
    except (urllib.error.URLError, TimeoutError, OSError, ValueError, AttributeError) as e:
        raise Retry(str(e))

def extra_clients(): return [x.strip() for x in E("EXTRA_CLIENT_IDS", "").split(",") if x.strip()]   # the phone's Google key(s): public, no secret

def access_token(key, refresh, cid=None):
    """key: cache name for this sign-in. cid None = the Mac's Google key (with its secret); else the phone's, which has no secret."""
    with _lock: t = _tokens.get(key)
    if t and t[1] > time.time() + 60: return t[0]
    f = {"client_id": cid or E("GOOGLE_CLIENT_ID", ""), "refresh_token": refresh, "grant_type": "refresh_token"}
    if not cid: f["client_secret"] = E("GOOGLE_CLIENT_SECRET", "")
    form = urllib.parse.urlencode(f).encode()
    s, b = call(cfg_token_url(), form, {"Content-Type": "application/x-www-form-urlencoded"})
    if s == 200 and "access_token" in b:
        with _lock: _tokens[key] = (b["access_token"], time.time() + int(b.get("expires_in", 3000)))
        return b["access_token"]
    if s in (400, 401) and b.get("error") == "invalid_grant": raise SignInGone("invalid_grant")
    if b.get("error") in ("invalid_client", "unauthorized_client"):   # our setup, not the user's sign-in
        print("token config error:", b["error"], flush=True); raise SetupError(f"token {s}")
    raise Retry(f"token {s}")

def gmail(key, refresh, method, path, body=None, cid=None):
    for attempt in (0, 1):
        tok = access_token(key, refresh, cid)
        s, b = call(cfg_gmail() + path, json.dumps(body).encode() if body is not None else None,
                    {"Authorization": "Bearer " + tok, "Content-Type": "application/json"}, method)
        if s == 401 and attempt == 0:
            with _lock: _tokens.pop(key, None)
            continue
        return s, b

def as_user(c, email, method, path, body=None):
    """A Gmail call as this person, through whichever of their devices still has a working sign-in (newest first)."""
    setup = None
    for d in c.execute("SELECT * FROM devices WHERE email=? AND signin_ok=1 ORDER BY created DESC, device", (email,)).fetchall():
        try: return gmail(email + "/" + d["device"], d["refresh_token"], method, path, body, d["client_id"])
        except SignInGone:
            with c: c.execute("UPDATE devices SET signin_ok=0 WHERE email=? AND device=?", (email, d["device"]))
        except SetupError as e: setup = e   # this device's key setup is broken, not its sign-in: try the next device, never flag it
    if setup: raise setup   # nobody worked, but at least one only for a setup reason: retry later instead of failing the job
    raise SignInGone("no sign-in")

# ---- sending ----

def claim(c, email, draft_id, now):
    with c: n = c.execute("UPDATE jobs SET status='sending', claimed_at=? WHERE email=? AND draft_id=? AND status='pending' AND send_at + COALESCE(grace, ?) <= ?",
                          (now, email, draft_id, GRACE(), now)).rowcount   # time re-checked: an edit landing mid-sweep wins
    return n == 1

def reason_of(b):
    return (b.get("error") or {}).get("errors", [{}])[0].get("reason", "") if isinstance(b.get("error"), dict) else ""

def finish(c, email, draft_id, status, now, note=None, sent=None, thread=None, retry_at=0, attempts=None, remind=None):
    with c:   # one transaction: the job is never marked sent without its reminder (or the reverse)
        if remind: c.execute("INSERT OR IGNORE INTO reminders(email,message_id,thread_id,remind_at,status,updated) VALUES(?,?,?,?, 'pending', ?)", (email, sent, thread, remind, now))
        c.execute("UPDATE jobs SET status=?, note=?, sent_id=?, thread_id=?, retry_at=?, claimed_at=NULL, updated=?, attempts=COALESCE(?,attempts) WHERE email=? AND draft_id=?",
                      (status, note, sent, thread, retry_at, now, attempts, email, draft_id))

def process(c, job, now):
    email, did = job["email"], job["draft_id"]
    if not claim(c, email, did, now): return   # someone else (or a cancel) got there first
    try: s, b = as_user(c, email, "POST", "/drafts/send", {"id": did})
    except SignInGone:
        return finish(c, email, did, "failed", now, "signin")
    except Exception as e:   # Retry, or anything odd: the attempt cap below still applies
        s, b = 599, {}
    if s == 200:   # Send Later with a reminder: the reminder starts here, Mac or no Mac
        return finish(c, email, did, "sent", now, None, b.get("id"), b.get("threadId"), remind=job["remind_at"] if b.get("id") and b.get("threadId") else None)
    if s == 404: return finish(c, email, did, "gone", now, "sent or deleted elsewhere")   # the safe outcome of every double-send race
    n = job["attempts"] + 1
    reason = reason_of(b)
    transient = s in (429, 599) or s >= 500 or (s == 403 and "imit" in reason)
    if transient and n < 20:
        return finish(c, email, did, "pending", now, None, None, None, now + min(60 * 2 ** n, 1800), n)
    finish(c, email, did, "failed", now, "could not send" if not transient else "gave up", attempts=n)

# ---- reminders: "remind me if no reply" ----

def rfinish(c, email, mid, status, now, note=None, retry_at=0, attempts=None):
    with c: c.execute("UPDATE reminders SET status=?, note=?, retry_at=?, claimed_at=NULL, updated=?, attempts=COALESCE(?,attempts) WHERE email=? AND message_id=?",
                      (status, note, retry_at, now, attempts, email, mid))

def real_reply(m):
    """A later message from someone else that a person wrote: not mine, a draft, trashed, spam, a bounce or an automatic answer."""
    if {"SENT", "DRAFT", "TRASH", "SPAM"} & set(m.get("labelIds") or []): return False
    h = {str(x.get("name")).lower(): str(x.get("value")).lower() for x in (m.get("payload") or {}).get("headers", []) if isinstance(x, dict)}   # headers are read, never stored
    if "mailer-daemon" in h.get("from", "") or "postmaster" in h.get("from", ""): return False
    if h.get("auto-submitted", "no") != "no" or "x-autoreply" in h or h.get("precedence") == "auto_reply": return False
    return True

def remind(c, r, now):
    email, mid = r["email"], r["message_id"]
    with c: n = c.execute("UPDATE reminders SET status='firing', claimed_at=? WHERE email=? AND message_id=? AND status='pending' AND remind_at + ? <= ?",
                          (now, email, mid, GRACE(), now)).rowcount   # one winner; a cancel or edit that landed first wins
    if n != 1: return
    try:
        s, b = as_user(c, email, "GET", "/threads/" + r["thread_id"] + "?format=metadata&metadataHeaders=From&metadataHeaders=Auto-Submitted&metadataHeaders=X-Autoreply&metadataHeaders=Precedence")
        if s == 200:
            msgs = [m for m in b.get("messages", []) if isinstance(m, dict)]
            me = next((m for m in msgs if m.get("id") == mid), None)
            if not me: return rfinish(c, email, mid, "gone", now, "email deleted")
            sent = int(me.get("internalDate") or 0)   # someone else, later; drafts and my own later emails do not count
            if any(m.get("id") != mid and int(m.get("internalDate") or 0) > sent and real_reply(m) for m in msgs):
                return rfinish(c, email, mid, "replied", now)
            s, b = as_user(c, email, "POST", "/messages/" + mid + "/modify", {"addLabelIds": ["INBOX", "UNREAD"]})
            if s == 200: return rfinish(c, email, mid, "fired", now)   # back at the top of the inbox, unread
    except SignInGone:
        return rfinish(c, email, mid, "failed", now, "signin")
    except Exception: s, b = 599, {}
    if s == 404: return rfinish(c, email, mid, "gone", now, "email deleted")
    n = r["attempts"] + 1
    transient = s in (429, 599) or s >= 500 or (s == 403 and "imit" in reason_of(b))
    if transient and n < 20: return rfinish(c, email, mid, "pending", now, None, now + min(60 * 2 ** n, 1800), n)
    rfinish(c, email, mid, "failed", now, "could not remind" if transient or s != 403 else "Google refused permission", attempts=n)

def tick(now=None):
    now = int(now or time.time()); c = db()
    try: _tick(c, now)
    finally: c.close()

def _tick(c, now):
    with c:   # a crash mid-send leaves "sending": put it back; Gmail's 404 makes a resend harmless
        c.execute("UPDATE jobs SET status='pending' WHERE status='sending' AND claimed_at < ?", (now - 300,))
        c.execute("DELETE FROM jobs WHERE status IN ('sent','gone','failed') AND updated < ?", (now - 14 * 86400,))
        c.execute("UPDATE reminders SET status='failed', note='could not remind', attempts=attempts+1, claimed_at=NULL WHERE status='firing' AND claimed_at < ? AND attempts >= 19", (now - 300,))
        c.execute("UPDATE reminders SET status='pending', attempts=attempts+1 WHERE status='firing' AND claimed_at < ?", (now - 300,))   # a crash counts as an attempt
        c.execute("DELETE FROM reminders WHERE status IN ('fired','replied','gone','failed') AND updated < ?", (now - 14 * 86400,))
    for j in c.execute("SELECT * FROM jobs WHERE status='pending' AND send_at + COALESCE(grace, ?) <= ? AND retry_at <= ? ORDER BY send_at",
                       (GRACE(), now, now)).fetchall():
        process(c, j, now)
    for r in c.execute("SELECT * FROM reminders WHERE status='pending' AND remind_at + ? <= ? AND retry_at <= ? ORDER BY remind_at", (GRACE(), now, now)).fetchall():
        remind(c, r, now)

def worker():
    while True:
        try: tick()
        except Exception as e: print("tick error:", type(e).__name__, flush=True)
        time.sleep(10)

# ---- HTTP ----

def org_doc(c, email):
    r = c.execute("SELECT version, doc FROM organizer WHERE email=?", (email,)).fetchone()
    return {"version": r["version"], **json.loads(r["doc"])} if r else {"version": 0, "smart": [], "searches": []}

TV_TIMES, TV_IDS = ("snoozes", "surfaced"), ("back_tag", "no_reply")
def tv_doc(c, email):
    r = c.execute("SELECT version, doc FROM timing_view WHERE email=?", (email,)).fetchone()
    return {"version": r["version"], **json.loads(r["doc"])} if r else {"version": 0, **{k: {} for k in TV_TIMES}, **{k: [] for k in TV_IDS}}

def rrow(r): return {k: r[k] for k in ("message_id", "thread_id", "remind_at", "status", "note")}
def jrow(r): return {k: r[k] for k in ("draft_id", "send_at", "status", "sent_id", "thread_id", "note")}

class H(BaseHTTPRequestHandler):
    timeout = 30   # socket timeout: a stalled client cannot hold a thread forever
    def log_message(self, *a): pass
    def out(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def body(self, limit=8192):
        n = int(self.headers.get("Content-Length") or 0)
        if not 0 <= n <= limit: raise ValueError("too big")
        try: d = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, RecursionError): raise ValueError("bad json")   # "[[[[..." nests past Python's limit: RecursionError, not ValueError
        if not isinstance(d, dict): raise ValueError("bad json")
        return d
    def user(self, c):
        a = self.headers.get("Authorization") or ""
        k = a[7:] if a.startswith("Bearer ") else ""
        return c.execute("SELECT * FROM devices WHERE key_hash=?", (hashlib.sha256(k.encode()).hexdigest(),)).fetchone() if k else None
    def handle_any(self, method):
        try:
            path = urllib.parse.urlparse(self.path).path
            if not path.startswith(PREFIX): return self.out(404, {})
            parts = [p for p in path[len(PREFIX):].split("/") if p]
            c = db()
            try:
                reg = method == "POST" and parts == ["register"]
                u = None if reg else self.user(c)
                if not reg and not u: return self.out(401, {"error": "bad key"})   # key first: an anonymous caller never gets the big read
                data = self.body(MAX_ORGANIZER_BODY if parts in (["organizer"], ["timing-view"]) else 8192) if method in ("POST", "PUT") else {}
                if reg: return self.register(c, data)
                if method == "GET" and parts == ["jobs"]:
                    return self.out(200, {"signin_ok": bool(u["signin_ok"]), "jobs": [jrow(r) for r in c.execute("SELECT * FROM jobs WHERE email=? ORDER BY send_at", (u["email"],))]})
                if method == "GET" and parts == ["reminders"]:
                    return self.out(200, {"signin_ok": bool(u["signin_ok"]), "reminders": [rrow(r) for r in c.execute("SELECT * FROM reminders WHERE email=? ORDER BY remind_at", (u["email"],))]})
                if parts == ["organizer"]:
                    if method == "GET": return self.out(200, org_doc(c, u["email"]))
                    if method == "PUT": return self.put_organizer(c, u, data)
                if parts == ["timing-view"]:
                    if method == "GET": return self.out(200, tv_doc(c, u["email"]))
                    if method == "PUT": return self.put_timing_view(c, u, data)
                if len(parts) == 2 and parts[0] == "reminders" and DRAFT_RE.match(parts[1]):
                    if method == "PUT": return self.put_reminder(c, u, parts[1], data)
                    if method == "DELETE": return self.del_reminder(c, u, parts[1])
                if len(parts) == 2 and parts[0] == "jobs" and DRAFT_RE.match(parts[1]):
                    if method == "PUT": return self.put_job(c, u, parts[1], data)
                    if method == "DELETE": return self.del_job(c, u, parts[1])
                self.out(404, {})
            finally: c.close()
        except ValueError as e: self.out(400, {"error": str(e)})
        except Exception as e:
            print("request error:", type(e).__name__, flush=True); self.out(500, {})
    do_GET = lambda s: s.handle_any("GET"); do_PUT = lambda s: s.handle_any("PUT")
    do_POST = lambda s: s.handle_any("POST"); do_DELETE = lambda s: s.handle_any("DELETE")

    def register(self, c, d):
        rt = d.get("refresh_token")
        if not isinstance(rt, str) or not 10 < len(rt) < 2048: raise ValueError("refresh_token needed")
        dev, cid = d.get("device", "mac"), d.get("client_id")   # an app that sends neither is the Mac of before, unchanged
        if not isinstance(dev, str) or not DEVICE_RE.match(dev): raise ValueError("bad device name")
        if cid is not None:
            if not isinstance(cid, str) or len(cid) > 200: raise ValueError("bad client_id")
            if cid == E("GOOGLE_CLIENT_ID", ""): cid = None
            elif cid not in extra_clients(): return self.out(403, {"error": "that app's Google key is not known to the server"})
        try:
            s, b = gmail("reg:" + hashlib.sha256(rt.encode()).hexdigest()[:12], rt, "GET", "/profile", None, cid)
        except SignInGone: return self.out(403, {"error": "Google did not accept that sign-in"})
        except Retry: return self.out(503, {"error": "could not reach Google"})
        email = (b.get("emailAddress") or "").lower() if s == 200 else ""
        if not email or email not in [a.strip().lower() for a in E("ALLOWED_EMAILS", "").split(",") if a.strip()]:
            return self.out(403, {"error": "this address is not on the list"})
        key = secrets.token_urlsafe(32); now = int(time.time())
        with c:   # signing in again: this device gets a new key and token (the other devices are untouched); jobs that failed only because of a sign-in get another go
            c.execute("BEGIN IMMEDIATE")
            if c.execute("SELECT 1 FROM devices WHERE email=? AND device=?", (email, dev)).fetchone() is None and c.execute("SELECT COUNT(*) FROM devices WHERE email=?", (email,)).fetchone()[0] >= MAX_DEVICES:
                return self.out(429, {"error": "too many devices"})
            c.execute("INSERT INTO devices(email,device,key_hash,refresh_token,client_id,signin_ok,created) VALUES(?,?,?,?,?,1,?) ON CONFLICT(email,device) DO UPDATE SET key_hash=excluded.key_hash, refresh_token=excluded.refresh_token, client_id=excluded.client_id, signin_ok=1",
                      (email, dev, hashlib.sha256(key.encode()).hexdigest(), rt, cid, now))
            c.execute("UPDATE jobs SET status='pending', note=NULL, attempts=0, retry_at=0 WHERE email=? AND status='failed' AND note='signin'", (email,))
            c.execute("UPDATE reminders SET status='pending', note=NULL, attempts=0, retry_at=0 WHERE email=? AND status='failed' AND note='signin'", (email,))
        with _lock: _tokens.pop(email + "/" + dev, None)
        self.out(200, {"api_key": key, "email": email, "device": dev})

    def when(self, d, key, now):
        """An absolute time (key) or seconds from now (key_in_seconds, by the server's own clock: a phone clock that runs fast cannot send early). Not both."""
        a, r = d.get(key), d.get(key.replace("_at", "_in_seconds"))
        if r is None: return a
        if a is not None: raise ValueError(f"send either {key} or its _in_seconds form, not both")
        if not isinstance(r, int) or isinstance(r, bool) or not 0 <= r < 400 * 86400: raise ValueError(key.replace("_at", "_in_seconds") + " must be 0 to 400 days of seconds")
        return now + r

    def put_job(self, c, u, did, d):
        now = int(time.time()); at = self.when(d, "send_at", now)
        if not isinstance(at, int) or isinstance(at, bool) or not now - 3600 <= at < now + 400 * 86400: raise ValueError("send_at must be within the last hour or the next 400 days")
        rem = self.when(d, "remind_at", now)   # optional: start a reminder on the sent email if this goes out while the Mac is off
        if rem is not None and (not isinstance(rem, int) or isinstance(rem, bool) or not now - 3600 <= rem < now + 400 * 86400): raise ValueError("remind_at must be within the last hour or the next 400 days")
        if rem is not None and rem <= at: raise ValueError("remind_at must be after send_at")
        gr = d.get("grace_seconds")   # optional head start for the app (phone emails: a few seconds); none = the server's usual 2 minutes
        if gr is not None and (not isinstance(gr, int) or isinstance(gr, bool) or not 0 <= gr <= GRACE()): raise ValueError("grace_seconds must be 0 to %d" % GRACE())
        with c:   # one transaction: no gap between the check and the write
            c.execute("BEGIN IMMEDIATE")
            r = c.execute("SELECT status FROM jobs WHERE email=? AND draft_id=?", (u["email"], did)).fetchone()
            if r and r["status"] in ("sending", "sent", "gone"): return self.out(409, {"status": r["status"]})
            if not r and c.execute("SELECT COUNT(*) FROM jobs WHERE email=? AND status='pending'", (u["email"],)).fetchone()[0] >= MAX_PENDING:
                return self.out(429, {"error": "too many scheduled emails"})
            c.execute("INSERT INTO jobs(email,draft_id,send_at,status,updated,remind_at,grace) VALUES(?,?,?, 'pending', ?, ?, ?) ON CONFLICT(email,draft_id) DO UPDATE SET send_at=excluded.send_at, status='pending', attempts=0, retry_at=0, note=NULL, updated=excluded.updated, remind_at=excluded.remind_at, grace=excluded.grace",
                      (u["email"], did, at, now, rem, gr))
        self.out(200, {"status": "pending"})

    def del_job(self, c, u, did):
        with c:
            c.execute("BEGIN IMMEDIATE")
            r = c.execute("SELECT status FROM jobs WHERE email=? AND draft_id=?", (u["email"], did)).fetchone()
            if not r: return self.out(200, {"status": "none"})
            if r["status"] == "sending": return self.out(409, {"status": "sending"})   # in flight: ask again in a moment
            c.execute("DELETE FROM jobs WHERE email=? AND draft_id=?", (u["email"], did))
        self.out(200, {"status": r["status"]})   # "pending" = cancelled; sent/gone/failed = result acknowledged

    def put_organizer(self, c, u, d):
        bv = d.get("base_version")
        if not isinstance(bv, int) or isinstance(bv, bool) or bv < 0: raise ValueError("base_version needed")
        doc = {}
        for k in ("smart", "searches"):   # both lists required, so a half-formed call can never wipe the other list; anything else the app sends (e.g. "folded") is not kept
            v = d.get(k)
            if not isinstance(v, list) or len(v) > 100: raise ValueError(k + " must be a list of up to 100")
            if not all(isinstance(x, dict) and isinstance(x.get("id"), str) and 0 < len(x["id"]) <= 64 and isinstance(x.get("name"), str) and len(x["name"]) <= 200 for x in v): raise ValueError("every entry in " + k + " needs an id and a name")
            doc[k] = v
        with c:
            c.execute("BEGIN IMMEDIATE")
            cur = org_doc(c, u["email"])
            if cur["version"] != bv: return self.out(409, cur)   # someone else saved first: the app merges onto this and tries again
            c.execute("INSERT INTO organizer(email,version,doc,updated) VALUES(?,?,?,?) ON CONFLICT(email) DO UPDATE SET version=excluded.version, doc=excluded.doc, updated=excluded.updated",
                      (u["email"], bv + 1, json.dumps(doc), int(time.time())))
        self.out(200, {"version": bv + 1})

    def put_timing_view(self, c, u, d):
        bv = d.get("base_version")
        if not isinstance(bv, int) or isinstance(bv, bool) or bv < 0: raise ValueError("base_version needed")
        doc = {}
        for k in TV_TIMES + TV_IDS:   # all four required, so a half-formed call can never wipe the others; anything else sent is not kept
            v = d.get(k)
            if not isinstance(v, dict if k in TV_TIMES else list) or len(v) > MAX_TIMING: raise ValueError(k + " must be a " + ("map" if k in TV_TIMES else "list") + " of up to %d" % MAX_TIMING)
            if not all(isinstance(i, str) and DRAFT_RE.match(i) for i in v): raise ValueError("every id in " + k + " must be a message id")
            if k in TV_TIMES and not all(isinstance(t, int) and not isinstance(t, bool) and 0 < t < 4102444800 for t in v.values()): raise ValueError("every time in " + k + " must be unix seconds")
            doc[k] = v
        with c:
            c.execute("BEGIN IMMEDIATE")
            cur = tv_doc(c, u["email"])
            if cur["version"] != bv: return self.out(409, cur)   # another device saved first: merge onto this and try again
            c.execute("INSERT INTO timing_view(email,version,doc,updated) VALUES(?,?,?,?) ON CONFLICT(email) DO UPDATE SET version=excluded.version, doc=excluded.doc, updated=excluded.updated",
                      (u["email"], bv + 1, json.dumps(doc), int(time.time())))
        self.out(200, {"version": bv + 1})

    def put_reminder(self, c, u, mid, d):
        at, th, now = d.get("remind_at"), d.get("thread_id"), int(time.time())
        if not isinstance(at, int) or isinstance(at, bool) or not now - 3600 <= at < now + 400 * 86400: raise ValueError("remind_at must be within the last hour or the next 400 days")
        if not isinstance(th, str) or not DRAFT_RE.match(th): raise ValueError("thread_id needed")
        with c:
            c.execute("BEGIN IMMEDIATE")
            r = c.execute("SELECT status FROM reminders WHERE email=? AND message_id=?", (u["email"], mid)).fetchone()
            if r and r["status"] != "pending": return self.out(409, {"status": r["status"]})   # already acted on (or being acted on): the Mac reads the result instead
            if not r and c.execute("SELECT COUNT(*) FROM reminders WHERE email=? AND status='pending'", (u["email"],)).fetchone()[0] >= MAX_PENDING:
                return self.out(429, {"error": "too many reminders"})
            c.execute("INSERT INTO reminders(email,message_id,thread_id,remind_at,status,updated) VALUES(?,?,?,?, 'pending', ?) ON CONFLICT(email,message_id) DO UPDATE SET thread_id=excluded.thread_id, remind_at=excluded.remind_at, attempts=0, retry_at=0, updated=excluded.updated",
                      (u["email"], mid, th, at, now))
        self.out(200, {"status": "pending"})

    def del_reminder(self, c, u, mid):
        with c:
            c.execute("BEGIN IMMEDIATE")
            r = c.execute("SELECT status FROM reminders WHERE email=? AND message_id=?", (u["email"], mid)).fetchone()
            if not r: return self.out(200, {"status": "none"})
            if r["status"] == "firing": return self.out(409, {"status": "firing"})
            c.execute("DELETE FROM reminders WHERE email=? AND message_id=?", (u["email"], mid))
        self.out(200, {"status": r["status"]})   # "pending" = cancelled; fired/replied/gone/failed = result acknowledged

def main():
    os.umask(0o077)   # the DB holds refresh tokens: owner-only files and folders
    os.makedirs(os.path.dirname(E("DB_PATH", "data/timing.db")) or ".", exist_ok=True, mode=0o700)
    threading.Thread(target=worker, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", int(E("PORT", "8093"))), H).serve_forever()

if __name__ == "__main__": main()
