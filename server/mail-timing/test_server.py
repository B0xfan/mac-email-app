#!/usr/bin/env python3
"""Self-check against a pretend Google. Run: python3 -I test_server.py   (no network, no real mail)"""
import json, os, sys, tempfile, threading, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---- pretend Google ----
drafts, sent_log, mode = {"d1", "d2", "d3", "d4", "d5", "d6", "d7", "e1", "e2", "e3", "e4", "e5", "e6", "e7"}, [], {"send": 200, "token": 200, "raw": None, "terr": None}
threads, modify_log, forms, bad_rt = {}, [], [], set()
bad_cid = set()
mode["modify"] = 200
rm_log, msg_labels = [], {}   # snooze: what the pretend mailbox holds per message
def thread(mid, *others): return [{"id": mid, "labelIds": ["SENT"], "internalDate": "1000000"}] + [{"id": o[0], "labelIds": o[1], "internalDate": str(o[2])} for o in others]
class G(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); raw = self.rfile.read(n)
        if self.path.startswith("/messages/") and self.path.endswith("/modify"):
            if mode["modify"] != 200: return self.reply(mode["modify"], {})
            j = json.loads(raw); modify_log.append((self.path[10:-7], j["addLabelIds"])); rm_log.append(j.get("removeLabelIds"))
            if self.path[10:-7] in msg_labels: msg_labels[self.path[10:-7]] = (msg_labels[self.path[10:-7]] - set(j.get("removeLabelIds") or [])) | set(j["addLabelIds"])
            return self.reply(200, {})
        if self.path == "/token":
            form = dict(x.split("=") for x in raw.decode().split("&")); forms.append(form)
            if form["refresh_token"] in bad_rt: return self.reply(400, {"error": "invalid_grant"})
            if form["client_id"] in bad_cid: return self.reply(400, {"error": "invalid_client"})
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
        if self.path == "/labels": return self.reply(200, {"labels": [{"id": "INBOX", "name": "INBOX"}, {"id": "L1", "name": "Snoozed"}]})
        if self.path.startswith("/messages/"):
            m = self.path[10:].split("?")[0]
            return self.reply(200, {"id": m, "labelIds": sorted(msg_labels[m])}) if m in msg_labels else self.reply(404, {})
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

c.execute("INSERT INTO devices(email,device,key_hash,refresh_token,created) VALUES('b@example.com','mac','h','r',1)")
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
c.execute("UPDATE devices SET key_hash=? WHERE email='b@example.com'", (__import__("hashlib").sha256(b"bkey").hexdigest(),)); c.commit()
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
c.execute("UPDATE devices SET key_hash=? WHERE email='b@example.com'", (__import__("hashlib").sha256(b"bkey2").hexdigest(),)); c.commit()
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

# ---- version 3: more than one device, Smart Folders, phone head start ----
import sqlite3, hashlib
os.environ["EXTRA_CLIENT_IDS"] = "ios-client, other-ios"
legacy = tempfile.mkdtemp() + "/old.db"; o = sqlite3.connect(legacy)
o.executescript("CREATE TABLE users(email TEXT PRIMARY KEY, key_hash TEXT NOT NULL, refresh_token TEXT NOT NULL, signin_ok INTEGER NOT NULL DEFAULT 1, created INTEGER NOT NULL);"
                "CREATE TABLE jobs(email TEXT NOT NULL, draft_id TEXT NOT NULL, send_at INTEGER NOT NULL, status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, retry_at INTEGER NOT NULL DEFAULT 0, claimed_at INTEGER, sent_id TEXT, thread_id TEXT, note TEXT, updated INTEGER NOT NULL, PRIMARY KEY(email, draft_id));")
