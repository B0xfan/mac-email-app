# Installing Audrey Mail (for James)

Audrey Mail is a Gmail app for the Mac. It needs a Mac with macOS 14 (Sonoma) or newer.

## 1. Download and install

1. Download the file `AudreyMail-notarized.zip` that John sent you.
2. Double-click it. A file called **Audrey Mail** appears.
3. Drag **Audrey Mail** into your **Applications** folder.

## 2. Open it the first time

1. Open **Audrey Mail** from Applications.
2. The Mac may say it was downloaded from the internet and ask "Are you sure you want to open it?". Click **Open**. This is normal. Apple has checked the app and found no problems.
3. If the Mac says it cannot check the app, tell John. Do not go around the message.

## 3. Add the Google sign-in file (once)

John will send you a small file named `google_client.json`. It lets Audrey Mail talk to Google. It holds no password and no mail.

1. In Finder, choose **Go > Go to Folder** and paste: `~/Library/Application Support/Audrey Mail`
2. If the folder is not there, open Audrey Mail once and close it, then try again. If it is still missing, create a folder with that exact name.
3. Drop `google_client.json` into that folder.

## 4. Sign in with Google

1. In Audrey Mail, click **Sign in with Google**. Your web browser opens.
2. Pick your Gmail account (jameshesch@gmail.com).
3. Google shows a warning: **"Google hasn't verified this app"**. This is expected. It appears because Audrey Mail is a private app that has not been through Google's public review. Click **Advanced**, then **Go to Audrey Mail (unsafe)**.
4. Google lists what Audrey Mail may do. Tick every box and click **Continue**. If you leave one off, that feature will not work:
   - Read, write and organize your Gmail (so you can read mail, move it, and archive it).
   - Send email as you (so you can reply and send).
   - Manage your Gmail filters and labels (so blocking a sender works in Gmail itself, and also on your phone).
   - See and manage only the files Audrey Mail itself puts on your Google Drive (used for sending big files as a link). It cannot see your other Drive files.
5. The browser says you can close the tab. Go back to Audrey Mail; your mail loads.

Your sign-in is kept in a private file on your Mac. It is not sent anywhere except to Google.

## 5. Other questions Audrey Mail may ask

Each of these appears only when you use the feature that needs it. You can say No and carry on.

- **Contacts**: to suggest people while you type in the To field, and to show their photos.
- **Reminders**: only if you choose Apple Reminders as your to-do list. It only adds new reminders.

## If something goes wrong

- "Your Google sign-in expired": click **Sign in with Google** again.
- Anything else: tell John what you saw on the screen.
