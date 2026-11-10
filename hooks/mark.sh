#!/bin/bash
# Claude Code hook helper. Usage: mark.sh set|clear   (hook JSON on stdin)
# set   -> ~/.claude/clauderr/<session_id>.waiting   (Notification hook)
# clear -> remove it                                  (UserPromptSubmit/Stop/PostToolUse)
dir="$HOME/.claude/clauderr"
id=$(sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' | head -n1)
[ -z "$id" ] && exit 0
mkdir -p "$dir"
case "$1" in
  set)   : > "$dir/$id.waiting" ;;
  clear) rm -f "$dir/$id.waiting" ;;
esac
exit 0