o.execute("INSERT INTO users VALUES('me@example.com',?,'rt',1,5)", (hashlib.sha256(b"oldkey").hexdigest(),))
o.execute("INSERT INTO jobs(email,draft_id,send_at,status,updated) VALUES('me@example.com','old1',9,'pending',1)"); o.commit(); o.close()
real = os.environ["DB_PATH"]; os.environ["DB_PATH"] = legacy; lc = server.db(); d0 = lc.execute("SELECT * FROM devices").fetchall(); lc.close(); lc = server.db()
check("an older database: the one saved sign-in becomes the Mac, its key still works, its jobs are kept",
      len(d0) == 1 and d0[0]["device"] == "mac" and d0[0]["client_id"] is None and d0[0]["key_hash"] == hashlib.sha256(b"oldkey").hexdigest()
      and lc.execute("SELECT COUNT(*) FROM jobs").fetchone()[0] == 1 and lc.execute("SELECT COUNT(*) FROM devices").fetchone()[0] == 1 and lc.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1)
lc.close(); os.environ["DB_PATH"] = real

forms.clear()
check("phone: a Google key the server does not know is refused", req("POST", "/register", {"refresh_token": "p" * 20, "device": "iphone", "client_id": "evil"})[0] == 403)
check("bad device name refused", all(req("POST", "/register", {"refresh_token": "p" * 20, "device": v})[0] == 400 for v in ("", "Mac", "a b", 5, "x" * 21)))
check("bad client_id type refused", req("POST", "/register", {"refresh_token": "p" * 20, "client_id": 5})[0] == 400)
s, b = req("POST", "/register", {"refresh_token": "p" * 20, "device": "iphone", "client_id": "ios-client"}); KP = b.get("api_key")
check("phone registers next to the Mac", s == 200 and bool(KP) and b["device"] == "iphone" and b["email"] == "me@example.com")
check("phone sign-in was checked with the phone's own Google key and no secret", forms and forms[-1]["client_id"] == "ios-client" and "client_secret" not in forms[-1] and forms[-1]["refresh_token"] == "p" * 20)
check("the Mac's key still works after the phone registered", req("GET", "/jobs", key=K2)[0] == 200 and req("GET", "/jobs", key=KP)[0] == 200)
forms.clear(); server._tokens.clear(); s, b = req("POST", "/register", {"refresh_token": "r" * 20}); K3 = b.get("api_key")
check("an app that sends no device name (today's Mac) is 'mac', uses the Mac's key and secret, replaces only the Mac",
      s == 200 and b["device"] == "mac" and forms[-1]["client_id"] == "x" and forms[-1]["client_secret"] == "y"
      and req("GET", "/jobs", key=K2)[0] == 401 and req("GET", "/jobs", key=K3)[0] == 200 and req("GET", "/jobs", key=KP)[0] == 200)
K2 = K3
check("sending the Mac's own key as client_id also counts as the Mac", req("POST", "/register", {"refresh_token": "r" * 20, "client_id": "x"})[1].get("device") == "mac")
K2 = req("POST", "/register", {"refresh_token": "r" * 20})[1]["api_key"]
for n in ("a", "b", "c"): req("POST", "/register", {"refresh_token": "p" * 20, "device": "ipad-" + n, "client_id": "other-ios"})
check("at most 5 devices per person; an existing one can still sign in again",
      req("POST", "/register", {"refresh_token": "p" * 20, "device": "ipad-z", "client_id": "other-ios"})[0] == 429
      and req("POST", "/register", {"refresh_token": "p" * 20, "device": "ipad-a", "client_id": "other-ios"})[0] == 200)

