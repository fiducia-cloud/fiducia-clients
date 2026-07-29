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

## Syncing with the remote

"Sync with the remote" is a two-way exchange: pull the remote commits and push
the local commits. A clean tree alone is not synchronized; local and remote must
hold the same commits.

1. Commit the intended work so the tree is clean.
2. Run `git fetch --all --prune`.
3. Run `git pull` or merge the upstream branch.
4. Run `git push`.

Integrate with `git merge` or `git pull`; avoid git rebase in favor of git merge.
Never discard unrelated or uncommitted user work.
