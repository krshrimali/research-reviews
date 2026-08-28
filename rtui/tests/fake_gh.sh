#!/usr/bin/env bash
# Fake `gh` for offline tests. Dispatches on the subcommand / GraphQL operation and emits
# canned JSON matching what src/data/gh.rs parses. If $PRTUI_GH_LOG is set, appends the full
# argv (one space-joined line) so tests can assert the command that was built.
set -euo pipefail

if [ -n "${PRTUI_GH_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$PRTUI_GH_LOG"
fi

all="$*"

case "${1:-}" in
  --version)
    echo "gh version 2.0.0 (fake)"
    ;;

  repo)
    # `gh repo view --json owner,name,url -q '[...] | @tsv'`
    printf 'acme\tprtui\thttps://github.corp.example/acme/prtui\n'
    ;;

  pr)
    case "${2:-}" in
      list)
        cat <<'JSON'
[{"number":42,"title":"Add token refresh","author":{"login":"octocat"},"state":"OPEN","isDraft":false,"updatedAt":"2026-08-20T10:00:00Z","reviewDecision":"REVIEW_REQUIRED","labels":[{"name":"enhancement"}],"headRefName":"feature/x","baseRefName":"main","assignees":[]}]
JSON
        ;;
      view)
        cat <<'JSON'
{"number":42,"title":"Add token refresh","body":"Body text.","author":{"login":"octocat"},"state":"OPEN","updatedAt":"2026-08-20T10:00:00Z","headRefName":"feature/x","baseRefName":"main","headRefOid":"deadbeef","baseRefOid":"cafebabe","isCrossRepository":true,"headRepositoryOwner":{"login":"contributor"},"headRepository":{"name":"prtui-fork","url":"https://github.corp.example/contributor/prtui-fork"},"labels":[{"name":"enhancement"}],"assignees":[],"reviewRequests":[{"login":"hubber"}],"reviews":[{"author":{"login":"hubber"},"state":"APPROVED","submittedAt":"2026-08-21T14:30:00Z","body":"LGTM"}],"reviewDecision":"APPROVED","statusCheckRollup":[{"name":"build","state":"SUCCESS"}]}
JSON
        ;;
      merge|close|reopen|ready|edit)
        # pr_command: success, no stdout needed.
        echo "ok"
        ;;
      *)
        echo "unknown pr subcommand: ${2:-}" >&2; exit 1;;
    esac
    ;;

  api)
    if printf '%s' "$all" | grep -q '/reviews'; then
      # submit_review: consume the JSON payload on stdin, return a created-review object.
      cat >/dev/null
      echo '{"id":12345,"state":"COMMENTED","body":"review"}'
    elif printf '%s' "$all" | grep -q 'addPullRequestReviewThreadReply'; then
      echo '{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"RC_new123"}}}}'
    elif printf '%s' "$all" | grep -qE 'resolveReviewThread|unresolveReviewThread'; then
      echo '{"data":{"resolveReviewThread":{"thread":{"id":"T1","isResolved":true}}}}'
    elif printf '%s' "$all" | grep -q 'addReaction'; then
      echo '{"data":{"addReaction":{"reaction":{"content":"THUMBS_UP"}}}}'
    elif printf '%s' "$all" | grep -q 'reviewThreads'; then
      cat <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
  {"id":"T1","isResolved":false,"isOutdated":false,"path":"src/auth.lua","line":2,"originalLine":2,"diffSide":"RIGHT","comments":{"nodes":[
    {"id":"C1","author":{"login":"octocat"},"body":"nit","createdAt":"2026-08-19T09:00:00Z","path":"src/auth.lua","originalLine":2,"line":2}
  ]}},
  {"id":"T2","isResolved":true,"isOutdated":true,"path":"src/auth.lua","line":1,"originalLine":1,"diffSide":"RIGHT","comments":{"nodes":[
    {"id":"C2","author":{"login":"hubber"},"body":"was here","createdAt":"2026-08-18T08:00:00Z","path":"src/auth.lua","originalLine":1,"line":1}
  ]}}
]}}}}}
JSON
    else
      echo '{"data":{}}'
    fi
    ;;

  *)
    echo "unknown gh command: ${1:-}" >&2; exit 1;;
esac