# the phone hands over an email: short head start, sent through whichever sign-in works, cancel works
drafts.update({"g1", "g2", "g3", "g4"}); T = now + 50000
check("grace_seconds outside 0 to 120 or wrong type refused", all(req("PUT", "/jobs/g1", {"send_at": T, "grace_seconds": v}, KP)[0] == 400 for v in (-1, 121, "5", 1.5, True)))
req("PUT", "/jobs/g1", {"send_at": T, "grace_seconds": 5}, KP); req("PUT", "/jobs/g2", {"send_at": T}, KP)
server.tick(T + 4); check("phone email: not sent before its short head start (the app goes first)", "g1" not in sent_log)
server.tick(T + 6); check("phone email: sent right after it; an email with no head start asked for still waits the full 2 minutes", "g1" in sent_log and "g2" not in sent_log)
server.tick(T + 125); check("...and goes after 2 minutes", "g2" in sent_log)
check("jobs are shared by the person's devices", jobs(K2)["g1"]["status"] == "sent" and jobs(KP)["g1"]["status"] == "sent")
req("DELETE", "/jobs/g1", key=KP); req("DELETE", "/jobs/g2", key=KP)
req("PUT", "/jobs/g3", {"send_at": T + 100, "grace_seconds": 0}, KP); check("cancel (Undo) before the time: never sent", req("DELETE", "/jobs/g3", key=KP) == (200, {"status": "pending"}))
server.tick(T + 500); check("cancelled phone email stays unsent", "g3" not in sent_log)
req("PUT", "/jobs/g3", {"send_at": T, "grace_seconds": 0}, KP); req("PUT", "/jobs/g3", {"send_at": T + 9000}, KP)
server.tick(T + 200); check("an edit without grace_seconds goes back to the full head start (whole state each time)", "g3" not in sent_log)
req("DELETE", "/jobs/g3", key=KP)

c.execute("DELETE FROM devices WHERE device LIKE 'ipad-%'"); c.commit()
bad_rt.add("p" * 20); server._tokens.clear(); req("PUT", "/jobs/g4", {"send_at": T, "grace_seconds": 0}, K2); server.tick(T + 30)
check("the phone's sign-in revoked, the Mac's fine: the email is still sent, the phone is flagged, the Mac is not",
      "g4" in sent_log and req("GET", "/jobs", key=KP)[1]["signin_ok"] is False and req("GET", "/jobs", key=K2)[1]["signin_ok"] is True)
bad_rt.clear(); KP = req("POST", "/register", {"refresh_token": "p" * 20, "device": "iphone", "client_id": "ios-client"})[1]["api_key"]
check("phone signs in again: flagged off, works", req("GET", "/jobs", key=KP)[1]["signin_ok"] is True); req("DELETE", "/jobs/g4", key=KP)

# Smart Folders and saved searches
sf = {"id": "A1", "name": "Invoices from Tomas", "matchAll": True, "rules": [{"id": "R1", "field": "from", "value": "tomas"}]}; ss = {"id": "S1", "name": "invoice", "query": "invoice"}
check("organizer: nothing refused without a key", req("GET", "/organizer")[0] == 401 and req("PUT", "/organizer", {"base_version": 0, "smart": [], "searches": []})[0] == 401)
check("organizer: starts empty at version 0", req("GET", "/organizer", key=K2) == (200, {"version": 0, "smart": [], "searches": []}))
check("organizer: Mac saves its list (first start)", req("PUT", "/organizer", {"base_version": 0, "smart": [sf], "searches": [ss], "folded": ["x"]}, K2) == (200, {"version": 1}))
check("organizer: the phone sees the same list, the Mac-only 'folded' is not kept", req("GET", "/organizer", key=KP) == (200, {"version": 1, "smart": [sf], "searches": [ss]}))
s, b = req("PUT", "/organizer", {"base_version": 0, "smart": [], "searches": []}, KP)
check("organizer: a save from an out-of-date copy is refused with the current list, nothing lost", s == 409 and b == {"version": 1, "smart": [sf], "searches": [ss]})
ss2 = {"id": "S2", "name": "Lucia dinner", "query": "Lucia dinner"}
check("organizer: phone saves on top of the current version", req("PUT", "/organizer", {"base_version": 1, "smart": [sf], "searches": [ss, ss2]}, KP) == (200, {"version": 2}) and req("GET", "/organizer", key=K2)[1]["searches"] == [ss, ss2])
check("organizer: an empty list is a valid save (deleting everything)", req("PUT", "/organizer", {"base_version": 2, "smart": [], "searches": []}, K2) == (200, {"version": 3}))
bad = [{"smart": [], "searches": []}, {"base_version": "1", "smart": [], "searches": []}, {"base_version": 3, "searches": []}, {"base_version": 3, "smart": []}, {"base_version": 3, "smart": {}, "searches": []},
       {"base_version": 3, "smart": [{"name": "x"}], "searches": []}, {"base_version": 3, "smart": [], "searches": [{"id": "a", "name": 5}]}, {"base_version": 3, "smart": [], "searches": ["x"]},
       {"base_version": 3, "smart": [{"id": "i%d" % i, "name": "n"} for i in range(101)], "searches": []}, {"base_version": 3, "smart": [{"id": "x" * 65, "name": "n"}], "searches": []}]
