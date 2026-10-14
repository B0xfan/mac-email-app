# Mail share-link service ("Copy link to share")

Runs on the droplet (`audrey-server`) as `mail-share.service`, code in `/opt/PKA-John/mail-share/`, behind `https://audreypka.com`.
It keeps ONE email per link as plain text (subject, from, to, date, body) and serves it as a read-only web page at
`https://audreypka.com/e/<token>`: no sign-in, no app, no attachments, no pictures. Links end 30 days after creation and are then
deleted from disk (overwritten, not just unlinked; the database's undo file is emptied after every write too). If the service is down, nginx shows a "Try again later" page.

## What the Mac does
Auth: header `Authorization: Bearer <api_key>`, the SAME key the Mac got from `POST /api/mail-timing/register`
(see `../mail-timing/README.md`). No separate registration. 401 = key wrong or replaced: register with the timing service again.
503 = the key check could not run right now: retry later.

1. Make a link: `POST /api/mail-share/links` with JSON, ALL five fields required, all text:
   `{"subject": "...", "from": "Priya Raman <priya@example.com>", "to": "John Hesch <john@example.com>", "date": "Today, 8:38 AM", "body": "plain text"}`
   - `date` is shown exactly as sent: send the display text you want people to read.
   - `body` must be the PLAIN-TEXT body (no HTML). Limits in CHARACTERS (Unicode code points, what Swift's `unicodeScalars.count` gives):
     subject 300, from 500, to 1000, date 100, body 150000. Trim against these numbers; the Mac should trim (and say so) rather than fail silently.
     Over a limit = 413 `{"error": "... too long (max N characters)"}`.
   - Send the JSON as UTF-8 as-is (Swift's JSONEncoder does this). The whole request may be up to 700 KB, which fits a full 150000-character
     body in any language. Do not escape non-English text as `\uXXXX`: that makes it up to 6 bytes per character and can go over 700 KB.
   - Invisible characters (zero-width, soft hyphen, control and text-direction characters) are removed silently.
     Broken text (a lone half of a surrogate pair) = 400 `{"error": "<field> is not valid text"}`.
   - 200 `{"token": "<32 chars>", "url": "https://audreypka.com/e/<token>", "expires_at": <unix seconds>}`. Copy `url`; keep `token`.
   - 400 = missing or wrong-typed field / bad JSON. 413 = too large (whole request over 700 KB, or a field over its limit).
     429 = 500 shared links exist already (delete some) or too many requests (slow down).
2. Turn a link off early: `DELETE /api/mail-share/links/<token>` -> 200 `{"status":"deleted"}` or `{"status":"none"}` (already gone/expired). Harmless to repeat.
3. There is no list call. The Mac must remember the token (the last 32 characters of the URL) if it wants to offer "stop sharing".

## What a visitor sees
The banner "John Hesch shared this email with you. You can read it here. You cannot reply from this page.", the subject, "From ... . To ... . date",
the body as text (line breaks kept, nothing clickable, nothing executed), and "This link works until <date>". An unknown, deleted or expired link shows
"This link has ended" (404). Service down: "Try again later" (503).

## Safety (what is in place)
- Email text is untrusted: stored as text, control and text-direction characters removed, HTML-escaped on output. Tested with script/img/svg payloads.
- Page headers: `X-Robots-Tag: noindex, nofollow, noarchive`, `Referrer-Policy: no-referrer`, CSP `default-src 'none'` (only the page's own style, by hash), `frame-ancestors 'none'`, `X-Frame-Options: DENY`, `no-store`.
- Token: 192-bit random; only its hash is stored. nginx does not log `/e/` paths (the path is the secret).
- Rate limits per IP: page views 60/min (burst 30), uploads/deletes 30/min (burst 20); over = 429. Request size cap 800 KB in nginx, 700 KB in the service.
- Runs as its own user `mailshare`, data folder 700, database 600, systemd sandbox like mail-timing.
- Auth is checked by asking the timing service on loopback on EVERY call (no caching), so a replaced key stops working at once. If the timing service is down, uploads/deletes answer 503 (page views still work).

## Not here
No "Copy link for me" (Mac only), no attachments, no editing a shared copy (make a new link), no per-person access.
Self-check: `python3 -I test_server.py` (pretend key check, made-up emails, no network).
