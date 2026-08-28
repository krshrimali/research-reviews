-- review.nvim :: thin GitHub client over the `gh` CLI (argv, shell=false).
-- We call `gh api graphql`/`gh pr` directly rather than depending on octo (R3).

local proc = require("review.util.proc")

local M = {}

--- True if the gh CLI is available.
---@return boolean
function M.available()
  return (proc.run({ vim.env.PRTUI_GH_BIN or "gh", "--version" }))
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
    return nil, err
  end
  local decoded_ok, decoded = pcall(vim.json.decode, out)
  if not decoded_ok then
    return nil, "gh graphql: bad JSON"
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

--- List open PRs (with optional search query). Returns a list of light PR records.
---@param opts table|nil { search=string, limit=integer, state=string }
---@param cwd string|nil
---@return table[] prs, string|nil err
function M.list_prs(opts, cwd)
  opts = opts or {}
  local argv = {
    vim.env.PRTUI_GH_BIN or "gh", "pr", "list",
    "--json", "number,title,author,state,isDraft,updatedAt,headRefName,baseRefName,labels,reviewDecision",
    "--limit", tostring(opts.limit or 100),
  }
  if opts.state then
    vim.list_extend(argv, { "--state", opts.state })
  end
  if opts.search and opts.search ~= "" then
    vim.list_extend(argv, { "--search", opts.search })
  end
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
  local fields = "number,title,body,author,state,isDraft,updatedAt,createdAt,"
    .. "headRefName,baseRefName,headRefOid,baseRefOid,labels,assignees,"
    .. "headRepository,headRepositoryOwner,isCrossRepository,reviewRequests,reviews,"
    .. "reviewDecision,statusCheckRollup,commits,files,mergeable"
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

return M
