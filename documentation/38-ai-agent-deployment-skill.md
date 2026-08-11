# 38. AI Agent Deployment Skill

This repository ships machine-readable guidance for AI coding assistants, so
that an operator using one doesn't have to explain the project to it — they
just point the agent at the right file (or the agent finds it on its own).

## Where to point your agent

| Your tool | What to do |
|-----------|------------|
| Claude Code | Nothing — it auto-discovers the deployment skill in `.claude/skills/padsign-deploy/` and reads `AGENTS.md` as project context. You can invoke the skill explicitly with `/padsign-deploy`. |
| Tools that support the `AGENTS.md` convention (OpenAI Codex, Cursor, GitHub Copilot, Gemini CLI, and others) | Nothing — `AGENTS.md` at the repository root is picked up automatically. |
| Any other assistant | Tell it to read `AGENTS.md` (project map and rules) and `.agents/skills/padsign-deploy/SKILL.md` (deployment procedure) before doing anything. |

## The three files

- **`AGENTS.md`** (repository root) — the project crib sheet: what this repo
  is, the services deployed, directory structure, how to deploy/upgrade, key
  config files, and the conventions an agent must respect (e.g. the
  documentation layout rules, the compose-editing lessons). This is the
  general "read me first" for any agent.
- **`.claude/skills/padsign-deploy/SKILL.md`** — the deployment *skill*:
  task-oriented instructions for operating `installation-scripts/*.sh`
  safely. Auto-discovered by [Claude Code](https://claude.com/claude-code).
- **`.agents/skills/padsign-deploy/SKILL.md`** — identical copy of the skill
  in the tool-agnostic `.agents/` location, for agents that don't read
  `.claude/`. If you edit one copy, mirror the change in the other.

None of these files contain executable code, credentials, or customer data —
they are documentation addressed to an agent instead of a human. Everything
they describe wraps the same scripts a human operator runs; they never bypass
or reimplement them.

## What the skill covers

- **Which script to use for which intent** — first-time deploy
  (`bootstrap.sh`), version bump (`upgrade.sh`), config sanity check
  (`validate-config.sh`), hostname change (`configure-host.sh`), served-cert
  verification (`verify-served-cert.sh`) — and when to ask the operator
  instead of guessing, because the wrong choice can be destructive.
- **Required inputs per workflow** — e.g. that `bootstrap.sh` must never run
  without `--host`, `--company-role`, and `--admin-pass`.
- **Safety rules** — check running state before acting, preserve `*.bak`
  backups, never commit TLS keys or captured secrets, never run
  `docker compose down -v` without asking, surface each script's own
  rollback instructions verbatim.
- **Verification steps** after any deploy or upgrade.

## Without any agent

Ignore all of it. These files change nothing about the stack or the scripts;
the human-facing instructions in this documentation are complete on their
own. This is the same invariant as the
[Deployment Wizard](36-deployment-wizard.md): an optional convenience layer
over the CLI scripts, never a replacement for them.

## Scope and trust notes

- The files only *instruct* an agent; whether an agent can actually run
  Docker or edit files is governed by that agent's own permission model, not
  by this repository.
- Treat edits to `AGENTS.md` or the skill with the same review rigor as
  script edits: an agent will follow what the file says, so a wrong
  instruction there becomes a wrong action on a real host.
- If script behavior changes, update the skill and `AGENTS.md` in the same
  commit that changes the script.
