-- review.nvim :: thin GitHub client over the `gh` CLI (argv, shell=false).
-- We call `gh api graphql`/`gh pr` directly rather than depending on octo (R3).

local proc = require("review.util.proc")

local M = {}

--- True if the gh CLI is available.
---@return boolean
function M.available()
  return vim.fn.executable(vim.env.PRTUI_GH_BIN or "gh") == 1
end

--- Run a GraphQL query. `vars` is a map of name->string (gh -F/-f). Returns decoded
--- data table or nil, err.
---@param query string
---@param vars table<string,string|integer>|nil
---@param cwd string|nil
---@return table|nil data, string|nil err
function M.graphql(query, vars, cwd)
  local argv = { vim.env.PRTUI_GH_BIN or "gh", "api", "graphql", "-f", "query=" .. query }
  for k, v in pairs(vars or {}) do
    if type(v) == "number" then
      table.insert(argv, "-F")
      table.insert(argv, string.format("%s=%d", k, v))
    else
      table.insert(argv, "-f")
      table.insert(argv, string.format("%s=%s", k, v))
    end
  end
  local ok, out, err = proc.run(argv, { cwd = cwd })
  if not ok then
    return nil, M.error_message(out, err)
  end
  local decoded_ok, decoded = pcall(vim.json.decode, out)
  if not decoded_ok then
    return nil, "gh graphql: bad JSON"
  end
  -- GraphQL reports failures with HTTP 200 and an `errors` array, so a successful
  -- exit code says nothing about whether the mutation actually happened.
  if type(decoded.errors) == "table" and #decoded.errors > 0 then
    local messages = {}
    for _, entry in ipairs(decoded.errors) do
      messages[#messages + 1] = type(entry) == "table" and (entry.message or vim.inspect(entry))
        or tostring(entry)
    end
    return nil, table.concat(messages, "; ")
  end
  return decoded.data, nil
end

--- owner, repo for the cwd's `origin`. Returns nil on failure.
---@param cwd string|nil
---@return string|nil owner, string|nil repo
function M.owner_repo(cwd)
  local identity = M.repo_identity(cwd)
  return identity and identity.owner, identity and identity.repo
end

---@param cwd string|nil
---@return table|nil identity {host,owner,repo,url}
function M.repo_identity(cwd)
  local ok, out = proc.run(
    { vim.env.PRTUI_GH_BIN or "gh", "repo", "view", "--json", "owner,name,url", "-q", "[.owner.login,.name,.url] | @tsv" },
    { cwd = cwd }
  )
  if not ok then
    return nil
  end
  local owner, repo, url = out:gsub("%s+$", ""):match("^([^\t]+)\t([^\t]+)\t(.+)$")
  if not owner or not url then return nil end
  return {
    owner = owner,
    repo = repo,
    host = url:match("^https?://([^/]+)"),
    url = url:gsub("/$", "") .. ".git",
  }
end

function M.list_prs_args(opts)
  opts = opts or {}
  local argv = {
    "pr", "list",
    "--json", "number,title,author,state,isDraft,updatedAt,headRefName,baseRefName,labels,reviewDecision",
    "--limit", tostring(opts.limit or 100),
  }
  if opts.state then vim.list_extend(argv, { "--state", opts.state }) end
  if opts.search and opts.search ~= "" then vim.list_extend(argv, { "--search", opts.search }) end
  return argv
end

--- List PRs (with optional search query). Returns a list of light PR records.
---@param opts table|nil { search=string, limit=integer, state=string }
---@param cwd string|nil
---@return table[] prs, string|nil err
function M.list_prs(opts, cwd)
  opts = opts or {}
  local argv = { vim.env.PRTUI_GH_BIN or "gh" }
  vim.list_extend(argv, M.list_prs_args(opts))
  local ok, out, err = proc.run(argv, { cwd = cwd })
  if not ok then
    return {}, err
  end
  local decoded_ok, prs = pcall(vim.json.decode, out)
  if not decoded_ok then
    return {}, "gh pr list: bad JSON"
  end
  return prs, nil
end

--- Full detail for one PR number.
---@param number integer
---@param cwd string|nil
---@return table|nil pr, string|nil err
function M.pr_view(number, cwd)
  local fields = "id,number,title,body,author,state,isDraft,updatedAt,createdAt,"
    .. "headRefName,baseRefName,headRefOid,baseRefOid,labels,assignees,"
    .. "headRepository,headRepositoryOwner,isCrossRepository,reviewRequests,reviews,"
    .. "reviewDecision,statusCheckRollup,commits,files,mergeable,comments"
  local ok, out, err = proc.run(
    { vim.env.PRTUI_GH_BIN or "gh", "pr", "view", tostring(number), "--json", fields },
    { cwd = cwd }
  )
  if not ok then
    return nil, err
  end
  local decoded_ok, pr = pcall(vim.json.decode, out)
  if not decoded_ok then
    return nil, "gh pr view: bad JSON"
  end
  return pr, nil
end

-- GraphQL to fetch review threads (comments, positions, resolution, suggestions live
-- inside comment bodies as ```suggestion blocks — no dedicated field, per R3).
local THREADS_QUERY = [[
query($owner:String!, $repo:String!, $number:Int!, $cursor:String) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      reviewThreads(first:100, after:$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated path line originalLine diffSide
          comments(first:100) {
            nodes {
              id databaseId author { login } body createdAt
              path originalLine line diffHunk
              reactionGroups { content users { totalCount } }
            }
          }
        }
      }
    }
  }
}]]

--- Fetch review threads for a PR. Returns normalized list, or {}, err.
---@param owner string
---@param repo string
---@param number integer
---@param cwd string|nil
---@return table[] threads, string|nil err
function M.review_threads(owner, repo, number, cwd)
  local all, cursor = {}, ""
  while true do
    local vars = { owner = owner, repo = repo, number = number }
    if cursor ~= "" then vars.cursor = cursor end
    local data, err = M.graphql(THREADS_QUERY, vars, cwd)
    if not data then return all, err end
    local ok, connection = pcall(function() return data.repository.pullRequest.reviewThreads end)
    if not ok or not connection then return all, "unexpected threads shape" end
    vim.list_extend(all, connection.nodes or {})
    if not connection.pageInfo or not connection.pageInfo.hasNextPage then break end
    cursor = connection.pageInfo.endCursor
  end
  return all, nil
end

function M.reply_thread(thread_id, body, cwd)
  local q = [[mutation($thread:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$thread,body:$body}){comment{id}}}]]
  local data, err = M.graphql(q, { thread = thread_id, body = body }, cwd)
  return data and data.addPullRequestReviewThreadReply.comment.id or nil, err
end

function M.resolve_thread(thread_id, resolved, cwd)
  local name = resolved and "resolveReviewThread" or "unresolveReviewThread"
  local q = string.format("mutation($thread:ID!){%s(input:{threadId:$thread}){thread{id isResolved}}}", name)
  local data, err = M.graphql(q, { thread = thread_id }, cwd)
  return data ~= nil, err
end

--- Pull the human-readable reason out of a GitHub error response.
---
--- `gh` prints the status line to stderr ("Unprocessable Entity (HTTP 422)") and the
--- body — which is where GitHub explains *why* — to stdout. Reporting only stderr
--- turned "Can not request changes on your own pull request" into a bare 422.
---@param body string
---@param fallback string
---@return string
function M.error_message(body, fallback)
  local ok, decoded = pcall(vim.json.decode, body or "")
  if not ok or type(decoded) ~= "table" then
    return vim.trim(fallback or "") ~= "" and vim.trim(fallback) or "GitHub rejected the request"
  end
  local parts = {}
  for _, entry in ipairs(decoded.errors or {}) do
    if type(entry) == "string" then
      parts[#parts + 1] = entry
    elseif type(entry) == "table" then
      parts[#parts + 1] = entry.message or entry.field or vim.inspect(entry)
    end
  end
  if #parts > 0 then
    return table.concat(parts, "; ")
  end
  if type(decoded.message) == "string" then
    return decoded.message
  end
  return vim.trim(fallback or "")
end

function M.submit_review(owner, repo, number, payload, cwd)
  local path = string.format("repos/%s/%s/pulls/%d/reviews", owner, repo, number)
  local ok, out, err = proc.run({ vim.env.PRTUI_GH_BIN or "gh", "api", path,
    "--method", "POST", "--input", "-" }, { cwd = cwd, stdin = vim.json.encode(payload) })
  if not ok then return nil, M.error_message(out, err) end
  local decoded, value = pcall(vim.json.decode, out)
  if not decoded then
    return nil, "bad GitHub response"
  end
  return value, nil
end

--- The login of the authenticated user, cached for the session.
---@param cwd string|nil
---@return string|nil
function M.viewer(cwd)
  if M._viewer ~= nil then
    return M._viewer ~= false and M._viewer or nil
  end
  local ok, out = proc.run({ vim.env.PRTUI_GH_BIN or "gh", "api", "user", "-q", ".login" }, { cwd = cwd })
  M._viewer = ok and vim.trim(out) ~= "" and vim.trim(out) or false
  return M._viewer ~= false and M._viewer or nil
end

--- Every inline review comment on a PR, across pages.
---@param owner string
---@param repo string
---@param number integer
---@param cwd string|nil
---@return table[] comments, string|nil err
function M.list_review_comments(owner, repo, number, cwd)
  local path = string.format("repos/%s/%s/pulls/%d/comments", owner, repo, number)
  local ok, out, err = proc.run({ vim.env.PRTUI_GH_BIN or "gh", "api", "--paginate", path },
    { cwd = cwd })
  if not ok then return {}, M.error_message(out, err) end
  local decoded_ok, decoded = pcall(vim.json.decode, out)
  if not decoded_ok or not vim.islist(decoded) then
    return {}, "gh: unexpected review-comment response"
  end
  return decoded, nil
end

--- True when the message describes GitHub throttling rather than a real rejection.
---@param message string|nil
---@return boolean
function M.is_rate_limited(message)
  message = tostring(message or ""):lower()
  return message:find("secondary rate limit", 1, true) ~= nil
    or message:find("api rate limit exceeded", 1, true) ~= nil
    or message:find("abuse detection", 1, true) ~= nil
end

-- A single REST review carrying dozens of comments is rejected by GitHub with an
-- opaque 500. The GraphQL flow below builds the same review incrementally — start a
-- PENDING review, add one thread at a time, then submit — which is what GitHub's own
-- web UI does and what large reviews therefore have to use.

--- Start a pending (unsubmitted) review. Returns its node id.
---@param pr_id string  PR node id
---@param cwd string|nil
---@return string|nil id, string|nil err
function M.start_pending_review(pr_id, cwd)
  local q = [[mutation($pr:ID!){addPullRequestReview(input:{pullRequestId:$pr}){pullRequestReview{id}}}]]
  local data, err = M.graphql(q, { pr = pr_id }, cwd)
  if not data then return nil, err end
  local ok, id = pcall(function() return data.addPullRequestReview.pullRequestReview.id end)
  if not ok or not id then
    return nil, "unexpected pending-review response"
  end
  return id, nil
end

--- Add one inline thread to a pending review.
---@param review_id string
---@param comment table { path, body, line, start_line?, side }
---@param cwd string|nil
---@return boolean ok, string|nil err
function M.add_pending_thread(review_id, comment, cwd)
  local vars = {
    review = review_id,
    path = comment.path,
    body = comment.body,
    line = comment.line,
    side = comment.side or "RIGHT",
  }
  local decl = "$review:ID!,$path:String!,$body:String!,$line:Int!,$side:DiffSide!"
  local args = "pullRequestReviewId:$review,path:$path,body:$body,line:$line,side:$side"
  if comment.start_line and comment.start_line < comment.line then
    vars.start_line = comment.start_line
    decl = decl .. ",$start_line:Int!"
    args = args .. ",startLine:$start_line,startSide:$side"
  end
  local q = string.format(
    "mutation(%s){addPullRequestReviewThread(input:{%s}){thread{id}}}", decl, args)
  local data, err = M.graphql(q, vars, cwd)
  return data ~= nil, err
end

--- Submit a pending review with a verdict and body.
---@param review_id string
---@param event string  COMMENT|APPROVE|REQUEST_CHANGES
---@param body string
---@param cwd string|nil
---@return boolean ok, string|nil err
function M.submit_pending_review(review_id, event, body, cwd)
  local q = [[mutation($review:ID!,$event:PullRequestReviewEvent!,$body:String!){
    submitPullRequestReview(input:{pullRequestReviewId:$review,event:$event,body:$body}){
      pullRequestReview{ id state }
    }
  }]]
  local data, err = M.graphql(q, { review = review_id, event = event, body = body }, cwd)
  return data ~= nil, err
end

--- Throw away a pending review that could not be completed, so a failed publish does
--- not strand an invisible draft review on the PR.
---@param review_id string
---@param cwd string|nil
---@return boolean
function M.discard_pending_review(review_id, cwd)
  local q = [[mutation($review:ID!){deletePullRequestReview(input:{pullRequestReviewId:$review}){clientMutationId}}]]
  local data = M.graphql(q, { review = review_id }, cwd)
  return data ~= nil
end

function M.react(subject_id, content, add, cwd)
  local field = add == false and "removeReaction" or "addReaction"
  local q = string.format("mutation($id:ID!,$content:ReactionContent!){%s(input:{subjectId:$id,content:$content}){reaction{content}}}", field)
  local data, err = M.graphql(q, { id = subject_id, content = content }, cwd)
  return data ~= nil, err
end

return M
