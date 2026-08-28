#!/usr/bin/env bash
# Fake `claude` for tests: ignores argv flags, reads the prompt from stdin, extracts
# the first comment_id and the Head SHA, and emits canned stream-json ending in a
# findings block that replies to that comment and adds one new comment.
set -euo pipefail

prompt="$(cat)"

# `|| true` so a no-match grep doesn't abort under `set -e -o pipefail` (happens when
# there are no existing threads to reply to).
comment_id="$(printf '%s\n' "$prompt" | grep -oE 'comment_id: [0-9a-f-]+' | head -1 | awk '{print $2}' || true)"
head_sha="$(printf '%s\n' "$prompt" | grep -oE 'Head SHA: [0-9a-f]+' | head -1 | awk '{print $3}' || true)"

printf '%s\n' '{"type":"system","session_id":"fake-session"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"reviewing the diff"}]}}'

# Detect a follow-up: the prompt already contains a reply line ("↳") under a thread.
followup=0
if printf '%s' "$prompt" | grep -q '↳'; then followup=1; fi

# Build the findings JSON. On a follow-up, respond to the new discussion (different
# reply, no new findings, softer verdict); on the first pass, reply + add a finding.
if [ -n "${comment_id:-}" ]; then
  if [ "$followup" = "1" ]; then
    replies="[{\"comment_id\":\"${comment_id}\",\"reply\":\"Good point on staleness — cache with a 60s TTL and refresh on 401. That addresses it.\"}]"
  else
    replies="[{\"comment_id\":\"${comment_id}\",\"reply\":\"I agree, this rename improves clarity.\"}]"
  fi
else
  replies="[]"
fi

if [ "$followup" = "1" ]; then
  new_comments="[]"
  verdict="comment"
  summary="Follow-up: your replies address the earlier concern."
else
  new_comments="[{\"file\":\"src/auth.lua\",\"line_start\":2,\"line_end\":2,\"side\":\"RIGHT\",\"body\":\"Consider caching the refreshed token.\"}]"
  verdict="request_changes"
  summary="One issue found."
fi

findings="{\"reviewed_head_sha\":\"${head_sha:-unknown}\",\"verdict\":\"${verdict}\",\"summary\":\"${summary}\",\"thread_replies\":${replies},\"new_comments\":${new_comments},\"resolved\":[],\"commits\":[]}"

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
