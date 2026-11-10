#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs kit: install a built game app into /Applications.
#   install-app.sh <built .app> <rollback folder> [--copy-to <project folder>]
# The app already in /Applications moves to <rollback folder>/<name>-YYYYMMDD-HHMMSS.app.noindex (the two newest
# are kept, older ones go to the Trash); the new one is cloned in and its signature checked; a Desktop alias is
# made once; with --copy-to, the project's copy of the app is replaced by a clone of the installed one (contract
# v2.3 rule 7: everything in the work folder).
#
# This version was written on 2026-11-08 for the Soldier of Fortune port.
set -euo pipefail
SRC=${1:?built app}; ROLLBACK=${2:?rollback folder}; shift 2
COPY_TO=""
while [ $# -gt 0 ]; do case "$1" in --copy-to) COPY_TO=${2:?folder}; shift 2;; *) echo "unknown option $1" >&2; exit 2;; esac; done
[ -d "$SRC" ] || { echo "no app at $SRC" >&2; exit 1; }
NAME=$(basename "$SRC" .app)
DEST="/Applications/$NAME.app"
STAMP=$(date +%Y%m%d-%H%M%S)

to_trash() { # path: into the Trash under a free name
  local base t; base=$(basename "$1"); t="$HOME/.Trash/$base"
  [ -e "$t" ] && t="$HOME/.Trash/${base%.*} $STAMP.${base##*.}"
  mv "$1" "$t"
}

codesign --verify --deep --strict "$SRC" || { echo "$SRC: signature not valid, not installed" >&2; exit 1; }

if [ -d "$DEST" ]; then
  mkdir -p "$ROLLBACK"
  KEPT="$ROLLBACK/$NAME-$STAMP.app.noindex"
  mv "$DEST" "$KEPT"
  echo "previous app kept at $KEPT"
  OLD=()
  while IFS= read -r f; do OLD+=("$f"); done < <(ls -1d "$ROLLBACK/$NAME-"*.app.noindex 2>/dev/null | sort -r | tail -n +3)
  if [ ${#OLD[@]} -gt 0 ]; then
    echo "older rollbacks moving to the Trash in the background"
    ( for f in "${OLD[@]}"; do to_trash "$f"; done ) >/dev/null 2>&1 &
  fi
fi

cp -c -R "$SRC" "$DEST"
codesign --verify --deep --strict "$DEST" && echo "installed $DEST (signature ok)"

if [ ! -e "$HOME/Desktop/$NAME" ]; then
  osascript -e "tell application \"Finder\" to make alias file to (POSIX file \"$DEST\") at (path to desktop folder)" \
    >/dev/null 2>&1 && echo "Desktop alias added" || echo "Desktop alias not made (Finder automation not allowed)"
fi

if [ -n "$COPY_TO" ]; then
  if [ -d "$COPY_TO/$NAME.app" ]; then
    to_trash "$COPY_TO/$NAME.app"
    echo "previous project copy moved to Trash"
  fi
  cp -c -R "$DEST" "$COPY_TO/"
  echo "copy of the app in the project folder: $COPY_TO/$NAME.app"
fi
