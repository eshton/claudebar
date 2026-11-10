#!/bin/bash
# Claude Code PermissionRequest hook. Hands the prompt to ClaudeBar so you can approve/deny from the
# menu bar or a notification. If ClaudeBar isn't running, or nobody answers in time, print nothing and
# exit 0: Claude Code then shows its normal terminal prompt.
#
# Mailbox: ~/.claude/clauderr/permissions/<id>.json (payload, written here)
#          ~/.claude/clauderr/permissions/<id>.decision ("allow" | "deny", written by ClaudeBar)
# <id> ends in this script's pid so the app can tell when the request is dead.
WAIT_SECONDS=300

pgrep -xq ClaudeBar || exit 0

dir="$HOME/.claude/clauderr/permissions"
mkdir -p "$dir" || exit 0
id="$(date +%s)$RANDOM-$$"
trap 'rm -f "$dir/$id.json" "$dir/$id.json.tmp" "$dir/$id.decision" "$dir/$id.decision.tmp"' EXIT

cat > "$dir/$id.json.tmp" || exit 0
mv "$dir/$id.json.tmp" "$dir/$id.json" || exit 0

emit() {
  printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"%s"}}}\n' "$1"
}

end=$((SECONDS + WAIT_SECONDS))
while [ $SECONDS -lt $end ]; do
  if [ -f "$dir/$id.decision" ]; then
    case "$(head -c 16 "$dir/$id.decision")" in
      allow) emit allow; exit 0 ;;
      deny)  emit deny;  exit 0 ;;
    esac
    exit 0
  fi
  pgrep -xq ClaudeBar || exit 0     # app quit while waiting: fall back to the terminal prompt
  sleep 0.3
done
exit 0