check("organizer: malformed saves refused and change nothing", all(req("PUT", "/organizer", b_, K2)[0] == 400 for b_ in bad) and req("GET", "/organizer", key=K2)[1]["version"] == 3)
big = {"base_version": 3, "smart": [{"id": "i%d" % i, "name": "n", "rules": "y" * 700} for i in range(60)], "searches": []}
check("organizer: a 40 KB list is accepted; over 64 KB is refused", req("PUT", "/organizer", big, K2)[0] == 200 and req("PUT", "/organizer", {"base_version": 4, "smart": [{"id": "i", "name": "n", "rules": "y" * 70000}], "searches": []}, K2)[0] == 400)
check("organizer: one person never sees another's list", req("GET", "/organizer", key="bkey2") == (200, {"version": 0, "smart": [], "searches": []}))
check("organizer: other jobs endpoints still refuse an oversized body", req("PUT", "/jobs/zz", {"send_at": now, "pad": "y" * 9000}, K2)[0] == 400)
# ---- timing view (snooze times, "back from snooze", "no reply yet") ----
EMPTY = {"version": 0, "snoozes": {}, "surfaced": {}, "back_tag": [], "no_reply": []}
tv = {"snoozes": {"18a1b2c3d4e5f601": now + 3600}, "surfaced": {"18a1b2c3d4e5f602": now - 60}, "back_tag": ["18a1b2c3d4e5f602"], "no_reply": ["m-x_1"]}
check("timing-view: nothing answered without a key", req("GET", "/timing-view")[0] == 401 and req("PUT", "/timing-view", {"base_version": 0, **tv})[0] == 401 and req("GET", "/timing-view", key="nope")[0] == 401)
check("timing-view: starts empty at version 0", req("GET", "/timing-view", key=K2) == (200, EMPTY))
check("timing-view: Mac saves the whole state, the extra 'junk' field is not kept", req("PUT", "/timing-view", {"base_version": 0, **tv, "junk": 1}, K2) == (200, {"version": 1}))
check("timing-view: the phone reads the same state", req("GET", "/timing-view", key=KP) == (200, {"version": 1, **tv}))
s, b = req("PUT", "/timing-view", {"base_version": 0, "snoozes": {}, "surfaced": {}, "back_tag": [], "no_reply": []}, KP)
check("timing-view: a save from an out-of-date copy gets 409 with the current state, nothing lost", s == 409 and b == {"version": 1, **tv} and req("GET", "/timing-view", key=K2)[1]["version"] == 1)
tv2 = {**tv, "snoozes": {}, "no_reply": []}
check("timing-view: phone saves on the current version; emptying is a valid save", req("PUT", "/timing-view", {"base_version": 1, **tv2}, KP) == (200, {"version": 2}) and req("GET", "/timing-view", key=K2) == (200, {"version": 2, **tv2}))
ok = lambda **kw: {"base_version": 2, **{**tv, **kw}}
bad = [{k: v for k, v in ok().items() if k != "base_version"}, {**ok(), "base_version": "2"}, {**ok(), "base_version": True}, {**ok(), "base_version": -1}]
bad += [{k: v for k, v in ok().items() if k != x} for x in ("snoozes", "surfaced", "back_tag", "no_reply")]
bad += [ok(snoozes=[]), ok(back_tag={}), ok(no_reply="a"), ok(snoozes={"a.b": now}), ok(snoozes={"": now}), ok(snoozes={"a" * 65: now}), ok(no_reply=["bad id"]), ok(no_reply=[5]), ok(back_tag=["a\n"]),
        ok(snoozes={"a1": "123"}), ok(snoozes={"a1": True}), ok(snoozes={"a1": 0}), ok(snoozes={"a1": -5}), ok(snoozes={"a1": 5000000000}), ok(snoozes={"a1": 1.5}), ok(surfaced={"a1": None}),
        ok(back_tag=["a%d" % i for i in range(2001)]), ok(snoozes={"a%d" % i: now for i in range(2001)})]
