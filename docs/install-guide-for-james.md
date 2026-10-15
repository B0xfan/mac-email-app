# How to install Audrey Mail

Audrey Mail is a Gmail app for the Mac. This is a private copy from John, so the Mac will ask you to confirm a couple of things. That is normal and takes about five minutes.

## 1. Check your Mac

Audrey Mail needs a Mac made in 2020 or later (an "Apple silicon" Mac) with macOS 14 (Sonoma) or newer.

1. Click the Apple menu (top left of the screen) and choose **About This Mac**.
2. Look at **Chip**. If it says M1, M2, M3 or a higher number, you are fine.
3. If it says **Intel**, Audrey Mail will not run on this Mac. Tell John.
4. Also check the macOS version on that screen. It should be 14 or higher.

## 2. Install it

1. Double-click **Audrey Mail.zip**. An app called **Audrey Mail** appears next to it.
2. Drag **Audrey Mail** into your **Applications** folder.

## 3. Open it the first time (the Mac will block it once)

Apple has not reviewed this private app, so the Mac blocks it the first time. You tell the Mac you trust it, once.

1. Open **Audrey Mail** from Applications. The Mac shows a message that it could not verify the app. Click **Done** (do not click Move to Bin).
2. Click the Apple menu, then **System Settings**, then **Privacy & Security** in the left list.
3. Scroll down to the **Security** section. You will see a line saying "Audrey Mail" was blocked, with a button **Open Anyway**. Click it.
4. Type your Mac password (or use Touch ID) and click **Open Anyway** again if it asks.

After this, Audrey Mail opens normally every time.

## 4. Add the Google sign-in file (once)

John gave you a small file named **google_client.json**. It lets Audrey Mail talk to Google. It holds none of your mail and none of your passwords.

1. In Finder, click **Go** in the top menu, then **Go to Folder**. Paste this and press Return: `~/Library/Application Support`
2. In that window, make a new folder named exactly **Audrey Mail** (File, then New Folder). If a folder with that name already exists, use it.
3. Drag **google_client.json** into the **Audrey Mail** folder.

If Audrey Mail was already open, quit it (Audrey Mail menu, then Quit) and open it again.

## 5. Sign in with Google

1. In Audrey Mail, click **Sign in with Google**. Your web browser opens.
2. Pick your Gmail account.
3. Google shows a warning: **"Google hasn't verified this app"**. This is expected, because Audrey Mail is a private app that has not been through Google's public review. Click **Advanced**, then **Go to Audrey Mail (unsafe)**.
4. Google lists what Audrey Mail may do. Tick every box and click **Continue**. If you leave one off, that feature will not work:
   - Read, write and organize your Gmail (read mail, move it, archive it).
   - Send email as you (reply and send).
   - Manage your Gmail filters and labels (so blocking a sender works in Gmail itself, and also on your phone).
   - See and manage only the files Audrey Mail itself puts on your Google Drive (used for sending big files as a link). It cannot see your other Drive files.
5. The browser says you can close the tab. Go back to Audrey Mail. Your mail loads.

Your sign-in is kept in a private file on your Mac. It is not sent anywhere except to Google.

## 6. Other questions Audrey Mail may ask

These appear only when you use the feature that needs them. You can say No and carry on.

- **Contacts**: to suggest people while you type in the To field, and to show their photos.
- **Reminders**: only if you choose Apple Reminders as your to-do list. It only adds new reminders.

## If something goes wrong

- "Your Google sign-in expired": click **Sign in with Google** again.
- The Open Anyway button is not there: try opening Audrey Mail once more, then go back to Privacy & Security. The button shows for about an hour after a blocked attempt.
- Anything else: tell John what you saw on the screen.
