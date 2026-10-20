#!/bin/sh
# Hibermate standalone uninstaller. It works even if the app is broken or
# already deleted.
#
#   sh uninstall.sh            # asks before each step that needs your password
#   sh uninstall.sh --yes      # no questions (sudo may still ask for a password)
#
# What it does:
#   1. Quits Hibermate.
#   2. Restores your original sleep setting, if a hold was active
#      (the root helper stores it in /Library/Application Support/Hibermate).
#   3. Stops and removes the privileged helper.
#   4. Removes Hibermate's hook entries from every AI tool's settings
#      (each changed file is backed up next to it first).
#   5. Deletes ~/Library/Application Support/Hibermate and Hibermate's preferences.
#   6. Optionally moves /Applications/Hibermate.app to the Trash.
set -u

LABEL="com.sr7d3v.hibermate.helper"
APP="/Applications/Hibermate.app"
USER_DIR="$HOME/Library/Application Support/Hibermate"
ROOT_DIR="/Library/Application Support/Hibermate"
STATE="$ROOT_DIR/helper-state.json"
ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

ask() {
    [ "$ASSUME_YES" = 1 ] && return 0
    printf '%s [y/N] ' "$1"
    read -r answer
    case "$answer" in [yY]*) return 0 ;; *) return 1 ;; esac
}

sleep_disabled_now() {
    # Read from the IORegistry; the key is absent when never changed.
    if /usr/sbin/ioreg -r -n IOPMrootDomain -d1 -k SleepDisabled | /usr/bin/grep -q '"SleepDisabled" = Yes'; then
        echo 1
    else
        echo 0
    fi
}

echo "== Hibermate uninstaller =="

# 1. Quit the app. Quitting releases any hold cleanly.
if /usr/bin/pgrep -xq Hibermate; then
    echo "Quitting Hibermate…"
    /usr/bin/osascript -e 'tell application "Hibermate" to quit' >/dev/null 2>&1
    i=0
    while /usr/bin/pgrep -xq Hibermate && [ $i -lt 10 ]; do /bin/sleep 1; i=$((i + 1)); done
    /usr/bin/pkill -x Hibermate 2>/dev/null
fi

# 2. Restore the original sleep setting if the helper recorded a hold.
if [ -f "$STATE" ]; then
    ORIGINAL=$(/usr/bin/plutil -extract originalSleepDisabled raw -o - "$STATE" 2>/dev/null)
    case "$ORIGINAL" in true|1) VALUE=1 ;; *) VALUE=0 ;; esac
    echo "A hold was active. Restoring your original setting: sudo pmset -a disablesleep $VALUE"
    if ask "Run it now?"; then
        /usr/bin/sudo /usr/bin/pmset -a disablesleep "$VALUE" && /usr/bin/sudo /bin/rm -f "$STATE"
    fi
fi

# 3. Stop the helper. Booting it out sends SIGTERM, and the helper restores on SIGTERM too.
if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1 || [ -d "$ROOT_DIR" ]; then
    echo "Removing the helper: sudo launchctl bootout system/$LABEL; sudo rm -rf \"$ROOT_DIR\""
    if ask "Run it now?"; then
        /usr/bin/sudo /bin/launchctl bootout "system/$LABEL" 2>/dev/null
        /usr/bin/sudo /bin/rm -rf "$ROOT_DIR"
    fi
fi

# 4. Remove hook entries from every tool, using the hook binary (it shares
#    the exact file list the app uses), or the copy inside the app.
HOOK=""
for candidate in "$USER_DIR/hooks/hibermate-hook" "$APP/Contents/MacOS/hibermate-hook"; do
    if [ -x "$candidate" ]; then HOOK="$candidate"; break; fi
done
if [ -n "$HOOK" ]; then
    "$HOOK" --uninstall-integrations
else
    echo "Couldn't find hibermate-hook. If you enabled integrations, remove entries containing"
    echo "'Application Support/Hibermate/hooks/hibermate-hook' from: ~/.claude/settings.json,"
    echo "~/.codex/hooks.json, ~/.gemini/settings.json, ~/.qwen/settings.json, ~/.cursor/hooks.json;"
    echo "and delete ~/.copilot/hooks/hibermate.json and ~/.config/opencode/plugins/hibermate.js."
    echo "(Leftover entries are harmless: they exit silently when Hibermate is gone.)"
fi

# 5. Delete Hibermate's own data and preferences.
if [ -d "$USER_DIR" ]; then
    /bin/rm -rf "$USER_DIR" && echo "Deleted $USER_DIR"
fi
if /usr/bin/defaults read com.sr7d3v.hibermate >/dev/null 2>&1; then
    /usr/bin/defaults delete com.sr7d3v.hibermate && echo "Deleted Hibermate's preferences"
fi

# 6. The app itself.
if [ -d "$APP" ] && ask "Move $APP to the Trash?"; then
    /usr/bin/osascript -e "tell application \"Finder\" to delete POSIX file \"$APP\"" >/dev/null 2>&1 \
        && echo "Moved Hibermate.app to the Trash"
fi

echo
echo "SleepDisabled is now: $(sleep_disabled_now)  (0 = normal sleep)"
echo "Check with: pmset -g | grep -i sleepdisabled   (no output or 0 means normal)"
echo "Done."
