# Fiducia client agent instructions

These instructions apply to this repository and every directory beneath it.

## Skill routing

Load only the skill that matches the task:

- For selecting or adding a Fiducia SDK to an application, read
  [`agents/skills/integrate-fiducia-client/SKILL.md`](agents/skills/integrate-fiducia-client/SKILL.md).
- For modifying generated clients, templates, contracts, tests, or package
  behavior, read
  [`agents/skills/maintain-fiducia-clients/SKILL.md`](agents/skills/maintain-fiducia-clients/SKILL.md).

Treat each skill as additional instructions, not a replacement for this file.

## Branch and worktree policy

- Work directly on the `main` branch for now.
- Before making changes, confirm that `main` is checked out.
- Do not create or use feature branches or Git worktrees.
- Merge any existing non-`main` branch into `main` with an intent-preserving
  merge, resolve conflicts semantically, and continue on `main`.
- Push completed work to `origin/main`.
- Preserve existing uncommitted work and stop for operator guidance if moving
  to `main` cannot be done safely.

## GitHub and Linear coordination

- GitHub organization: `fiducia-cloud`
- Linear workspace/team: `denman` / `Denman` (`DEN`)
- Linear team ID: `eb8ab169-5afe-4b6f-9cab-3f2aa3e887dc`
- Linear project: `github.com/fiducia-cloud`
- Linear project ID: `d9e89bd3-19da-47f3-9bf7-6dc8cc910b70`
- Linear project URL:
  `https://linear.app/denman/project/githubcomfiducia-cloud-8fd5e1bec9d3`

Reuse a suitable issue in that project for issue-backed work instead of
creating duplicates. Keep repository links, acceptance criteria, validation,
status, and blockers current when Linear coordination is part of the task.
Never commit Linear or GitHub credentials.

## Syncing with the remote

"Sync with the remote" is a two-way exchange: pull the remote commits and push
the local commits. A clean tree alone is not synchronized; local and remote must
hold the same commits.

When the operator asks to sync the whole organization or all repositories, this
repository is only one member of that larger audit. Do not claim organization
completion merely because this checkout is synchronized.

1. Commit the intended work so the tree is clean.
2. Run `git fetch --all --prune`.
3. Run `git pull` or merge the upstream branch.
4. Run `git push`.

Integrate with `git merge` or `git pull`; avoid git rebase in favor of git merge.
Never discard unrelated or uncommitted user work.

## Repository-local Git worktrees

- Create or use a Git worktree only when the human operator explicitly authorizes it for the current task. Concurrency or a dirty checkout is not permission by itself.
- Put every authorized worktree at `<repository-root>/tmp/worktrees/<name>`; from the repository root, use `./tmp/worktrees/<name>`. Never place worktrees beside repositories or organization directories.
- Keep `tmp`, `temp`, `tmp/worktrees`, and `temp/worktrees` ignored in the repository-root `.gitignore`. Do not commit files from those directories.
- Relocate or remove a worktree only when the operator explicitly requests it. Before removal, preserve and publish intended changes, verify its commit is represented on the target branch, and confirm there are no tracked, untracked, ignored-sensitive, or in-use files that must survive. Remove it with `git worktree remove <path>` without `--force`; never delete a worktree directory with `rm`.
