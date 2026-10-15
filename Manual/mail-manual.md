---
type: how-to
created: 2026-10-14
author: Noor Calder
status: draft
---

# Audrey Mail: your user manual

Audrey Mail is a Mac email app for Gmail. This manual says what each part does and how to use it. It is also the help inside the app: choose Help, then Audrey Mail Help, or click the question mark at the top right.

## Contents

1. [Getting started](#getting-started)
2. [The inbox](#the-inbox)
3. [Reading an email](#reading-an-email)
4. [Writing and replying](#writing-and-replying)
5. [Send Later](#send-later)
6. [Remind me if no reply](#remind-me-if-no-reply)
7. [Snooze](#snooze)
8. [Link to an email](#link-to-an-email)
9. [Save as note](#save-as-note)
10. [Blocking and sender warnings](#blocking-and-sender-warnings)
11. [Folders and searches](#folders-and-searches)
12. [Searching your mail](#searching-your-mail)
13. [Translate](#translate)
14. [Claude access](#claude-access)
15. [Quick Reply](#quick-reply)
16. [Settings and accounts](#settings-and-accounts)
17. [What works when your Mac is off](#what-works-when-your-mac-is-off)
18. [Keyboard shortcuts](#keyboard-shortcuts)
19. [Using this help](#using-this-help)

## Getting started

### Sign in with Google

1. Open Audrey Mail. If you are signed out, you see an envelope and a **Sign in with Google** button. Click it.
2. Your web browser opens a Google page, and Audrey Mail says "Finish signing in in your browser."
3. Pick your Gmail account.
4. The first time, Google may warn that it has not checked this app. That is expected, because Audrey Mail is a private app that Google has not reviewed. Click **Advanced**, then the link at the bottom that lets you go on to the app (it carries the app's name and the word "unsafe").
5. Google lists what Audrey Mail may do: read and change your mail, send mail, change your Gmail settings, and put files on your Google Drive. Leave everything ticked and click Allow.
6. The browser says you are signed in. Close the tab. Audrey Mail opens your inbox.

You stay signed in. Audrey Mail works with Gmail only.

If sign-in fails:

| What you see | What to do |
| --- | --- |
| "Your Google sign-in expired. Please sign in again." | Click **Sign in with Google** again. |
| "Google did not allow the sign-in" | Try again. If the reason says "timed out", you took more than 5 minutes in the browser. |
| "The Google sign-in file is missing from this Mac." | Audrey Mail cannot sign in without its Google sign-in file. The person who set Audrey Mail up on this Mac has to put it back. |
| "The sign-in reply did not match. Please try again." | Try again, using one browser tab only. |
| "Google did not return a lasting sign-in. Please try again." | Try again and allow everything Google asks. |
| "Could not reach Google" | Check your internet, then try again. You stay signed in meanwhile. |

### Connect Google Drive (for big-file links)

Drive comes with the same Google sign-in. There is no separate button.

1. Open Settings (Command-comma), choose **Accounts**, click **Remove**. Your emails stay with Gmail.
2. Click **Sign in with Google** and go through the steps above again. This time Google also asks about Drive. Allow it.

If you skip this, adding a big file ends with: "Big files need one more Google permission. Open Settings, sign out of Google, and sign in again."

If you signed in for the first time with this version of Audrey Mail, Google already asked about Drive and you do not need to repeat these steps. Audrey Mail uses the Drive permission only for files it puts there itself. Drive also has to be switched on in the Google project that Audrey Mail signs in through. That is a one-time setting on Google's side and Audrey Mail cannot see it, so if big files still fail with a Google error after you allowed Drive, that setting is the thing to check.

## The inbox

The sidebar lists Home, Inbox, Recently Seen, Set Aside, Snoozed, Scheduled, New senders, Blocked, Sent, Drafts, Archive, then your folders. Numbers show what is waiting. The first button in the top bar (or Control-Command-S) hides the sidebar down to icons.

### Smart, Classic and Unread

Three buttons at the top right of the inbox switch the view.

- **Smart** (the default): three tabs above the list, **People**, **Notifications** and **Newsletters**. Each tab shows how many unread emails it holds. Click a tab to see only those.
- **Classic**: everything in one list, newest first.
- **Unread first**: unread emails on top, then the rest.

Audrey Mail puts each email in a tab by itself. If it picks wrong, right-click the email, choose **Move to category**, and pick the right tab. Audrey Mail remembers your choice for that sender.

**Group emails into conversations.** In Settings, Inbox, there is a switch with this name. It is off until you turn it on, and it works in all three views. With it off, nothing changes.

- Emails that are replies to each other show as one row. A small number on the row says how many messages are in the conversation (a single email has no number).
- The row names whoever wrote last, and shows the subject, preview and time of the newest message. It counts as unread if any message in the conversation is unread.
- Open it and the messages are stacked, oldest first. The older ones are folded to one line; click a line to open that message (the one that was open folds). The newest message is open when you start. Messages you wrote yourself show as "You".
- Archive, Snooze, Set Aside, Move to Trash, Pin, Mark read and Add to to-do act on the whole conversation. Reply answers the newest message. Select several rows (see below) and each row means its whole conversation. Your own sent messages in a conversation are left alone.
- In Unread first, a conversation you open stays where it is until you click another email. If a new reply arrives, it goes back up under Unread and the number goes up by one.
- In Settings, Inbox, **Open one message at a time** (on by default, available when grouping is on) decides what opening an older message does: on folds the one already open, off keeps the newest message open beside it.
- This applies to the Inbox only. Sent, Archive, folders and searches stay as they are.

### Keeping the inbox tidy

- **Pin.** Pinned emails stay in a strip at the top. Hover over a row and click the pin, or press P. Pin again to unpin.
- **Set Aside.** Parks an email out of the inbox without deciding on it. Find it under **Set Aside**; **Back to Inbox** returns it.
- **Archive.** Hover icon, A, or the toolbar button. A short **Undo** appears.
- **Swipe.** Slide a row sideways with two fingers on the trackpad. By default right archives and left sets aside. You can change each side in Settings, Swipe.
- **Select several emails.** In the Inbox, hold Command and click to add or remove one email. Hold Shift and click to select everything from the last email you clicked. Command-A selects every email in the list (in Smart, the tab you are on). Selected emails turn grey-blue with a check mark where the picture was; teal is only for the email you have open. With two or more selected, the reading pane says how many and offers Archive, Set Aside, Snooze, Pin, Mark read or unread, Add to to-do, Move to folder, Block senders and Move to Trash, each applied to all of them. One **Undo** brings them all back. The top-bar buttons that need a single email (Reply, Reply all, Forward, Save as note, Link) turn grey. Press Escape, or click one email, to go back to normal.
- **Right-click an email** for Pin, Set Aside, Snooze, Archive, Move to folder, Move to category and more.
- **Recently Seen** lists emails you opened in the last 1 or 2 days (your choice in Settings).
- **Check for new email.** The circular arrow in the top bar checks right now. Audrey Mail also checks by itself (Settings, Inbox).
- **Lists you just left stay put.** Go back to Archive, Sent or a folder within two minutes and it shows at once, without asking Gmail again. The circular arrow (or Check now) reads the open list fresh, and so does any change you make. Gmail limits how fast one person can ask for mail. If you hit the limit, Audrey Mail slows down and waits by itself; if it still cannot get through you see "Gmail is busy right now. Audrey Mail will try again by itself on the next check."
- **Home.** A welcome page with the time and counts. It appears after you have been idle (Settings, Home Screen), or click **Home** in the sidebar. Any click or key takes you back to your mail.

## Reading an email

1. Click an email in the list. It opens beside the list. Several messages on the same subject show as one conversation.
2. **Attachments** show under the email. Click the name to open it.
3. **Reading pane.** The button at the right end of the top bar moves the reading pane beside the list or below it. When it is below, a **Back** arrow (or Escape) returns to the list.
4. **Add note.** Under the subject you can write a private note that only you see. It stays on this Mac.
5. **Print.** Command-P. For a conversation, choose **This email** or **Whole conversation**.
6. **Pictures.** Normal pictures load. Hidden tracking pictures, which tell a sender you opened the email, are always blocked, and the email says how many. If you turn off automatic pictures in Settings, an email shows **Load images** or **Always load from this sender**.
7. **Translate.** If the email is in another language, a **Translate** button appears (see [Translate](#translate)).
8. **Search.** Type in **Search mail** at the top of the sidebar and press Return. Clear the box and press Return to go back (see [Searching your mail](#searching-your-mail)).

## Writing and replying

- **New email:** Command-N, C, or the pencil button.
- **Reply, Reply all, Forward:** the toolbar buttons, or R and F. Reply all adds everyone else from the email to the Cc line, and leaves out your own addresses.
- **To, Cc and Bcc.** Typing in To suggests people from your Contacts and your mail. Use the arrows and Return to pick. Click **Cc** or **Bcc** at the right end of the To line to add that line.
- **From.** Click the From line to send from another of your Gmail addresses.
- **Formatting.** Bold, italic, underline, link, bulleted list, and attach file.
- **Signature.** Added under what you type (Settings, Signatures).
- **Save draft** and **Discard** sit beside **Send**.
- **Undo Send.** After you click Send, an **Undo** button shows for 5, 10, 20 or 30 seconds (your choice in Settings, Sending).
- **Big files.** A file over 20 MB cannot be attached. Audrey Mail offers **Send as link** instead. The file goes to your Google Drive and the email gets a link that anyone with it can open. Audrey Mail removes the file from Drive after 3 days, 7 days (the usual choice), 30 days or Never. Under a sent email, **Delete now** removes it early. This needs the Drive step above, and Audrey Mail must be open at the time it removes the file. A big-file link cannot be combined with Send Later.
- **Add to to-do.** The checklist button or T. Type one line and Audrey Mail shows what it understood. It goes to Obsidian, Apple Reminders, Todoist or ClickUp (Settings, To-do).

## Send Later

Write the email as usual, then click the small arrow beside **Send** and choose **Send later...**. Pick a time from the list, or type one such as "Tuesday 3pm". Audrey Mail shows the date it understood.

- The email waits in your Gmail Drafts, so your phone shows it too.
- **It is sent at the time you chose even if your Mac is off.** Audrey Mail's timing service sends it, usually within a couple of minutes after the time. If your Mac is awake, Audrey Mail sends it on time itself. It is never sent twice.
- See waiting emails under **Scheduled**. Each one has **Send now**, **Change time** and **Keep as draft** (stops the timer and leaves it in Drafts).
- If Audrey Mail says the timing service needs you to sign in again, sign out and back in (Settings, Accounts).
- If the service cannot be reached, Audrey Mail says nothing. It sends the email itself at the time you chose, but only while Audrey Mail is open.
- The timing service only works for Gmail addresses that have been added to its list. If yours is not on the list, the waiting email shows a **Mac must be open** tag in Scheduled. It is still sent at the right time, but only while Audrey Mail is open. The person who runs the service has to add your address first.

## Remind me if no reply

After writing an email, click the small arrow beside **Send** and choose **Remind me if no reply...**. Pick a time.

- If nobody has answered by then, the sent email comes back to the top of your inbox, unread, with a "No reply yet" tag.
- Automatic answers (out-of-office, bounce messages) do not count as a reply. Your own later emails do not count either.
- **It works even when your Mac is off.** Audrey Mail's timing service brings the email back, and your phone shows it too. The "No reply yet" tag itself appears once Audrey Mail is open next. If someone replied, nothing happens.
- It can be combined with Send Later: the reminder counts from when the email is actually sent.
- Same list as Send Later: if your address is not on the timing service's list, the reminder still works, but only while Audrey Mail is open.

## Snooze

Hides an email until the time you pick, then it comes back to the top of the inbox, unread.

1. Click the moon icon, press Z, or right-click and choose **Snooze...**.
2. Pick Later today, This evening, Tomorrow morning, This weekend or Next week, or type a time such as "Tuesday 3pm".
3. See snoozed emails under **Snoozed**, where you can **Bring back now** or **Change time**.

**Audrey Mail must be open for the email to come back on time.** If Audrey Mail was closed, the email comes back when you next open it.

## Link to an email

Makes a link to one email that you can paste into a note, a to-do or a message. Use the link button in the email's header, or right-click the email.

- **Copy link for me.** Opens that email in Audrey Mail on this Mac, even if you archived it. It works only on a Mac with Audrey Mail and your account. If the email has been deleted, Audrey Mail says "That email is no longer in this account."
- **Copy link to share.** Makes a web page with a plain-text copy of the email, and copies its address. Anyone who has the link can read it, with no sign-in. They cannot reply, and attachments and pictures are not included. The link stops working by itself after 30 days. Very long emails are shortened, and Audrey Mail tells you when that happened.
- When you paste, you get a clickable title that starts "Email: ".
- Making a shared link needs an internet connection. If Audrey Mail says it could not make the link, try again later.
- Audrey Mail has no button to switch a shared link off early. It stops by itself after 30 days.
- Shared links use the same service and the same list of addresses as Send Later. If your address is not on the list, Audrey Mail says the sharing service said no.

## Save as note

Saves the open email, or its whole conversation, as a note in your Obsidian vault.

1. Open the email.
2. Click the **Save as note** button in the top bar, or press N.
3. The note appears in your vault's Inbox folder. Its title is the subject without "Fwd:" or "Re:".

Forwarded content is kept. Earlier quoted copies of the same text are dropped, so each message appears once, in order. Signatures are kept. Attachments are not saved.

This needs an Obsidian vault on the Mac. Audrey Mail saves into the folder named **01 Inbox** inside the vault folder you choose in Settings, To-do (under "Vault folder"). If it cannot find that folder, it says "Audrey Mail could not find the Inbox folder in your Obsidian vault."


## Blocking and sender warnings

### New senders

The first email from a stranger waits in **New senders** (a card at the top of the inbox). **Approve** lets them in. **Block** keeps them out. **Approve all** and **Block all** deal with everyone waiting. You can turn this off in Settings, New senders.

A new sender's Approve takes effect once Audrey Mail has seen the email. Until then your phone may still show them.

### Block

Choose **Block this address**, or **Block everyone at** their company. The sender is not told. The block is set in Gmail itself, so it also holds on your phone and when your Mac is off. Their old emails move to **Blocked**. **Unblock** there sends them back. Older block rules in your Gmail that send a sender's mail to Trash (for example ones made earlier in Spark) also appear in the Blocked list, so you can undo them in one place. Unblocking one of those removes the rule; the old emails stay in Trash.

### Unsubscribe

Newsletter emails show an **Unsubscribe** button beside **Block**. Afterwards you choose whether to move their old emails to Blocked.

### Sender warnings

A small amber or red label beside the sender's name:

- **Sender not verified**: Gmail could not confirm the email really came from that sender.
- **Replies go to someone else**: if you reply, it goes to a different address.
- **Name doesn't match address**: the name shown looks like a different person or company than the address.

Click the small "i" next to a label for a plain explanation. A label is a reason to be careful, not proof of a scam.

## Folders and searches

- **Folders** are your Gmail labels. In the sidebar, under **Folders**, click **+** to make one. Type `Parent/Child` to put one inside another. Right-click a folder to **Rename** or **Delete** it (the emails are kept). Drag an email onto a folder, or right-click it and choose **Move to folder**.
- **Smart Folders** fill themselves from rules you set, for example "has an attachment". Click **+** next to Smart Folders and choose to match **all** or **any** of the rules.
- **Saved searches.** After a search, click **Save this search** and name it. It appears in the sidebar for one click next time.
- **Rules** (Settings, Rules) show your Gmail filters as plain sentences. Use **+ New rule** to make one, or right-click an email and choose **Make a rule from this email**. Rules are kept in Gmail, so they also work on your phone and when your Mac is off.

## Searching your mail

Type in **Search mail** at the top of the sidebar and press Return.

### Say it in plain words

Type the search the way you would say it. Examples:

- from Amazon last month
- emails with attachments from Tomas this week
- unread from Priya
- sent to Dana in August

Audrey Mail reads people (**from**, **to**, **sent to**), dates (today, yesterday, this week, last month, last 3 months, in August, August 2025, in 2025), attachments and unread. Small tags under the search bar show what it understood, with the words "Audrey Mail understood this". If a tag is wrong, click it to remove it and Audrey Mail searches again. If Audrey Mail cannot read a phrase, it says "Audrey Mail searched for these words." and searches for the words as you typed them.

Audrey Mail reads your words on your Mac with fixed rules. They do not go to any AI service. Gmail's own search words (such as `from:bob has:attachment`) still work and are sent exactly as typed. A saved search made in plain words is read again each time, so "last month" keeps moving.

### All the way back, with no limit

Search looks through all of your Gmail, as far back as your mail goes (2015 and older too). It does not stop at 80 emails. Scroll to the bottom of the list and the next batch (50 at a time) loads by itself. If it ever pauses, click **Show older emails**. The same is true for Sent, folders, Smart Folders, saved searches, Archive and the inbox.

The notes you wrote under emails (**Add note**) are searched too, so an email can be found by what you wrote about it.

## Translate

When an email is written in a language other than your Mac's languages, a **Translate** button appears in the top bar. It does not appear for short emails, because Audrey Mail cannot be sure of the language from a few words.

1. Open the email and click **Translate**.
2. The email shows in your language, with "Translated from Spanish to English." (or whichever languages apply).
3. Click **Show original** to bring back the real text at any time.

Good to know:

- The email itself is never changed.
- Translation is done by your Mac's own translator. Nothing leaves your Mac, and the translation is not saved to Gmail or shown on your phone.
- The first time you use a language, the Mac may ask to download it. Until it is ready, Audrey Mail says "Audrey Mail could not translate this email. The Mac may still be getting the language ready." Try again in a moment.
- Only the first part of a very long email is translated, and Audrey Mail tells you when that happened.
- It is good for understanding an email and for short replies, not for contracts or anything legal.
- Translate needs macOS 15 or newer. On older Macs the button is not shown.

### Translate what you write

In the writing window, a **Translate to** button sits beside the formatting buttons. The language starts as the language of the email you are answering; the small arrow picks another. Audrey Mail shows the translation in a small box first. Click **Use this** to put it in your email, or **Cancel**. Nothing is swapped without you seeing it. If you change your email after translating, Audrey Mail asks you to translate again instead of replacing your changes. Always read the translation before you use it.

## Claude access

This lets the Claude app on your Mac search and read your mail when you ask it to. It is off until you turn it on.

1. Open Settings (Command-comma) and choose **Claude access**.
2. Turn on **Allow Claude to use my mail**.
3. Quit the Claude app and open it again, once. Claude only sees Audrey Mail after that restart. Audrey Mail reminds you with "On. Quit and reopen the Claude app once so it sees Audrey Mail."

To stop, turn the switch off. Claude can no longer see anything.

What Claude can and cannot do:

- **Read only.** Claude can search and read your mail. It cannot send, delete, archive or change anything. There is no other mode yet.
- **Hidden from Claude.** Blocked senders, Spam and Trash stay hidden. This is the **Never visible to Claude** switch, which is on until you turn it off. It also hides everyone at a company you blocked, including that company's subdomains (for example, blocking everyone at shop.com also hides mail from news.shop.com). If Audrey Mail cannot check what is blocked at that moment, it shows Claude nothing.
- **Recent Claude activity.** The same page lists what Claude looked at, newest first, so you can see it.
- **Audrey Mail must be open.** If Audrey Mail is closed, Claude says Audrey Mail is not open and cannot reach your mail.
- **Limits.** Claude gets at most 25 results per search, and the number of requests per minute is capped.
- **What it means.** Anything Claude reads is sent to the Claude service so it can answer you. That is why it starts off and read only. While the switch is on, other apps on this Mac running under your account could also ask Audrey Mail for your email.

When you turn the switch on, Audrey Mail adds one entry to the Claude app's own settings file. The first time, it keeps a copy of the original beside it. Turning the switch off removes the entry. If Audrey Mail cannot read that file, it leaves it alone and says so.

## Quick Reply

Short answer buttons sit under an open email, such as "Thanks!". Click one to start a reply with that text. You still press Send yourself. To change them, open Settings, **Quick Replies**, where you can edit, remove, add (**Add a Quick Reply**) and drag to reorder. They stay on this Mac.

## Settings and accounts

Open Settings with Command-comma (Audrey Mail's Settings window is the Mac's standard one, so the usual shortcut opens it).

| Page | What it does |
| --- | --- |
| Accounts | Shows the connected Gmail account. **Remove** signs out (your emails stay in Gmail). |
| Signatures | Your signature for new emails. |
| Quick Replies | The short answers under an email. |
| Away message | An automatic out-of-office reply: on or off, first and last day (or "Until I turn it off"), subject, message, and "Only reply to people in my contacts". Gmail sends it even when your Mac is off. A strip at the top of the inbox shows while it is on, with **Turn off**. |
| Rules | Your Gmail filters. |
| Sending | How long you have to change your mind after you press Send. |
| Inbox | How often Audrey Mail checks, and what opens after you archive. |
| Layout | Reading pane position, preview lines, sender pictures, smaller sidebar. |
| Swipe | What each swipe direction does. |
| Menu bar | The small envelope at the top of the screen: what it counts. |
| To-do | Where "Add to to-do" sends tasks, and the vault folder Save as note uses. |
| Keyboard | Turns the single-key shortcuts on or off. |
| Claude access | Lets the Claude app read your mail. Off until you turn it on. |
| Appearance | Light, dark, or follow the Mac. |
| Home Screen | When the welcome page appears. |
| Recently Seen | 1 or 2 days. |
| Default app | **Make this my default email app**. |
| New senders | Turns the Approve or Block check on or off. |
| Privacy | Block hidden tracking pictures, and load normal pictures automatically or choose email by email. |

Other Mac touches: **Command Center** (Command-K) lets you type what you want to do and press Return. The **menu bar envelope** shows a count and the five newest unread emails, and Audrey Mail keeps running when you close its window. The **Share** menu in Safari and Finder starts a new email from a link, text or file (files over 20 MB are skipped).

## What works when your Mac is off

| Feature | With the Mac off |
| --- | --- |
| Send Later | Works. The timing service sends it. |
| Remind me if no reply | Works. The email comes back to your inbox. |
| Away message | Works. Gmail sends the reply. |
| Blocking and Rules | Work. They live in Gmail. |
| Shared links | The web page stays up for 30 days. |
| Snooze | Does not work on time. The email comes back when Audrey Mail is next open. |
| Removing big files from Drive | Happens only while Audrey Mail is open. |
| New sender checks, Approve | Take effect once Audrey Mail has seen the email. |
| Translate | Works. It happens on your Mac, once the language is ready. |
| Claude access | Does not work. Claude can reach your mail only while Audrey Mail is open. |

The Send Later and reminder service needs you to have signed in with the current Audrey Mail. If you sign out and in again, Audrey Mail sets this up again by itself.

## Keyboard shortcuts

Single keys work only with the email list in front, not while writing, and only if **Keyboard shortcuts** is on (Settings, Keyboard).

| Keys | What it does |
| --- | --- |
| Command-N | New email |
| Command-K | Command Center |
| Command-P | Print |
| Command-comma | Settings |
| Command-? | Audrey Mail Help |
| Control-Command-S | Hide or show the sidebar |
| C | New email |
| R | Reply |
| F | Forward |
| N | Save the open email as a note |
| A | Archive |
| S | Set Aside (inbox only) |
| Z | Snooze (inbox only) |
| P | Pin or unpin (inbox only) |
| T | Add to to-do |
| Escape | Back from an email (reading pane below) |
| Any key | Leaves the Home screen |

Reply all has no key; use the toolbar or Command-K.

## Using this help

- **Open it:** Help, then **Audrey Mail Help** (Command-?), or the **?** button at the top right of the inbox, beside the reading pane button.
- **Left side:** the list of sections. Click one to read it.
- **Search:** type in the box at the top. Matching sections are listed as you type, with your words highlighted, and the sections that do not match are dimmed in the list. Click a result to open it. Press Escape to clear the search.
- **Help, Keyboard shortcuts** jumps straight to the shortcuts. **Help, Search help...** puts the cursor in the search box.
- The help is built into Audrey Mail, so it works without the internet. It opens in its own window, so you can keep it beside your mail while you follow the steps.
