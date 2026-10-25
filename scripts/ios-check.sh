#!/bin/zsh
# Runs on GitHub (macOS runner), never on John's Mac: starts the iPhone app in the simulator on the pretend Gmail,
# runs its built-in checks, and takes a picture of each screen in light and dark. Usage: ios-check.sh <built .app> <picture folder>
set -u
APP="$1"; OUT="$2"; mkdir -p "$OUT"
[ -d "$APP" ] || { echo "no .app found"; exit 1; }
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
c=[x for k,v in d.items() if "iOS" in k for x in v if "iPhone" in x["name"]]
pick=[x for x in c if "16 Pro" in x["name"] and "Max" not in x["name"]] or c
print(pick[0]["udid"])')
echo "simulator $UDID"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 || true
xcrun simctl install "$UDID" "$APP"
BID=com.johnhesch.audreymail
rc=0
echo "== built-in checks =="
for try in 1 2; do
  perl -e 'alarm 420; exec @ARGV' xcrun simctl launch --console --terminate-running-process "$UDID" $BID -selftest > "$OUT/selftest.txt" 2>&1 || true
  cat "$OUT/selftest.txt"
  grep -q "^DONE" "$OUT/selftest.txt" && break
  echo "-- the checks did not finish (try $try); crash reports:"
  ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i audrey | head -3
  for f in $(ls -t ~/Library/Logs/DiagnosticReports/AudreyMail* 2>/dev/null | head -1); do head -c 3000 "$f"; done
done
grep -q "^DONE failures=0" "$OUT/selftest.txt" || rc=1
for mode in light dark; do
  xcrun simctl ui "$UDID" appearance $mode
  for s in signin signinagain inbox undo undooffline wentout read write leave search savesearch namesearch new block settings mailboxes newfolder smartfolder smartform snoozed pinned returned newsletter folder move blocked blockedsender drafts attach recent aside grouped todo classicview unreadview lines2 settings-end set-accounts set-signatures set-quick set-away set-rules set-rule set-sending set-inbox set-layout set-swipe set-todo set-appearance set-recent set-senders set-privacy set-storage; do
    xcrun simctl terminate "$UDID" $BID >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" $BID -demo $s >/dev/null || rc=1
    case $s in set-*|settings*) sleep 6;; *) sleep 9;; esac
    xcrun simctl io "$UDID" screenshot "$OUT/$s-$mode.png" >/dev/null 2>&1 || rc=1
  done
done
xcrun simctl terminate "$UDID" $BID >/dev/null 2>&1 || true
ls -la "$OUT"
exit $rc
