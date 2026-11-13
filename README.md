# gh-tide

A [GitHub CLI](https://cli.github.com/) extension that shows how far a change has flowed: which branches and tags already contain a pull request, a commit, or a path, and which open pull requests are stuck before the first stage.

```
$ gh tide pr 1234 --stages develop,staging,main,tag:^prod-
owner/repo  PR #1234 merged: Add retry to the webhook handler
✓  develop
✓  staging
✗  main
✗  tag:^prod-  (prod-20260101-120000)
```

It answers questions like "is this fix on staging yet?" or "did the last production release include it?" without cloning the repository. Everything goes through `gh api`, so it works with whatever `gh` is logged in to, including private repositories.

## Install

```
gh extension install ogijun/gh-tide
```

Requires Ruby 4.0 or later.

## Usage

```
gh tide pr <number>      # merged PRs use the merge commit; open PRs use the head commit
gh tide commit <sha>
gh tide path <path>      # does the file or directory exist on each stage?
gh tide stuck            # open PRs that are not merged yet, grouped by why (see below)
```

Options:

| Option | Meaning |
|---|---|
| `-R, --repo owner/repo` | Target repository (default: the current one) |
| `--stages <list>` | Comma-separated stages, in promotion order |
| `--workflows` | Also list workflows that are not active (for example `disabled_manually`) |
| `--json` | JSON output |

## Stages

A stage is one of:

- a branch name, such as `develop` or `main`
- `tag:<regex>`, which picks the tag with the greatest name that matches (works well with date-stamped tags such as `prod-YYYYMMDD-HHMMSS`; only the first 1,000 tags are read)
- `release`, the tag of the latest GitHub release

Stages come from `--stages`, then from `git config tide.stages` in the current repository, and finally default to `<default branch>,release`.

```
git config tide.stages "develop,staging,main,tag:^prod-"
```

## How it decides

- Commits and PRs: `GET /repos/{owner}/{repo}/compare/{stage}...{sha}`. The change is on the stage when the status is `identical` or `behind`.
- Paths: `GET /repos/{owner}/{repo}/contents/{path}?ref={stage}`. A 404 means the path is not there.

A stage whose branch or tag does not exist shows `?`.

If a stage was promoted with a squash merge or a cherry-pick, the original commit is not an ancestor of that stage, and `gh tide` reports it as missing. Use `gh tide path` for those flows.

## Stuck pull requests

`gh tide stuck` looks at the other end of the flow: open pull requests that have not been merged yet, grouped by why they are stuck.

```
$ gh tide stuck
6 open PRs by @me, drafts excluded

  conflict        1
  ci-failing      1
  re-review       1
  waiting-review  2
  ready-to-merge  1

conflict (1) — update the branch and resolve the conflicts
  acme/web#88  41d old, idle 12d     Move the settings page to the new layout
      with main; also waiting-review

ci-failing (1) — fix or re-run the failing checks
  acme/api#130  6d old, idle 2d      Validate the token audience
      failing: test (3); also waiting-review

re-review (1) — commits were added after the approval; ask for another look
  acme/api#127  9d old, idle 1d      Add retry to the webhook handler
      approved at 1a2b3c4, 2 commits since

waiting-review (2) — no approval yet
  acme/api#121  15d old, idle 15d    Report every failure in a test shard
      no reviewer requested
  acme/api#131  2d old, idle 2d      Split the export job
      requested: alice, backend; also stacked on #130

ready-to-merge (1) — approved, green, no conflicts; only the merge is left
  acme/infra#12  3d old, idle 1d     Add the parameter for the new secret
      approved by bob
```

Each section lists the oldest PRs first. "idle" is the time since the last commit, comment, or review by a person.

```
gh tide stuck [--author <login>] [--owner <owner> | -R <owner/repo>] [--min-age <duration>]
              [--merged-unreleased [--since <duration>] [--stages <list>]] [--json]
```

| Option | Meaning |
|---|---|
| `--author <login>` | Whose PRs (default: `@me`) |
| `--owner <owner>` | Only repositories of this user or organization |
| `-R, --repo owner/repo` | Only this repository. Unlike the other subcommands, the default is every repository, not the current one |
| `--min-age <duration>` | Only PRs opened at least this long ago: `12h`, `3d`, `2w` |
| `--merged-unreleased` | Also list PRs merged in the last `--since` (default `30d`) that have not reached the last stage |
| `--stages <list>` | Stages for `--merged-unreleased` (see [Stages](#stages)); applies to every repository |
| `--json` | JSON output |

### Reasons

A PR gets every reason that applies. The first one, in this order, is the section it is listed under; the rest are shown after "also".

| Reason | When |
|---|---|
| `conflict` | `mergeable` is `CONFLICTING` or `mergeStateStatus` is `DIRTY` |
| `ci-failing` | A check on the head commit failed or was cancelled. If any check is required, only required checks count |
| `changes-requested` | `reviewDecision` is `CHANGES_REQUESTED` (or, without branch protection, a reviewer's latest review requests changes) |
| `awaiting-reply` | The last comment by a person is from someone other than the author: a PR comment, a review comment, or an unresolved review thread. Bots are ignored, and an approval, including the inline comments left with it, needs no reply |
| `re-review` | Approved, but the approved commit is not the head: commits other than merges were added after it, or it is no longer on the branch |
| `waiting-review` | No approval yet. Shows the requested reviewers, or that nobody was asked |
| `stacked` | The base branch is not the default branch. Shows the parent PR when an open PR in the same repository has that branch as its head |
| `ci-pending` | Checks are still running and nothing else applies |
| `ready-to-merge` | Approved, CI green, no conflicts, based on the default branch |

CI is judged the way [gh-tally](https://github.com/ogijun/gh-tally) does: for each workflow and event only the newest run counts, so a failure that a later run fixed is not a failure, and a cancelled run of a workflow that succeeded on the same commit (two runs started at once, one cancelled by concurrency) only looks red. When a job is re-run, its newest attempt counts.

GitHub often reports mergeability as `UNKNOWN` right after many merges; `gh tide stuck` asks once more before giving up (the PR is then listed under `unknown`). Requests that fail with a server error are retried once, and a PR that still cannot be read is reported at the end without hiding the others.

### Merged but not released

`--merged-unreleased` adds a section of merged PRs whose merge commit is not yet on the last stage, checked the same way as `gh tide pr`. The stages come from `--stages`, then `git config tide.stages` when the PR's repository is the current one, and otherwise `<default branch>,release`. Repositories where the last stage cannot be resolved (for example, no release yet) are listed as skipped.

## Development

```
ruby -Ilib test/tide_test.rb
ruby -Ilib test/stuck_test.rb
```

## License

MIT
