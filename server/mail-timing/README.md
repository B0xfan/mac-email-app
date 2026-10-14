# Mail timing service (Send Later while the Mac is off)

Runs on the droplet (`audrey-server`) as `mail-timing.service`, code in `/opt/PKA-John/mail-timing/`, behind
`https://audreypka.com/api/mail-timing/`. It holds a Gmail DRAFT id and a send time per job, plus each user's Google refresh token (needed to send; stored in
the database, owner-only file modes, service runs as a non-root user). The email itself stays in Gmail.

## What the Mac does
1. Once per install: `POST /register` `{"refresh_token": "<the Mac's Google refresh token>"}` -> `{"api_key","email"}`.
   Store `api_key` in the same private file as the sign-in. Signing in again gives a new key (the old one stops).
   400 = body missing/invalid or no refresh token; 403 = address not on the list; 503 = Google unreachable (retry).
2. Every request after: header `Authorization: Bearer <api_key>`. 401 = key wrong or replaced: register again.
3. Schedule or change time: create/keep the Gmail draft as today, then `PUT /jobs/<draftId>` `{"send_at": <unix seconds>}`.
   Same call edits the time. 200 `{"status":"pending"}`. 409 `{"status":"sending|sent|gone"}` = too late to change, treat as sent.
   400 = bad time (not more than 1 hour in the past, not more than 400 days ahead). 429 = 200 scheduled already.
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

## Not here
No reminders, no big-file/Drive attachments (the Mac still refuses those), no email content.
Self-check: `python3 -I test_server.py` (pretend Google, no network).