check("timing-view: malformed saves refused and change nothing", all(req("PUT", "/timing-view", b_, K2)[0] == 400 for b_ in bad) and req("GET", "/timing-view", key=K2)[1]["version"] == 2)
check("timing-view: 2000 ids in a list is accepted", req("PUT", "/timing-view", ok(snoozes={}, back_tag=["b%d" % i for i in range(2000)]), K2) == (200, {"version": 3}))
check("timing-view: over 64 KB is refused", req("PUT", "/timing-view", {**ok(), "base_version": 3, "snoozes": {"a%d" % i: now for i in range(2000)}, "pad": "y" * 70000}, K2)[0] == 400)
check("timing-view: one person never sees another's state", req("GET", "/timing-view", key="bkey2") == (200, EMPTY))
check("timing-view: other endpoints still refuse a 9 KB body", req("PUT", "/reminders/zz", {"remind_at": now, "pad": "y" * 9000}, K2)[0] == 400)
check("timing-view: wrong method is not found", req("DELETE", "/timing-view", key=K2)[0] == 404)
# ---- fix round 1 ----
import socket, sqlite3
def secs(d, key): return (row(d)[key] or 0) - int(time.time())
# 1. phone clock skew: "in N seconds" is turned into a time by the server's own clock
check("relative: send_in_seconds becomes server time + N", req("PUT", "/jobs/rl1", {"send_in_seconds": 60}, K2)[0] == 200 and 58 <= secs("rl1", "send_at") <= 61)
check("relative: remind_in_seconds counts from now; must still be after the send", req("PUT", "/jobs/rl2", {"send_in_seconds": 60, "remind_in_seconds": 3600}, K2)[0] == 200 and 3598 <= secs("rl2", "remind_at") <= 3601
      and req("PUT", "/jobs/rl3", {"send_in_seconds": 60, "remind_in_seconds": 30}, K2)[0] == 400 and row("rl3") is None)
check("relative: both forms together, negative, text, true or absurd refused", all(req("PUT", "/jobs/rl4", b_, K2)[0] == 400 for b_ in
      ({"send_at": now + 60, "send_in_seconds": 60}, {"send_in_seconds": -1}, {"send_in_seconds": "5"}, {"send_in_seconds": True}, {"send_in_seconds": 400 * 86400}, {"send_in_seconds": 60, "remind_at": now + 9000, "remind_in_seconds": 9000})) and row("rl4") is None)
drafts.add("rl5"); req("PUT", "/jobs/rl5", {"send_in_seconds": 0, "grace_seconds": 0}, K2); server.tick(int(time.time()) + 11)
check("relative: 0 seconds + grace 0 goes at the next check, once", sent_log.count("rl5") == 1)
check("relative: the absolute form (the Mac) still works", req("PUT", "/jobs/rl6", {"send_at": now + 5000}, K2)[0] == 200 and row("rl6")["send_at"] == now + 5000)
# 2. nested brackets: 400, not a crash
deep = b"[" * 5000 + b"]" * 5000
check("nested-bracket body: 400 on organizer, jobs and register", req("PUT", "/organizer", raw=deep, headers={"Authorization": "Bearer " + K2})[0] == 400
      and req("PUT", "/jobs/rl7", raw=deep, headers={"Authorization": "Bearer " + K2})[0] == 400 and req("POST", "/register", raw=deep, headers={})[0] == 400)
