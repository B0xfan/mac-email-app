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
  for s in signin signinagain inbox undo undooffline wentout read write leave search savesearch namesearch new block settings mailboxes newfolder smartfolder smartform snoozed snooze pinned returned newsletter unsub folder move blocked blockedsender drafts attach recent aside grouped todo classicview unreadview lines2 settings-end set-accounts set-signatures set-quick set-away set-rules set-rule set-sending set-inbox set-layout set-swipe set-todo set-appearance set-recent set-senders set-privacy set-storage; do
    xcrun simctl terminate "$UDID" $BID >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" $BID -demo $s >/dev/null || rc=1
    case $s in set-*|settings*) sleep 6;; *) sleep 9;; esac
    xcrun simctl io "$UDID" screenshot "$OUT/$s-$mode.png" >/dev/null 2>&1 || rc=1
  done
done
xcrun simctl terminate "$UDID" $BID >/dev/null 2>&1 || true
xcrun simctl shutdown "$UDID" || true
echo "== iPad pictures =="
PAD=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
c=sorted(([int(n) for n in k.split("iOS-")[-1].split("-")],x["name"],x["udid"]) for k,v in d.items() if "iOS" in k for x in v if "iPad Pro" in x["name"] and "13" in x["name"])
print(c[-1][2] if c else "")')   # the newest 13 inch iPad Pro: the size Apple asks for (2064 x 2752)
if [ -z "$PAD" ]; then echo "no iPad simulator"; rc=1; else
  echo "iPad simulator $PAD"
  xcrun simctl boot "$PAD" || true
  xcrun simctl bootstatus "$PAD" -b
  xcrun simctl status_bar "$PAD" override --time 9:41 --batteryState charged --batteryLevel 100 || true
  xcrun simctl install "$PAD" "$APP"
  for mode in light dark; do
    xcrun simctl ui "$PAD" appearance $mode
    for turn in land port; do
      for s in inbox read write folder mailboxes search new settings set-layout; do
        [ $mode = dark ] && case $s in inbox|read) ;; *) continue;; esac   # dark: two screens are enough, the rest is the phone's look
        [ $turn = land ] && [ $s = write ] && continue   # the Write card and keyboard are not drawn turned; the upright picture shows them
        xcrun simctl terminate "$PAD" $BID >/dev/null 2>&1 || true
        if [ $turn = land ]; then xcrun simctl launch "$PAD" $BID -demo $s -landscape >/dev/null || rc=1
        else xcrun simctl launch "$PAD" $BID -demo $s >/dev/null || rc=1; fi
        sleep 9
        xcrun simctl io "$PAD" screenshot "$OUT/ipad-$turn-$s-$mode.png" >/dev/null 2>&1 || rc=1
        [ $turn = land ] && { sips -r 270 "$OUT/ipad-$turn-$s-$mode.png" >/dev/null || rc=1; }   # drawn turned: turn it back
      done
    done
  done
  xcrun simctl terminate "$PAD" $BID >/dev/null 2>&1 || true
  w=$(sips -g pixelWidth "$OUT/ipad-land-inbox-light.png" 2>/dev/null | awk '/pixelWidth/{print $2}')
  [ "$w" = 2752 ] || { echo "the sideways iPad picture is not sideways on a 13 inch iPad (2752 wide, got $w)"; rc=1; }
  xcrun simctl shutdown "$PAD" || true
fi
ls -la "$OUT"
exit $rc
