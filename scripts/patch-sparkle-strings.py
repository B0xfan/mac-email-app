#!/usr/bin/env python3
"""Rewrites the English wording of Sparkle's windows to the approved Audrey Mail text (no em dashes).
Usage: patch-sparkle-strings.py <Sparkle.framework>. Fails loudly if a line it expects is gone (a new Sparkle version)."""
import plistlib, sys, pathlib

NB = " "
CHANGES = {
    "%@ %@ is now available—you have %@. Would you like to download it now?": "%1$@ %2$@ is ready. You have %3$@.",
    "%@ %@ is now available—you have %@. This is an important update; would you like to download it now?": "%1$@ %2$@ is ready. You have %3$@. This is an important update.",
    "%@ %@ is now available—you have %@. Would you like to learn more about this update on the web?": "%1$@ %2$@ is ready. You have %3$@. Would you like to learn more about it on the web?",
    "A new version of %@ is available!": "A new version of %@ is ready",
    "Install Update": "Install and restart",
    "Install and Relaunch": "Install and restart",
    "Remind Me Later": "Remind me later",
    "Skip This Version": "Skip this version",
    "Cancel Update": "Cancel",
    "You’re up to date!": "You are up to date",
    "%@ %@ is currently the newest version available.": "%1$@ %2$@ is the newest version.",
    "%@ %@ is currently the newest version available.\n(You are currently running version" + NB + "%@.)": "%1$@ %2$@ is the newest version.",
    "Unable to Check For Updates": "Audrey Mail could not check for updates",
    "Update Error!": "The update did not install",
    "The update is improperly signed and could not be validated. Please try again later or contact the app developer.":
        "The new version could not be checked as safe, so Audrey Mail did not install it. Your current version is unchanged. Please tell John.",
}

path = pathlib.Path(sys.argv[1]) / "Versions/B/Resources/Base.lproj/Sparkle.strings"
d = plistlib.loads(path.read_bytes())
missing = [k for k in CHANGES if k not in d]
if missing:
    sys.exit("Sparkle wording changed, update scripts/patch-sparkle-strings.py. Missing: " + "; ".join(missing))
d.update(CHANGES)
bad = [v for v in d.values() if "—" in v]
if bad:
    sys.exit("An em dash is still in Sparkle's English wording: " + bad[0])
path.write_bytes(plistlib.dumps(d, fmt=plistlib.FMT_BINARY))
print("Sparkle wording patched (%d lines)" % len(CHANGES))
