# gh-tide

A [GitHub CLI](https://cli.github.com/) extension that shows how far a change has flowed: which branches and tags already contain a pull request, a commit, or a path.

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

Requires Node.js 20 or later.

## Usage

```
gh tide pr <number>      # merged PRs use the merge commit; open PRs use the head commit
gh tide commit <sha>
gh tide path <path>      # does the file or directory exist on each stage?
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
- `tag:<regex>`, which picks the tag with the greatest name that matches (works well with date-stamped tags such as `prod-YYYYMMDD-HHMMSS`)
- `release`, the tag of the latest GitHub release

Stages come from `--stages`, then from `git config tide.stages` in the current repository, and finally default to `<default branch>,release`.

```
git config tide.stages "develop,staging,main,tag:^prod-"
```

## How it decides

- Commits and PRs: `GET /repos/{owner}/{repo}/compare/{stage}...{sha}`. The change is on the stage when the status is `identical` or `behind`.
- Paths: `GET /repos/{owner}/{repo}/contents/{path}?ref={stage}`. A 404 means the path is not there.

If a stage was promoted with a squash merge or a cherry-pick, the original commit is not an ancestor of that stage, and `gh tide` reports it as missing. Use `gh tide path` for those flows.

## Development

```
npm test
```

## License

MIT
