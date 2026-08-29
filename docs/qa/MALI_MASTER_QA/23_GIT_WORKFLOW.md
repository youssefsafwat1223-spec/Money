# 23 — Git Workflow

Related: [01_GLOBAL_RULES.md](01_GLOBAL_RULES.md) Rule 10, [22_CODING_STANDARDS.md](22_CODING_STANDARDS.md), [00_SYSTEM_PROMPT.md](00_SYSTEM_PROMPT.md).

## 1. Branching

- `main` is the primary/release branch.
- Feature work happens on descriptively-named branches (e.g., `feat/accounts-multicurrency`), not directly on `main`.
- Branch names describe the feature/fix, not the author or the date.

## 2. Commit discipline

- **Never commit without explicit, current instruction to do so** — a prior approval to commit does not carry forward to later, unrelated changes in the same session ([01_GLOBAL_RULES.md](01_GLOBAL_RULES.md) Rule 10).
- Prefer creating a **new commit** over amending an existing one, unless explicitly asked to amend. This matters especially when a pre-commit hook fails: the failing attempt did not produce a commit, so `--amend` at that point would rewrite the *previous* (different) commit rather than fixing the current attempt — fix the issue, re-stage, and create a new commit instead.
- Never use `--no-verify`, `--no-gpg-sign`, or any other hook/signing bypass unless explicitly instructed.
- Stage specific files by name; avoid `git add -A`/`git add .` in an automated/agent context, since it can sweep in unrelated untracked files (secrets, generated artifacts, stray scratch files) that were never part of the task.
- Commit messages focus on **why**, not a restatement of the diff — 1–2 sentences is usually sufficient.

## 3. Never do these without explicit instruction

- `git push --force` (especially to `main`/`master`).
- `git reset --hard`.
- `git checkout .` / `git restore .` / `git clean -f` (discards uncommitted work).
- `git branch -D` (force branch deletion).
- Rewriting published history in any form.

If one of these seems like the fastest way to resolve a problem (a messy working tree, a stuck merge), stop and confirm with the user first — the cost of asking is low; the cost of destroyed uncommitted work is not recoverable.

## 4. Pull requests

- PR title under ~70 characters; details go in the body, not a long title.
- PR description includes: summary (bullet points, why not just what), and a test plan (checklist of what was verified, mirroring [20_FINAL_REPORT_TEMPLATE.md](20_FINAL_REPORT_TEMPLATE.md) §6/§8 in miniature).
- Every PR touching the notification/capture pipeline links the relevant [18_REGRESSION.md](18_REGRESSION.md) entries if it fixes or risks a known regression class.
- Every PR touching schema/flags links the specific migration file(s) and states the flag rollout state explicitly (see [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md) §6).

## 5. Handling merge conflicts

- Resolve conflicts by understanding both sides' intent, not by mechanically picking "ours" or "theirs" — a conflict in financial logic (e.g., transfer-accounting rules) requires understanding *why* both sides changed that code before merging them correctly.
- Never discard a side of a conflict to "make it compile" without understanding what that side was for — if genuinely unsure, ask rather than guess on financial-logic code.

## 6. Handling an unfamiliar working-tree state

If you encounter unexpected files, branches, or uncommitted changes when starting work:

- Investigate before deleting or overwriting — it may be another person's (or your own earlier session's) in-progress work.
- If a lock file exists, investigate what process holds it rather than deleting it.
- Prefer resolving over discarding (e.g., resolve a merge conflict rather than `git checkout --ours`/`--theirs` wholesale, restore rather than `clean -f` an unfamiliar untracked file whose origin is unclear).

## 7. AI-agent-specific notes

When an AI agent creates a commit on the user's behalf (only when explicitly instructed), the commit message includes standard attribution trailers per the tool's configured convention. This is a transparency mechanism, not a formality to skip — it lets a future reader distinguish human-authored from agent-authored commits at a glance, which matters for this project's audit trail given the heavy AI-agent involvement described in [02_PROJECT_DISCOVERY.md](02_PROJECT_DISCOVERY.md) §8.
