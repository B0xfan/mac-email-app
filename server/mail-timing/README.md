# Mail timing service (Send Later while the Mac is off)

Runs on the droplet (`audrey-server`) as `mail-timing.service`, code in `/opt/PKA-John/mail-timing/`, behind
`https://audreypka.com/api/mail-timing/`. It holds a Gmail DRAFT id and a send time per job, plus each user's Google refresh token (needed to send; stored in
the database, owner-only file modes, service runs as a non-root user). The email itself stays in Gmail.

## What the Mac does
1. Once per install: `POST /register` `{"refresh_token": "<the Mac's Google refresh token>"}` -> `{"api_key","email","device"}`.
   Store `api_key` in the same private file as the sign-in. Signing in again gives a new key (the old one stops) for THAT device only.
   400 = body missing/invalid or no refresh token or bad device name; 403 = address not on the list, or the app's Google key is not known; 429 = already 5 devices; 503 = Google unreachable (retry).
   **Several devices per person (v3).** Optional body fields `"device"` (lowercase letters, digits, `-`, up to 20; default `"mac"`, so the Mac sends nothing new) and
   `"client_id"` (the Google client ID the refresh token was issued to; omit it or send the Mac's own for the Mac; the phone sends its iOS client ID, which must be in the server's
   `EXTRA_CLIENT_IDS` setting; it has no secret, so the server refreshes it without one). Each device has its own key and sign-in. Jobs, reminders and the Smart Folder list belong to the person, not the device.
   The server sends and reminds through whichever of the person's devices still has a working sign-in (newest first); a device whose sign-in Google refuses is flagged (`signin_ok` false in its own `GET /jobs`), the others carry on.
2. Every request after: header `Authorization: Bearer <api_key>`. 401 = key wrong or replaced: register again.
3. Schedule or change time: create/keep the Gmail draft as today, then `PUT /jobs/<draftId>` `{"send_at": <unix seconds>}`.
   Same call edits the time. 200 `{"status":"pending"}`. 409 `{"status":"sending|sent|gone"}` = too late to change, treat as sent.
   400 = bad time (not more than 1 hour in the past, not more than 400 days ahead). 429 = 200 scheduled already.
   Optional `"grace_seconds"` (0 to 120): this job's head start for the app instead of the usual 2 minutes (the phone uses a few seconds so an Undo Send email goes out close to its time; the server checks every 10 seconds, so it can be up to ~10 s later). Like `remind_at`, an edit without it goes back to the usual 2 minutes.
   The phone sends `"send_in_seconds": N` instead of `send_at` (and `"remind_in_seconds"` instead of `remind_at`): the server adds N to its own clock, so a phone clock that runs fast cannot send early. Giving both forms is a 400. The Mac keeps using `send_at`.
   The phone hands over an email for Undo Send exactly like Send Later: create the Gmail draft, `PUT /jobs/<draftId>` with `send_in_seconds` = the Undo delay and a small `grace_seconds`; Undo = `DELETE /jobs/<draftId>` before touching the draft.
4. Cancel / Keep as draft / Send now: `DELETE /jobs/<draftId>` BEFORE touching the draft. 200 with `status`:
   `pending` = cancelled in time; `none` = nothing there; `sent|gone|failed` = result acknowledged (it already happened).
   409 `sending` = the server is sending right now: ask again in a few seconds. The job can then be `sent`, `gone`, `failed`, or
   `pending` again (the send hit a snag and will retry, so DELETE once more to cancel).
5. Status: `GET /jobs` -> `{"signin_ok": bool, "jobs":[{draft_id, send_at, status, sent_id, thread_id, note}]}`.
   status: `pending` | `sending` | `sent` (server sent it) | `gone` (draft was already sent or deleted elsewhere, i.e. the Mac won)
   | `failed` (note `signin` = Google sign-in no longer works, register again and it retries; else `could not send`/`gave up`).
   Finished jobs are kept 14 days so the Mac can show "sent while you were away", then purged.

## Never twice
- The server waits 2 minutes after `send_at` (the Mac, if awake, goes first). Both sides use Gmail `drafts.send`, which
  consumes the draft: the second caller gets 404. The Mac MUST treat a 404 from `drafts.send` as "already sent", not an error.
- When the Mac sends on time it should `DELETE /jobs/<draftId>` afterwards (not required for safety).
- Editing the draft's text in Gmail is fine (draft id is unchanged). If the Mac ever re-creates the draft with a new id,
  `DELETE` the old job and `PUT` the new one.

