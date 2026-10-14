#!/usr/bin/env python3
"""Self-check against a pretend Google. Run: python3 -I test_server.py   (no network, no real mail)"""
import json, os, sys, tempfile, threading, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---- pretend Google ----
drafts, sent_log, mode = {"d1", "d2", "d3", "d4", "d5", "d6", "d7", "e1", "e2", "e3", "e4", "e5", "e6", "e7"}, [], {"send": 200, "token": 200, "raw": None, "terr": None}
threads, modify_log = {}, []
mode["modify"] = 200
def thread(mid, *others): return [{"id": mid, "labelIds": ["SENT"], "internalDate": "1000000"}] + [{"id": o[0], "labelIds": o[1], "internalDate": str(o[2])} for o in others]
class G(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); raw = self.rfile.read(n)
        if self.path.startswith("/messages/") and self.path.endswith("/modify"):
            if mode["modify"] != 200: return self.reply(mode["modify"], {})
            modify_log.append((self.path[10:-7], json.loads(raw)["addLabelIds"])); return self.reply(200, {})
        if self.path == "/token":
            if mode["terr"]: return self.reply(400, {"error": mode["terr"]})
            return self.reply(200, {"access_token": "AT", "expires_in": 3000}) if mode["token"] == 200 else self.reply(400, {"error": "invalid_grant"})
        if self.path == "/drafts/send":
            if mode["raw"] is not None:   # a 200 that is not a JSON object
                self.send_response(200); self.send_header("Content-Length", str(len(mode["raw"]))); self.end_headers(); return self.wfile.write(mode["raw"])
            if mode["send"] != 200: return self.reply(mode["send"], {})
            did = json.loads(raw)["id"]
            if did in drafts: drafts.discard(did); sent_log.append(did); return self.reply(200, {"id": "m-" + did, "threadId": "t-" + did})
            return self.reply(404, {})
    def do_GET(self):
        if self.path.startswith("/threads/"):
            t = self.path[9:].split("?")[0]
            return self.reply(200, {"messages": threads[t]}) if t in threads else self.reply(404, {})
        self.reply(200, {"emailAddress": "Me@Example.com"} if self.path == "/profile" else {})
gs = ThreadingHTTPServer(("127.0.0.1", 0), G); threading.Thread(target=gs.serve_forever, daemon=True).start()
os.environ.update(GOOGLE_TOKEN_URL=f"http://127.0.0.1:{gs.server_port}/token", GMAIL_BASE=f"http://127.0.0.1:{gs.server_port}",
                  DB_PATH=tempfile.mkdtemp() + "/t.db", ALLOWED_EMAILS="other@example.com", GRACE_SECONDS="120", GOOGLE_CLIENT_ID="x", GOOGLE_CLIENT_SECRET="y")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import server
