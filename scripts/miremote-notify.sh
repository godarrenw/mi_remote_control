#!/bin/bash
# MiRemote hook 发信端：把 Claude Code hook 事件转成一行 JSON 发到本地 socket。
# 用法：miremote-notify.sh <waiting_approval|agent_done|agent_needs_input>（hook stdin 喂 JSON）
# 与 Sources/MiRemote/Integrations/ClaudeHooks.swift 内嵌副本同源；改动需同步。
EVENT="${1:-waiting_approval}"
SOCK="$HOME/Library/Application Support/MiRemote/events.sock"
[ -S "$SOCK" ] || exit 0
PAYLOAD=$(/usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(json.dumps({"event": sys.argv[1], "source": "claude-code",
                  "session": d.get("session_id", ""), "cwd": d.get("cwd", ""),
                  "message": d.get("message", "")}))' "$EVENT" 2>/dev/null) || exit 0
printf '%s\n' "$PAYLOAD" | /usr/bin/nc -U -w 1 "$SOCK" >/dev/null 2>&1
exit 0