## Reminders ("Remind me if no reply") while the Mac is off
Same service, same key, same 2-minute grace. The server stores only ids and times (message id, thread id, due time), never email text.
Message ids and thread ids are the Gmail ids Mail already has (letters, digits, `_`, `-`, up to 64).
1. Register: when the sent email's id is known, `PUT /reminders/<sentMessageId>` `{"thread_id": "<threadId>", "remind_at": <unix seconds>}`.
   Same call changes the time. 200 `{"status":"pending"}`. 400 = bad time (not more than 1 hour in the past, not more than 400 days ahead) or bad thread id.
   409 `{"status": ...}` = the server already acted on it (read the result, below). 429 = 200 pending reminders already.
2. Send Later with a reminder: add `"remind_at": <unix seconds>` to the `PUT /jobs/<draftId>` body (same time rules, and it must be later than `send_at`, else 400). When the SERVER
   sends the email, it creates the reminder itself for the sent message, so a reminder survives the Mac being off for days. When the Mac
   sends it instead, the Mac registers the reminder as in step 1. An edit `PUT /jobs/...` without `remind_at` removes it, so always send the whole state.
   After a job comes back `sent`, `GET /reminders` may already hold the reminder for `sent_id`; a `PUT /reminders/<sent_id>` while it is still pending is harmless (same values).
3. Cancel / the user removes the reminder: `DELETE /reminders/<messageId>`. 200 `status`: `pending` = cancelled in time; `none` = nothing there;
   `fired|replied|gone|failed` = result acknowledged. 409 `firing` = in flight, ask again in a few seconds.
4. Status: `GET /reminders` -> `{"signin_ok": bool, "reminders":[{message_id, thread_id, remind_at, status, note}]}`.
   status: `pending` | `firing` | `fired` (server brought the email back) | `replied` (someone answered, nothing done) | `gone` (the email or thread was deleted)
   | `failed` (it NEVER fired: note `signin` = register again and it retries; `Google refused permission` = Google refused the change, a 403 that is not a rate limit, no retry; `could not remind` = gave up after 20 tries). Finished ones are kept 14 days, then purged.
5. What the server does at `remind_at` + 2 minutes (the Mac goes first): it reads the thread. If anyone else wrote after the sent email (your own later emails and drafts do not count, exactly like the Mac's rule; neither do messages in Trash or Spam, bounces from
   mailer-daemon/postmaster, or automatic answers such as out-of-office, i.e. `Auto-Submitted` other than `no`, `X-Autoreply`, `Precedence: auto_reply`. The server reads only those headers from Gmail while checking and stores none of them), it does nothing and marks `replied`.
   Otherwise it adds the labels `INBOX` and `UNREAD` to the sent message (the same two labels the Mac adds), marks `fired`. That is the only change to the mailbox; it
   shows on the phone and in Mail as the sent email back at the top of the inbox, unread. It cannot add the "No reply yet" tag, because that
   is Mail's own: when `GET /reminders` shows `fired`, the Mac sets `noReply`/`surfaced` for that message and drops its local follow-up, then `DELETE`s it.
   `replied` or `gone`: drop the local follow-up, `DELETE`. `failed`: the server never fired it, so keep the local follow-up and let Mail do it, then `DELETE` (this is also how Mail learns of a sign-in problem).

### Never twice
- The server fires a reminder once (`pending` -> `firing` -> `fired` is one atomic claim; a second sweep or a retry finds it no longer pending).
- The Mac, when its own timer says a reminder is due, MUST `DELETE /reminders/<id>` FIRST and act only if the answer is `pending`, `none`, `failed` (the server never fired, so Mail must do it
  itself), or the service is unreachable. Answer `fired|replied|gone` (only these three): do nothing more locally except tidy up (set the tag if `fired`). This is the same
  rule as Send Later and stops Mail re-surfacing an email the server already brought back (and the user may have archived since).
- Adding the labels twice is harmless in itself; the risk is only a re-surfaced email after the user archived it, which the DELETE-first rule prevents.
- A reply found but a time edit later: a `replied`/`fired` reminder cannot be edited (409); set a new reminder on the new sent email instead.

## Smart Folders and saved searches (shared by the person's devices)
Names, rules and search words only, never email text. The server keeps the lists exactly as the apps send them (each entry needs a string `id` up to 64 characters and a string `name` up to 200; up to 100 of each; the whole call up to 64 KB). Anything else the app sends, such as the Mac's `folded` list, is not kept.
- `GET /organizer` -> `{"version": n, "smart": [...], "searches": [...]}` (`version` 0 and empty lists until someone saves).
- `PUT /organizer` `{"base_version": n, "smart": [...], "searches": [...]}` (both lists required) -> 200 `{"version": n+1}`. 409 = someone saved first: the body is the current `{"version","smart","searches"}`; merge onto it and try again with its version. 400 = malformed.

## Not here
No snooze, no big-file/Drive attachments (the Mac still refuses those), no email content.
Self-check: `python3 -I -B test_server.py` (pretend Google, no network).