ms = ThreadingHTTPServer(("127.0.0.1", 0), server.H); threading.Thread(target=ms.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{ms.server_port}{server.PREFIX}"

def req(method, path, body=None, key=None, raw=None, headers=None):
    r = urllib.request.Request(BASE + path, raw if raw is not None else json.dumps(body).encode() if body is not None else None, method=method,
                               headers=headers if headers is not None else {"Authorization": "Bearer " + key} if key else {})
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

# ---- review fixes ----
def row(d): return c.execute("SELECT * FROM jobs WHERE draft_id=?", (d,)).fetchone()
def late(d): req("PUT", "/jobs/" + d, {"send_at": now - 500}, K2)
for e in ("invalid_client", "unauthorized_client"):
    mode["terr"] = e; server._tokens.clear(); late("e1"); server.tick(now + 2000)
    check(f"{e}: retried later, sign-in not flagged", row("e1")["status"] == "pending" and jobs(K2)["e1"]["note"] is None
          and req("GET", "/jobs", key=K2)[1]["signin_ok"] is True and "e1" not in sent_log)
mode["terr"] = None; server.tick(now + 2000 + 4000); check("...and sent once the config error is gone", sent_log.count("e1") == 1)
for raw in (b"not json", b"[1]"):
    mode["raw"] = raw; late("e2"); server.tick(now + 2000)
    check(f"200 reply {raw!r}: job goes back to pending, not stuck sending", row("e2")["status"] == "pending" and row("e2")["attempts"] == 1)
mode["raw"] = None
orig = server.gmail; server.gmail = lambda *a, **k: 1 / 0; late("e7"); server.tick(now + 2000); server.gmail = orig
check("any unexpected error: attempt counted, job pending", row("e7")["status"] == "pending" and row("e7")["attempts"] == 1)
check("send_at older than an hour refused, 59 minutes ago accepted", req("PUT", "/jobs/e3", {"send_at": now - 3700}, K2)[0] == 400 and req("PUT", "/jobs/e3", {"send_at": now - 3500}, K2)[0] == 200)
check("bad Authorization prefix refused", req("GET", "/jobs", headers={"Authorization": "Token " + K2})[0] == 401 and req("GET", "/jobs", headers={"Authorization": K2})[0] == 401)
check("negative Content-Length refused", req("POST", "/register", raw=b"{}", headers={"Content-Length": "-1"})[0] == 400)
check("handler has a socket timeout", server.H.timeout == 30)
check("PUT with bad JSON refused", req("PUT", "/jobs/e3", raw=b"{nope", headers={"Authorization": "Bearer " + K2})[0] == 400)

mode["send"] = 400; late("e4"); server.tick(now + 2000)
check("hard 400 from Google: failed, not retried", row("e4")["status"] == "failed" and row("e4")["note"] == "could not send")
mode["send"] = 503; late("e5")
for i in range(20): c.execute("UPDATE jobs SET retry_at=0 WHERE draft_id='e5' AND status='pending'"); c.commit(); server.tick(now + 2000 + i)
check("20 transient failures: gives up", row("e5")["status"] == "failed" and row("e5")["note"] == "gave up" and row("e5")["attempts"] == 20)
mode["send"] = 200
import socket
server.cfg_gmail = lambda: "http://127.0.0.1:1"; late("e6"); server.tick(now + 9000)
check("network failure (599): kept pending to retry", row("e6")["status"] == "pending" and row("e6")["attempts"] == 1); server.cfg_gmail = lambda: f"http://127.0.0.1:{gs.server_port}"
c.execute("INSERT INTO jobs(email,draft_id,send_at,status,updated) VALUES('me@example.com','old1',1,'sent',?)", (now - 15 * 86400,))
c.execute("INSERT INTO jobs(email,draft_id,send_at,status,updated) VALUES('me@example.com','new1',1,'sent',?)", (now - 13 * 86400,)); c.commit(); server.tick(now)
check("finished jobs purged after 14 days, not before", row("old1") is None and row("new1") is not None)
server.MAX_PENDING = 2; c.execute("DELETE FROM jobs WHERE status='pending'"); c.commit()
codes = [req("PUT", f"/jobs/m{i}", {"send_at": now + 9000}, K2)[0] for i in range(3)]
check("too many scheduled: 429 (an edit of an existing one still fine)", codes == [200, 200, 429] and req("PUT", "/jobs/m0", {"send_at": now + 9100}, K2)[0] == 200); server.MAX_PENDING = 200
c.execute("UPDATE users SET key_hash=? WHERE email='b@example.com'", (__import__("hashlib").sha256(b"bkey").hexdigest(),)); c.commit()
mine = lambda: c.execute("SELECT send_at FROM jobs WHERE email='me@example.com' AND draft_id='m0'").fetchone()
check("another user's PUT/DELETE on my draft id touches only their own row", req("PUT", "/jobs/m0", {"send_at": now + 1}, "bkey")[0] == 200 and mine()["send_at"] == now + 9100
      and req("DELETE", "/jobs/m0", key="bkey") == (200, {"status": "pending"}) and mine() is not None)
# ---- reminders ----
def rem(m, th, at): return req("PUT", "/reminders/" + m, {"thread_id": th, "remind_at": at}, K2)
def rems(): return {x["message_id"]: x for x in req("GET", "/reminders", key=K2)[1]["reminders"]}
def rrow(m): return c.execute("SELECT * FROM reminders WHERE message_id=?", (m,)).fetchone()
check("reminder: bad id, thread or time refused", rem("a.b", "t", now + 60)[0] == 404 and rem("r1", "a b", now + 60)[0] == 400
      and all(rem("r1", "t1", v)[0] == 400 for v in (0, now - 3700, "x", True, now + 9 * 10**8)) and req("GET", "/reminders")[0] == 401)
check("reminder: an hour ago accepted (Mac catching up)", rem("r0", "t0", now - 3500)[0] == 200); req("DELETE", "/reminders/r0", key=K2)
threads["t1"] = thread("r1"); threads["t2"] = thread("r2", ("x", ["INBOX"], 2000000)); threads["t3"] = thread("r3", ("me2", ["SENT"], 2000000), ("dr", ["DRAFT"], 2000000))
for m in ("r1", "r2", "r3"): rem(m, "t" + m[1], now - 10)
server.tick(now); check("reminder: not touched inside the grace window (the Mac goes first)", modify_log == [] and rems()["r1"]["status"] == "pending")
server.tick(now + 130)
check("reminder: no reply -> email back in the inbox, unread, once", modify_log.count(("r1", ["INBOX", "UNREAD"])) == 1 and rems()["r1"]["status"] == "fired")
check("reminder: someone else replied -> no action, marked replied", ("r2", ["INBOX", "UNREAD"]) not in modify_log and rems()["r2"]["status"] == "replied")
check("reminder: my own later email and a draft do not count as a reply", modify_log.count(("r3", ["INBOX", "UNREAD"])) == 1)
server.tick(now + 5000); ts = [threading.Thread(target=server.tick, args=(now + 6000,)) for _ in range(4)]; [t.start() for t in ts]; [t.join() for t in ts]
check("reminder: later and simultaneous checks never fire it again", len(modify_log) == 2)
check("reminder: edit of a finished one refused; delete acknowledges the result", rem("r1", "t1", now + 99)[0] == 409
      and req("DELETE", "/reminders/r1", key=K2) == (200, {"status": "fired"}) and "r1" not in rems())
threads["t4"] = thread("r4"); rem("r4", "t4", now + 7200); rem("r4", "t4", now - 10)
req("PUT", "/reminders/r4", {"thread_id": "t4", "remind_at": now + 7200}, K2); server.tick(now + 130)
check("reminder: changed time respected", modify_log.count(("r4", ["INBOX", "UNREAD"])) == 0)
check("reminder: cancel before it is due -> never fires", req("DELETE", "/reminders/r4", key=K2) == (200, {"status": "pending"}))
server.tick(now + 10**5); check("reminder: cancelled one stays quiet; cancelling an unknown one is harmless", len(modify_log) == 2 and req("DELETE", "/reminders/zz", key=K2)[0] == 200)
rem("r5", "tnone", now - 10); server.tick(now + 130); check("reminder: thread deleted -> gone, no action", rems()["r5"]["status"] == "gone")
threads["t6"] = [{"id": "other", "labelIds": [], "internalDate": "5"}]; rem("r6", "t6", now - 10); server.tick(now + 130)
check("reminder: sent email itself deleted -> gone", rems()["r6"]["status"] == "gone")
threads["t7"] = thread("r7"); mode["modify"] = 503; rem("r7", "t7", now - 10); server.tick(now + 130)
check("reminder: Google error -> kept to retry, not lost", rrow("r7")["status"] == "pending" and rrow("r7")["attempts"] == 1)
mode["modify"] = 200; c.execute("UPDATE reminders SET retry_at=0"); c.commit(); server.tick(now + 140)
check("reminder: retry succeeds, fires once", modify_log.count(("r7", ["INBOX", "UNREAD"])) == 1)
mode["token"] = 400; server._tokens.clear(); threads["t8"] = thread("r8"); rem("r8", "t8", now - 10); server.tick(now + 130)
check("reminder: revoked sign-in -> failed and flagged, nothing done", rrow("r8")["note"] == "signin" and "r8" not in [m for m, _ in modify_log])
mode["token"] = 200; K2 = req("POST", "/register", {"refresh_token": "r" * 20})[1]["api_key"]; server.tick(now + 200)
check("reminder: signing in again gives it another go, fires once", modify_log.count(("r8", ["INBOX", "UNREAD"])) == 1)
server.MAX_PENDING = 1; codes = [rem(f"q{i}", "t1", now + 9000)[0] for i in range(2)]
check("reminder: too many -> 429 (edit of an existing one fine)", codes == [200, 429] and rem("q0", "t1", now + 9100)[0] == 200); server.MAX_PENDING = 200
c.execute("INSERT INTO reminders(email,message_id,thread_id,remind_at,status,claimed_at,updated) VALUES('me@example.com','r9','t9',1,'firing',?,?)", (int(time.time()), now)); c.commit()
threads["t9"] = thread("r9")
check("reminder: edit or cancel while firing refused", rem("r9", "t9", now + 5)[0] == 409 and req("DELETE", "/reminders/r9", key=K2)[0] == 409)
c.execute("UPDATE reminders SET claimed_at=?", (now - 400,)); c.commit(); server.tick(now + 100)
check("reminder: stuck 'firing' after a crash is recovered and fires once", modify_log.count(("r9", ["INBOX", "UNREAD"])) == 1)
# Send Later with a reminder: the server sends, then starts the reminder itself
drafts.add("sl1"); check("job with remind_at: bad value refused", req("PUT", "/jobs/sl1", {"send_at": now + 60, "remind_at": 5}, K2)[0] == 400)
req("PUT", "/jobs/sl1", {"send_at": now - 500, "remind_at": now + 86400}, K2); server.tick(now + 300)
check("job with remind_at: after the server sends, a reminder exists for the sent email", rems()["m-sl1"]["thread_id"] == "t-sl1" and rems()["m-sl1"]["status"] == "pending")
threads["t-sl1"] = thread("m-sl1"); server.tick(now + 86400 + 200)
check("...and fires on time with the Mac off", modify_log.count(("m-sl1", ["INBOX", "UNREAD"])) == 1)
drafts.add("sl2"); req("PUT", "/jobs/sl2", {"send_at": now - 500}, K2); server.tick(now + 300)
check("job without remind_at starts no reminder", "m-sl2" not in rems())
c.execute("INSERT INTO reminders(email,message_id,thread_id,remind_at,status,updated) VALUES('me@example.com','old',1,1,'fired',?)", (now - 15 * 86400,)); c.commit(); server.tick(now)
check("finished reminders purged after 14 days", rrow("old") is None)
# ---- review fixes: reminders ----
check("job: remind_at not after send_at refused (equal and before)", all(req("PUT", "/jobs/rv1", {"send_at": now + 600, "remind_at": v}, K2)[0] == 400 for v in (now + 600, now + 500)) and "rv1" not in jobs(K2))
# a later message that is not a real reply: trash, spam, bounce, out-of-office, auto-submitted
def hm(i, labels, frm="Dana <dana@x.example>", **h):
    return {"id": i, "labelIds": labels, "internalDate": "2000000", "payload": {"headers": [{"name": "From", "value": frm}] + [{"name": k.replace("_", "-"), "value": v} for k, v in h.items()]}}
threads["tn"] = [{"id": "rn", "labelIds": ["SENT"], "internalDate": "1000000"}, hm("a", ["TRASH"]), hm("b", ["SPAM"]), hm("c", ["INBOX"], "Mail Delivery <MAILER-DAEMON@x.example>"),
                 hm("d", ["INBOX"], "postmaster@x.example"), hm("e", ["INBOX"], Auto_Submitted="auto-replied"), hm("f", ["INBOX"], X_Autoreply="yes"), hm("g", ["INBOX"], Precedence="auto_reply")]
rem("rn", "tn", now - 10); server.tick(now + 130)
check("reminder: trash, spam, bounce, out-of-office and automatic mail are not replies -> fires", modify_log.count(("rn", ["INBOX", "UNREAD"])) == 1)
threads["tp"] = [{"id": "rp", "labelIds": ["SENT"], "internalDate": "1000000"}, hm("a", ["TRASH"]), hm("h", ["INBOX"], Auto_Submitted="no")]
rem("rp", "tp", now - 10); server.tick(now + 130)
check("reminder: a person's message (Auto-Submitted: no) still counts as a reply", rems()["rp"]["status"] == "replied" and ("rp", ["INBOX", "UNREAD"]) not in modify_log)
# 403: only rate limits retry
orig_call = server.call
def call403(reason):
    def f(url, data=None, headers=None, method=None):
        if "/messages/" in url and url.endswith("/modify"): return 403, {"error": {"errors": [{"reason": reason}]}}
        return orig_call(url, data, headers, method)
    return f
threads["t403"] = thread("r403"); threads["t403b"] = thread("r403b")
server.call = call403("insufficientPermissions"); rem("r403", "t403", now - 10); server.tick(now + 130)
check("reminder: a 403 that is not a rate limit -> failed with a clear note, not retried", rrow("r403")["status"] == "failed" and rrow("r403")["note"] == "Google refused permission" and rrow("r403")["attempts"] == 1)
server.call = call403("userRateLimitExceeded"); rem("r403b", "t403b", now - 10); server.tick(now + 130); server.call = orig_call
check("reminder: a rate-limit 403 is retried", rrow("r403b")["status"] == "pending" and rrow("r403b")["attempts"] == 1)
# a crash counts as an attempt; the 20th stuck one fails instead of looping
c.execute("INSERT INTO reminders(email,message_id,thread_id,remind_at,status,attempts,claimed_at,updated) VALUES('me@example.com','rs1','t1',1,'firing',3,?,?)", (now - 400, now))
c.execute("INSERT INTO reminders(email,message_id,thread_id,remind_at,status,attempts,claimed_at,updated) VALUES('me@example.com','rs2','t1',1,'firing',19,?,?)", (now - 400, now)); c.commit()
server.tick(now + 140); server.tick(now + 140)
check("reminder: recovering a stuck 'firing' counts an attempt (and the last one fails)", rrow("rs2")["status"] == "failed" and rrow("rs2")["attempts"] == 20 and rrow("rs1")["attempts"] >= 4)
# two people: reminders never cross
c.execute("INSERT INTO reminders(email,message_id,thread_id,remind_at,status,updated) VALUES('b@example.com','bx','t1',9,'pending',1)"); c.commit()
check("reminder: one person never sees another's", "bx" not in rems() and req("DELETE", "/reminders/bx", key=K2) == (200, {"status": "none"}) and rrow("bx") is not None)
c.execute("UPDATE users SET key_hash=? WHERE email='b@example.com'", (__import__("hashlib").sha256(b"bkey2").hexdigest(),)); c.commit()
check("reminder: another user's PUT/DELETE on my message id touches only their own row",
      req("PUT", "/reminders/q0", {"thread_id": "t1", "remind_at": now + 5}, "bkey2")[0] == 200 and rems()["q0"]["remind_at"] == now + 9100
      and req("DELETE", "/reminders/q0", key="bkey2") == (200, {"status": "pending"}) and "q0" in rems())
# job finish + reminder insert are one step: a failing insert leaves the job unfinished
drafts.add("sl3"); req("PUT", "/jobs/sl3", {"send_at": now - 500, "remind_at": now + 86400}, K2)
c.execute("CREATE TRIGGER boom BEFORE INSERT ON reminders WHEN NEW.message_id='m-sl3' BEGIN SELECT RAISE(ABORT,'boom'); END"); c.commit()
try: server.tick(now + 300)
except Exception: pass
check("job + reminder saved together: if the reminder cannot be saved, the job is not marked sent", row("sl3")["status"] in ("sending", "pending") and rrow("m-sl3") is None)
c.execute("DROP TRIGGER boom"); c.commit()
print("FAILURES:", fails); sys.exit(1 if fails else 0)
