# Agent Rules — Homelab Workspace

Source: adapted from zulhardy/infrastructure-agents-guide
(Ch 5 Credential Management, Ch 7 Change Control, Ch 8 Policy & Guardrails, Ch 13 Risk Framework).

These rules are the *prompt-level* layer. The guide treats this layer as the weakest one,
so each rule is also enforced structurally where possible (see "Enforced by").

## Purpose

- This repo is the **homelab workspace**: 3 Ubuntu VMs on Hyper-V (ops01, prd01, dev01), code on GitHub
  (PUBLIC repo), GitHub Actions self-hosted runner on ops01. It stays at home.
- The homelab is used to **author and test a group capstone project** (a web app with a database,
  hosted on Azure). The homelab is NOT the capstone project.
- The capstone project lives in a **separate repository** (name not decided yet): GitHub for now,
  Azure DevOps later, running on temporary Azure resources. Its rules (including Azure/Terraform rules)
  belong in that repository's own CLAUDE.md, not here.
- Do not put capstone project code in this repo.

## Autonomy level

- Level 1: PROPOSE. The agent writes code and opens pull requests. The repo owner merges.
- The agent never merges, deploys, or runs commands on the VMs.

## Hard rules — NEVER violate these

1. NEVER push directly to `main`. ALWAYS create a new branch per change.
   - Enforced by: GitHub branch protection on `main` (PR + passing checks required).
2. NEVER run commands on the VMs or the Hyper-V host. Changes reach the VMs only through
   merged PRs executed by the runner, or through steps the repo owner runs.
   - Enforced by: the agent holds no SSH keys, passwords, or runner tokens.
3. NEVER merge or approve a pull request, or change branch protection or repository settings.
   - Enforced by: the scope of the GitHub token the agent is given (branch protection alone does not block a merge).
4. NEVER store, request, print, or commit credentials (SSH private keys, passwords, runner tokens,
   PATs, `.env` files with secrets). The repo owner enters every secret.
   - Enforced by: `.gitignore`; secret scanning / push protection on the repo.
5. The self-hosted runner (ops01) may ONLY be used by workflows triggered by `push` to `main`
   or `workflow_dispatch`. NEVER target it from `pull_request` or `pull_request_target` workflows.
   PR checks run on GitHub-hosted runners.
   - Enforced by: repo setting "Require approval for all outside collaborators" for fork PR workflows.
6. NEVER commit anything that should not be public: secrets, real passwords, personal data.
7. NEVER modify files outside `ansible/`, `apps/`, `scripts/`, `docs/`, and `.github/workflows/`
   (workflow changes require an explicit request from the repo owner).
8. NEVER open a ready-for-review PR until lint checks have run. If they don't pass after
   10 iterations, open a DRAFT PR titled `[not converged]` and NEVER describe it as a fix.
9. Anything irreversible — deleting data, volumes, VMs, users, or keys — is done by the repo owner.
10. When something is unclear, STOP and ask. Fail safe, not fail open.

## Every pull request must include

- Summary: what changed and why
- Changes: list of files
- Validation: lint / syntax-check results
- Impact: which VM(s) are affected and what will change on them
- Anything destructive, called out explicitly at the top

## Lab conventions

- ops01 (192.168.0.102): control node: Ansible, self-hosted runner, OpenBao, k3s control plane.
  No app pods.
- prd01 (192.168.0.103): k3s agent for PRD apps.
- dev01 (192.168.0.104): k3s agent for DEV apps (e.g. the capstone project's app and database for testing).
- Image builds, tests and scans run on GitHub-hosted runners, not on the VMs. Docker is not installed on the VMs.
- Pipeline logic lives in `scripts/`; workflow YAML stays thin.
- Pin versions (runner version + checksum, action commit SHAs). No `latest`.
- Branch naming: `feat/<short-name>`, `fix/<short-name>`, `chore/<short-name>`

## Skills, MCP servers, and third-party code

- Vendor-official sources only, pinned to a version or commit hash.
- Review files before installing. Nothing that fetches remote URLs at runtime or asks for static keys.

## Emergency stop

- The repo owner disables GitHub Actions for the repo and/or stops the runner service on ops01
  (`sudo systemctl stop 'actions.runner.*'`).
- Test this once before the first real project.

## Behavioral guidelines

Guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.
If anything here conflicts with the Hard rules, the Hard rules win.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.
Judgment applies to these guidelines only, never to the Hard rules.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified, up to the 10-iteration limit in the Hard rules.**

For the agent, "verified" means lint / syntax checks and the PR checks on GitHub-hosted runners.
It never means running anything on the VMs.

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication,
and clarifying questions come before implementation rather than after mistakes.