# 3. an anonymous caller is refused before any body is read
def raw_put(key):
    sk = socket.create_connection(("127.0.0.1", ms.server_port), timeout=3)   # promises 60000 bytes, sends none: a server that reads first would sit waiting
    sk.sendall(("PUT %s/organizer HTTP/1.0\r\nContent-Length: 60000\r\n%s\r\n" % (server.PREFIX, "Authorization: Bearer %s\r\n" % key if key else "")).encode())
    try: return sk.recv(64).split(b" ")[1]
    except socket.timeout: return b"waited"
    finally: sk.close()
check("organizer: no key / wrong key answered 401 without reading the body", raw_put(None) == b"401" and raw_put("nope") == b"401")
check("organizer: a good key still gets its 64 KB allowance", raw_put(K2) == b"waited")
# 4. a trailing newline is not a valid name
check("device name 'iphone\\n' refused, 'iphone' accepted", req("POST", "/register", {"refresh_token": "r" * 20, "device": "iphone\n"})[0] == 400
      and req("POST", "/register", {"refresh_token": "r" * 20, "device": "iphone"})[0] == 200
      and not server.DRAFT_RE.match("d1\n") and not server.DEVICE_RE.match("mac\n") and server.DRAFT_RE.match("d1"))
c.execute("DELETE FROM devices WHERE email='me@example.com' AND device='iphone'"); c.commit()
# 5. one device with a broken key setup does not block the account's other devices
c.execute("INSERT INTO devices(email,device,key_hash,refresh_token,client_id,signin_ok,created) VALUES('me@example.com','phone2','h2','rtok','badcl',1,?)", (int(time.time()) + 100,)); c.commit()
bad_cid.add("badcl"); server._tokens.clear(); drafts.add("fa1"); late("fa1"); server.tick(now + 2000)
check("setup error on the newest device: falls through to the next device, sends once", sent_log.count("fa1") == 1 and row("fa1")["status"] == "sent"
      and c.execute("SELECT COUNT(*) FROM devices WHERE email='me@example.com' AND signin_ok=0").fetchone()[0] == 0)
c.execute("UPDATE devices SET signin_ok=0 WHERE email='me@example.com' AND device<>'phone2'"); c.commit(); drafts.add("fa2"); late("fa2"); server.tick(now + 2000)
check("setup error and every other device refused: job waits to retry, nothing flagged failed", row("fa2")["status"] == "pending" and "fa2" not in sent_log
      and c.execute("SELECT signin_ok FROM devices WHERE device='phone2'").fetchone()[0] == 1)
c.execute("DELETE FROM devices WHERE device='phone2'"); c.execute("UPDATE devices SET signin_ok=1 WHERE email='me@example.com'"); c.execute("DELETE FROM jobs WHERE draft_id='fa2'"); c.commit(); bad_cid.clear()
# ---- snooze return ----
def snz(): return {x["message_id"]: x for x in req("GET", "/snoozes", key=K2)[1]["snoozes"]}
def put_snz(m, at, **kw): return req("PUT", "/snoozes/" + m, {"wake_at": at, **kw}, K2)
c.execute("UPDATE devices SET signin_ok=1 WHERE email='me@example.com'"); c.commit()
check("snooze: no key refused (GET, PUT, DELETE)", all(req(m, p, {"wake_at": now + 60} if m == "PUT" else None)[0] == 401 for m, p in (("GET", "/snoozes"), ("PUT", "/snoozes/s1"), ("DELETE", "/snoozes/s1"))))
check("snooze: bad id, bad time, both time forms refused", req("PUT", "/snoozes/a.b", {"wake_at": now + 60}, K2)[0] == 404
      and all(put_snz("s1", v)[0] == 400 for v in (0, "x", True, now + 9 * 10**8))
      and req("PUT", "/snoozes/s1", {"wake_at": now + 60, "wake_in_seconds": 60}, K2)[0] == 400 and req("PUT", "/snoozes/s1", {}, K2)[0] == 400)
