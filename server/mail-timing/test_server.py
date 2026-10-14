#!/usr/bin/env python3
"""Self-check against a pretend Google. Run: python3 -I test_server.py   (no network, no real mail)"""
import json, os, sys, tempfile, threading, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---- pretend Google ----
drafts, sent_log, mode = {"d1", "d2", "d3", "d4", "d5", "d6", "d7"}, [], {"send": 200, "token": 200}
class G(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); raw = self.rfile.read(n)
        if self.path == "/token":
            return self.reply(200, {"access_token": "AT", "expires_in": 3000}) if mode["token"] == 200 else self.reply(400, {"error": "invalid_grant"})
        if self.path == "/drafts/send":
            if mode["send"] != 200: return self.reply(mode["send"], {})
            did = json.loads(raw)["id"]
            if did in drafts: drafts.discard(did); sent_log.append(did); return self.reply(200, {"id": "m-" + did, "threadId": "t-" + did})
            return self.reply(404, {})
    def do_GET(self): self.reply(200, {"emailAddress": "Me@Example.com"} if self.path == "/profile" else {})
gs = ThreadingHTTPServer(("127.0.0.1", 0), G); threading.Thread(target=gs.serve_forever, daemon=True).start()
os.environ.update(GOOGLE_TOKEN_URL=f"http://127.0.0.1:{gs.server_port}/token", GMAIL_BASE=f"http://127.0.0.1:{gs.server_port}",
                  DB_PATH=tempfile.mkdtemp() + "/t.db", ALLOWED_EMAILS="other@example.com", GRACE_SECONDS="120", GOOGLE_CLIENT_ID="x", GOOGLE_CLIENT_SECRET="y")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import server
ms = ThreadingHTTPServer(("127.0.0.1", 0), server.H); threading.Thread(target=ms.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{ms.server_port}{server.PREFIX}"

def req(method, path, body=None, key=None):
    r = urllib.request.Request(BASE + path, json.dumps(body).encode() if body is not None else None, method=method,
                               headers={"Authorization": "Bearer " + key} if key else {})
    try:
        with urllib.request.urlopen(r) as x: return x.status, json.loads(x.read())
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or b"{}")

fails = 0
def check(name, ok):
    global fails; fails += (not ok); print(("PASS " if ok else "FAIL ") + name)
def jobs(k): return {x["draft_id"]: x for x in req("GET", "/jobs", key=k)[1]["jobs"]}

now = int(time.time())
check("register: refused for an address not on the list", req("POST", "/register", {"refresh_token": "r" * 20})[0] == 403)
os.environ["ALLOWED_EMAILS"] = "me@example.com"
check("register: bad body refused", req("POST", "/register", {})[0] == 400)
s, b = req("POST", "/register", {"refresh_token": "r" * 20}); K = b.get("api_key")
check("register: allowed address gets a key", s == 200 and bool(K) and b["email"] == "me@example.com")
check("no key / wrong key refused", req("GET", "/jobs")[0] == 401 and req("GET", "/jobs", key="nope")[0] == 401)
check("bad draft id refused", req("PUT", "/jobs/a.b", {"send_at": now + 60}, K)[0] == 404)
check("send_at out of range or wrong type refused", all(req("PUT", "/jobs/d1", {"send_at": v}, K)[0] == 400 for v in (0, "x", now + 9 * 10**8, True)))

req("PUT", "/jobs/d1", {"send_at": now - 10}, K); server.tick(now)
check("not sent inside the grace window (the Mac goes first)", sent_log == [])
server.tick(now + 130); j = jobs(K)
check("sent after the grace window; sent id recorded", sent_log == ["d1"] and j["d1"]["status"] == "sent" and j["d1"]["sent_id"] == "m-d1")
server.tick(now + 400); check("later checks never send it again", sent_log == ["d1"])
check("editing a sent job refused", req("PUT", "/jobs/d1", {"send_at": now + 99}, K)[0] == 409)
check("deleting a sent job acknowledges the result", req("DELETE", "/jobs/d1", key=K) == (200, {"status": "sent"}) and not jobs(K))

