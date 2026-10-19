---
name: ship
description: Ship the current work for Macolima. `/ship` commits, pushes and opens a pull request. `/ship install` (after the PR is merged) pulls the latest main and runs `make install`.
argument-hint: "[install]"
disable-model-invocation: true
---

# Ship

Two modes, picked by the argument. The user typing `/ship` is the authorization to commit, push and open a PR for **this invocation only**; nothing here authorizes force-pushing, pushing to `main`, or merging.

- No argument → **Ship** (commit, push, PR).
- `install` → **Install** (latest main, `make install`).

Repo: `https://github.com/aldidas/macolima` (remote `origin`), base branch `main`. Use `gh` for GitHub.

---

## Ship (no argument)

1. **Branch check.** `git branch --show-current`. If it is `main` (or detached), do not commit there: create a branch named after the work (`feat/<slug>`, `fix/<slug>`, `chore/<slug>`) from the current state and continue on it. Never push `main`.
2. **Look before staging.** Run `git status --short` and `git diff --stat`. Never stage build output or scratch: `build/`, `.build/`, `Macolima.xcodeproj/`, `.superpowers/`, `.DS_Store`, `xcuserdata/`. If any such path is already tracked (`git ls-files | grep -E '(^|/)(\.build|build|\.superpowers)/'`), stop and tell the user instead of shipping it (remove it with `git rm -r --cached` and extend `.gitignore` if the user agrees).
3. **Test.** Run `make test`. If it fails, report the failures and stop; shipping waits for green. Report the `Executed N tests` line.
4. **Commit.** Stage the relevant files by name (not `git add -A` blindly) and commit with a conventional message (`feat:`, `fix:`, `chore:`, `docs:`, optional scope such as `feat(kit):`), matching the existing history. If the tree is already clean and the branch has commits ahead of `main`, skip to push. End the message with the attribution line the harness gives for commits. Never `--amend` or rewrite commits that are already pushed.
5. **Push.** `git push -u origin <branch>`. If rejected, the remote moved: investigate (`git fetch`, look at the divergence) and ask; never force-push.
6. **Pull request.** If `gh pr view` shows an open PR for the branch, the push already updated it: report its URL and stop. Otherwise `gh pr create --base main --head <branch>` with:
   - a title under 70 characters in the same conventional style;
   - a body with **Summary** (what and why, 2–4 bullets), **Test plan** (the `make test` result, plus anything verified by hand and anything not verified), and any **deferred / known issues** the user should know;
   - the pull-request attribution line the harness gives, at the end of the body.
7. **Report** the PR URL, the commit list, and the test result. Remind the user that after merging they can run `/ship install`.

---

## Install (`/ship install`)

Run this after the PR is merged on GitHub.

1. **Clean tree required.** `git status --short` must be empty. If not, stop and say what is uncommitted; do not stash, reset or discard anything.
2. **Latest main.** `git fetch origin`, `git checkout main`, `git pull --ff-only origin main`. If the fast-forward fails, stop and report; never merge or reset to force it.
3. **Confirm the merge landed.** Show `git log --oneline -5`. If the user's PR branch is still not in `main` (`git branch --no-merged main` lists it), say the PR does not look merged yet and ask before continuing.
4. **Test, then install.** Run `make test`; if it fails, stop. Then `make install` (Release build, ad-hoc signed, backs up the old app once as `Macolima.previous.app`, installs to `/Applications/Macolima.app`, relaunches). Check that `pgrep -x Macolima` finds the running app and report the installed commit (`git rev-parse --short HEAD`).
5. **Tidy (ask first).** Offer to delete the merged local branch (`git branch -d <branch>`, safe delete only) and to prune the remote-tracking ref (`git fetch --prune`). Do these only if the user says yes.

---

## Never

- Force-push, push to `main`, merge a PR, or rewrite pushed history.
- Skip `make test`, or ship on a red suite.
- Commit secrets, build output, or `.superpowers/` scratch.
- Stage with a blind `git add -A` when `git status` shows files you did not look at.