mark = len(modify_log); msg_labels["s1"] = {"L1", "UNREAD"}
check("snooze: created pending", put_snz("s1", now + 600) == (200, {"status": "pending"}) and snz()["s1"]["wake_at"] == now + 600)
server.tick(now + 599); check("snooze: nothing happens before the time", len(modify_log) == mark and snz()["s1"]["status"] == "pending")
put_snz("s1", now + 5000); server.tick(now + 700)
check("snooze: an edited time is respected", len(modify_log) == mark and snz()["s1"]["wake_at"] == now + 5000)
server.tick(now + 5000)
check("snooze: at the time it goes back to the inbox, unread, snooze label off", modify_log[mark:] == [("s1", ["INBOX", "UNREAD"])] and rm_log[-1] == ["L1"] and msg_labels["s1"] == {"INBOX", "UNREAD"} and snz()["s1"]["status"] == "woken")
tv = req("GET", "/timing-view", key=K2)[1]
check("snooze: shared view updated like the Mac (time dropped, surfaced + back_tag set)", "s1" not in tv["snoozes"] and tv["surfaced"]["s1"] == now + 5000 and "s1" in tv["back_tag"] and tv["version"] >= 1)
server.tick(now + 9000); check("snooze: never fires twice", len(modify_log) == mark + 1)
check("snooze: snoozing it again later works", put_snz("s1", now + 20000) == (200, {"status": "pending"}) and snz()["s1"]["status"] == "pending")
check("snooze: cancel before the time", req("DELETE", "/snoozes/s1", key=K2) == (200, {"status": "pending"}) and "s1" not in snz())
msg_labels["s1"] = {"L1"}; server.tick(now + 30000); check("snooze: a cancelled snooze never fires", len(modify_log) == mark + 1)
check("snooze: cancelling an unknown one is harmless", req("DELETE", "/snoozes/zzz", key=K2) == (200, {"status": "none"}))
msg_labels["s2"] = {"INBOX"}; put_snz("s2", now - 60); server.tick(now + 40000)
check("snooze: brought back by hand earlier: left alone", snz()["s2"]["status"] == "skipped" and len(modify_log) == mark + 1)
msg_labels["s3"] = {"L1", "TRASH"}; put_snz("s3", now - 60); server.tick(now + 40000)
check("snooze: trashed while snoozed: left alone", snz()["s3"]["status"] == "skipped" and len(modify_log) == mark + 1)
put_snz("s4", now - 60); server.tick(now + 40000); check("snooze: email deleted: marked gone", snz()["s4"]["status"] == "gone")
msg_labels["s5"] = {"L1"}; mode["modify"] = 503; put_snz("s5", now - 60); server.tick(now + 41000)
check("snooze: Google error: kept to retry", snz()["s5"]["status"] == "pending" and msg_labels["s5"] == {"L1"})
mode["modify"] = 200; server.tick(now + 41010); check("snooze: not retried before its back-off", snz()["s5"]["status"] == "pending")
server.tick(now + 42000); check("snooze: retry later succeeds, once", snz()["s5"]["status"] == "woken" and msg_labels["s5"] == {"INBOX", "UNREAD"})
msg_labels["s6"] = {"L1"}; put_snz("s6", now - 60); ts = [threading.Thread(target=server.tick, args=(now + 50000,)) for _ in range(4)]; [t.start() for t in ts]; [t.join() for t in ts]
check("snooze: four simultaneous checks wake once", [m for m, _ in modify_log].count("s6") == 1)
c.execute("INSERT INTO snoozes(email,message_id,wake_at,status,claimed_at,updated) VALUES('me@example.com','s7',?, 'waking', ?, ?)", (now - 900, int(time.time()), now)); c.commit()
check("snooze: edit or cancel while it is waking refused for now", put_snz("s7", now + 5)[0] == 409 and req("DELETE", "/snoozes/s7", key=K2)[0] == 409)
c.execute("UPDATE snoozes SET claimed_at=?", (now - 400,)); c.commit(); msg_labels["s7"] = {"L1"}; server.tick(now + 60000)
check("snooze: stuck 'waking' after a crash is recovered and woken once", snz()["s7"]["status"] == "woken" and [m for m, _ in modify_log].count("s7") == 1)
mode["token"] = 400; server._tokens.clear(); msg_labels["s8"] = {"L1"}; put_snz("s8", now - 60); server.tick(now + 70000)
check("snooze: revoked sign-in: failed and flagged, mailbox untouched", snz()["s8"]["note"] == "signin" and msg_labels["s8"] == {"L1"})
mode["token"] = 200; K2 = req("POST", "/register", {"refresh_token": "r" * 20})[1]["api_key"]
check("snooze: signing in again gives it another go", snz()["s8"]["status"] == "pending"); server.tick(now + 80000)
check("snooze: and it is then woken once", snz()["s8"]["status"] == "woken")
for i in range(server.MAX_PENDING): c.execute("INSERT INTO snoozes(email,message_id,wake_at,status,updated) VALUES('me@example.com',?,?, 'pending', 1)", ("f%d" % i, now + 99999))
c.commit(); check("snooze: 201st pending refused, but an edit of an existing one still works", put_snz("new", now + 60)[0] == 429 and put_snz("f0", now + 70)[0] == 200)
c.execute("DELETE FROM snoozes WHERE message_id LIKE 'f%'"); c.commit()
c.execute("INSERT INTO snoozes(email,message_id,wake_at,status,updated) VALUES('b@example.com','x9',5,'pending',1)"); c.commit()
check("snooze: one person never sees another's", "x9" not in snz())
# 6. create + copy is one transaction
def fresh_db(users_sql, path):
    os.environ["DB_PATH"] = path; k = sqlite3.connect(path); k.execute(users_sql); k.commit(); k.close()