drafts.discard("d2"); req("PUT", "/jobs/d2", {"send_at": now - 500}, K); server.tick(now)
check("Mac sent it first (draft gone): marked gone, nothing sent", sent_log == ["d1"] and jobs(K)["d2"]["status"] == "gone")
req("DELETE", "/jobs/d2", key=K)

req("PUT", "/jobs/d3", {"send_at": now - 500}, K); req("PUT", "/jobs/d3", {"send_at": now + 7200}, K); server.tick(now)
check("edited time respected: not sent at the old time", "d3" not in sent_log)
check("cancel before send time removes it", req("DELETE", "/jobs/d3", key=K) == (200, {"status": "pending"}))
server.tick(now + 10**5); check("a cancelled job is never sent", "d3" not in sent_log)
check("cancelling an unknown job is harmless", req("DELETE", "/jobs/zzz", key=K)[0] == 200)

mode["send"] = 503; req("PUT", "/jobs/d4", {"send_at": now - 500}, K); server.tick(now)
check("Google error: kept to retry later", jobs(K)["d4"]["status"] == "pending" and "d4" not in sent_log)
server.tick(now + 10); mode["send"] = 200; server.tick(now + 20)
check("not retried before its back-off", "d4" not in sent_log)
server.tick(now + 200); check("retry later succeeds, sent once", sent_log.count("d4") == 1)
req("DELETE", "/jobs/d4", key=K)

req("PUT", "/jobs/d5", {"send_at": now - 500}, K)
ts = [threading.Thread(target=server.tick, args=(now + 1000,)) for _ in range(4)]; [t.start() for t in ts]; [t.join() for t in ts]
check("four simultaneous checks send once", sent_log.count("d5") == 1); req("DELETE", "/jobs/d5", key=K)

c = server.db()
req("PUT", "/jobs/d8", {"send_at": now - 500}, K); stale = c.execute("SELECT * FROM jobs WHERE draft_id='d8'").fetchone()
req("PUT", "/jobs/d8", {"send_at": now + 9000}, K)
check("an edit that lands after the sweep picked the job still wins", not server.claim(c, "me@example.com", "d8", now) and "d8" not in sent_log)
req("DELETE", "/jobs/d8", key=K)
c.execute("INSERT INTO jobs(email,draft_id,send_at,status,claimed_at,updated) VALUES('me@example.com','d6',?, 'sending', ?, ?)", (now - 900, int(time.time()), now)); c.commit()
check("edit or cancel of a job being sent is refused for now", req("PUT", "/jobs/d6", {"send_at": now + 5}, K)[0] == 409 and req("DELETE", "/jobs/d6", key=K)[0] == 409)
c.execute("UPDATE jobs SET claimed_at=?", (now - 400,)); c.commit(); server.tick(now + 100)
check("job stuck in 'sending' after a crash is recovered and sent once", sent_log.count("d6") == 1); req("DELETE", "/jobs/d6", key=K)

mode["token"] = 400; server._tokens.clear(); req("PUT", "/jobs/d7", {"send_at": now - 500}, K); server.tick(now)
s, b = req("GET", "/jobs", key=K)
check("revoked sign-in: job failed and flagged, nothing sent", b["jobs"][0]["note"] == "signin" and b["signin_ok"] is False and "d7" not in sent_log)
mode["token"] = 200; K2 = req("POST", "/register", {"refresh_token": "r" * 20})[1]["api_key"]
check("signing in again: old key stops, the job gets another go", req("GET", "/jobs", key=K)[0] == 401 and jobs(K2)["d7"]["status"] == "pending")
server.tick(now + 200); check("and is then sent once", sent_log.count("d7") == 1)

c.execute("INSERT INTO users(email,key_hash,refresh_token,created) VALUES('b@example.com','h','r',1)")
c.execute("INSERT INTO jobs(email,draft_id,send_at,status,updated) VALUES('b@example.com','x1',5,'pending',1)"); c.commit()
check("one person never sees another's jobs", "x1" not in jobs(K2))
print("FAILURES:", fails); sys.exit(1 if fails else 0)
