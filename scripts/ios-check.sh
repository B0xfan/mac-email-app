#!/bin/zsh
# Runs on GitHub (macOS runner), never on John's Mac: starts the iPhone app in the simulator on the pretend Gmail,
# runs its built-in checks, and takes a picture of each screen in light and dark. Usage: ios-check.sh <built .app> <picture folder>
set -u
APP="$1"; OUT="$2"; mkdir -p "$OUT"
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
timeout 180 xcrun simctl launch --console --terminate-running-process "$UDID" $BID -selftest > "$OUT/selftest.txt" 2>&1 || true
cat "$OUT/selftest.txt"
grep -q "^DONE failures=0" "$OUT/selftest.txt" || rc=1
for mode in light dark; do
  xcrun simctl ui "$UDID" appearance $mode
  for s in signin signinagain inbox read write search new block settings; do
    xcrun simctl terminate "$UDID" $BID >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" $BID -demo $s >/dev/null
    sleep 7
    xcrun simctl io "$UDID" screenshot "$OUT/$s-$mode.png" >/dev/null 2>&1 || rc=1
  done
done
xcrun simctl terminate "$UDID" $BID >/dev/null 2>&1 || true
ls -la "$OUT"
exit $rc
