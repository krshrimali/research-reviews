"""GitHub access via the `gh` CLI (argv-style)."""

from __future__ import annotations

import json

from . import proc


def available() -> bool:
    return proc.run(["gh", "--version"])[0]


def owner_repo(cwd: str | None = None) -> tuple[str | None, str | None]:
    ok, out, _ = proc.run(
        ["gh", "repo", "view", "--json", "owner,name",
         "-q", '.owner.login + "/" + .name'],
        cwd=cwd,
    )
    if not ok:
        return None, None
    slug = out.strip()
    if "/" in slug:
        owner, repo = slug.split("/", 1)
        return owner, repo
    return None, None


def list_prs(search: str = "", limit: int = 100, state: str | None = None,
             cwd: str | None = None) -> list[dict]:
    argv = [
        "gh", "pr", "list", "--json",
        "number,title,author,state,isDraft,updatedAt,headRefName,baseRefName,labels,reviewDecision",
        "--limit", str(limit),
    ]
    if state:
        argv += ["--state", state]
    if search:
        argv += ["--search", search]
    ok, out, _ = proc.run(argv, cwd=cwd)
    if not ok:
        return []
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return []


def pr_view(number: int, cwd: str | None = None) -> dict | None:
    fields = ("number,title,body,author,state,isDraft,updatedAt,createdAt,"
              "headRefName,baseRefName,headRefOid,baseRefOid,labels,assignees,"
              "reviewRequests,reviews,reviewDecision,statusCheckRollup,commits,files,mergeable")
    ok, out, _ = proc.run(["gh", "pr", "view", str(number), "--json", fields], cwd=cwd)
    if not ok:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


_THREADS_QUERY = """
query($owner:String!, $repo:String!, $number:Int!) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      reviewThreads(first:100) { nodes {
        id isResolved isOutdated path line originalLine diffSide
        comments(first:100) { nodes {
          id databaseId author { login } body createdAt path originalLine line diffHunk
        } }
      } }
    }
  }
}"""


def review_threads(owner: str, repo: str, number: int,
                   cwd: str | None = None) -> list[dict]:
    argv = ["gh", "api", "graphql", "-f", f"query={_THREADS_QUERY}",
            "-f", f"owner={owner}", "-f", f"repo={repo}", "-F", f"number={number}"]
    ok, out, _ = proc.run(argv, cwd=cwd)
    if not ok:
        return []
    try:
        data = json.loads(out)
        return data["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]
    except (json.JSONDecodeError, KeyError, TypeError):
        return []