good = tempfile.mkdtemp() + "/old.db"; broken = tempfile.mkdtemp() + "/old.db"; real = os.environ["DB_PATH"]
fresh_db("CREATE TABLE users(email TEXT, key_hash TEXT, refresh_token TEXT, signin_ok INTEGER, created INTEGER)", good)
k = sqlite3.connect(good); k.execute("INSERT INTO users VALUES('a@x.example','kh','rt',1,5)"); k.commit(); k.close()
errs = []
def starter():
    try: server.db().close()
    except Exception as e: errs.append(e)
ts = [threading.Thread(target=starter) for _ in range(6)]; [t.start() for t in ts]; [t.join() for t in ts]
k = sqlite3.connect(good); mig = k.execute("SELECT email,device,key_hash,client_id FROM devices").fetchall(); keep = k.execute("SELECT COUNT(*) FROM users").fetchone()[0]; k.close()
check("first start of an old database: six simultaneous starters, no error, the old sign-in copied exactly once, old table untouched", not errs and mig == [("a@x.example", "mac", "kh", None)] and keep == 1)
fresh_db("CREATE TABLE users(email TEXT, key_hash TEXT)", broken)   # cannot be copied (columns missing)
try: server.db(); failed = False
except sqlite3.Error: failed = True
k = sqlite3.connect(broken); left = k.execute("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('devices','jobs','organizer','reminders','timing_view','snoozes')").fetchone()[0]; k.close()
check("a copy that fails leaves no half-made tables behind (the next start tries again)", failed and left == 0)
os.environ["DB_PATH"] = real
print("FAILURES:", fails); sys.exit(1 if fails else 0)
