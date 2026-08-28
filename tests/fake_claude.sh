#!/usr/bin/env bash
# Fake `claude` for tests: ignores argv flags, reads the prompt from stdin, extracts
# the first comment_id and the Head SHA, and emits canned stream-json ending in a
# findings block that replies to that comment and adds one new comment.
set -euo pipefail

prompt="$(cat)"

comment_id="$(printf '%s\n' "$prompt" | grep -oE 'comment_id: [0-9a-f-]+' | head -1 | awk '{print $2}')"
head_sha="$(printf '%s\n' "$prompt" | grep -oE 'Head SHA: [0-9a-f]+' | head -1 | awk '{print $3}')"

printf '%s\n' '{"type":"system","session_id":"fake-session"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"reviewing the diff"}]}}'

# Build the findings JSON. If there was an existing comment, reply to it.
if [ -n "${comment_id:-}" ]; then
  replies="[{\"comment_id\":\"${comment_id}\",\"reply\":\"I agree, this rename improves clarity.\"}]"
else
  replies="[]"
fi

findings="{\"reviewed_head_sha\":\"${head_sha:-unknown}\",\"verdict\":\"request_changes\",\"summary\":\"One issue found.\",\"thread_replies\":${replies},\"new_comments\":[{\"file\":\"src/auth.lua\",\"line_start\":2,\"line_end\":2,\"side\":\"RIGHT\",\"body\":\"Consider caching the refreshed token.\"}],\"resolved\":[],\"commits\":[]}"

# The result field carries the assistant's final text with a fenced json block.
result_text="Here is my review.

\`\`\`json
${findings}
\`\`\`"

# Emit the result event as a single JSON line (encode result_text safely via python).
python3 - "$result_text" <<'PY'
import json, sys
print(json.dumps({"type":"result","result":sys.argv[1],"is_error":False,"session_id":"fake-session"}))
PY
