# 14.4 AI agent deployment skill

The deployment package includes instructions written for AI coding assistants, so an assistant
running on your host can operate PadSign's installation scripts correctly without you explaining the
project first. This is optional. The scripts and this documentation work the same without it.

## How to use it

| Your tool | What to do |
|---|---|
| Claude Code | Nothing. Started in `/opt/padsign`, it finds the skill in `.claude/skills/padsign-deploy/` and reads `AGENTS.md`. You can also call the skill directly with `/padsign-deploy`. |
| Tools that read `AGENTS.md` (for example OpenAI Codex, Cursor, GitHub Copilot, Gemini CLI) | Nothing. `AGENTS.md` in the repository root is picked up automatically. |
| Any other assistant | Tell it to read `AGENTS.md` and `.agents/skills/padsign-deploy/SKILL.md` before it does anything. |

Then describe the task in plain words, for example "install PadSign for padsign.example.com",
"renew the TLS certificate" or "check why ps-server keeps restarting".

## The files

- **`AGENTS.md`**: an overview of the deployment package for an assistant: services, directory
  layout, key configuration files and the rules to respect.
- **`.claude/skills/padsign-deploy/SKILL.md`** and **`.agents/skills/padsign-deploy/SKILL.md`**:
  the same deployment skill in two locations, for tools that read one or the other.

They contain instructions only: no code, credentials or customer data.

## What the skill tells the assistant

- **Which script fits which task**: first install (`bootstrap.sh`), upgrade (`upgrade.sh`, with a
  `--plan-only` preview first), configuration check (`validate-config.sh`), hostname change
  (`update-hostname.sh`), certificate renewal (`renew-cert.sh`), feature changes
  (`toggle-features.sh`), post-deploy checks (`postdeploy-check.sh`), rollback (`rollback.sh`),
  monitoring (`monitor-status.sh`) and test logins (`smoke-user.sh`). When your request is vague, the
  assistant is told to ask which one you mean, because the wrong one can be destructive.
- **Required inputs**, for example that `bootstrap.sh` needs a hostname, a company role and an
  admin password, and that the assistant should ask for anything missing in one go.
- **Safety rules**, among them: check the running state before acting; keep the `*.bak` backups;
  never put a password on a command line; never commit TLS keys or secrets; never run
  `docker compose down -v` (it deletes the Keycloak database) without asking; never approve an image
  or skip a signature check on its own; report a failing check's exact output instead of
  paraphrasing it.
- **Verification** after every install or upgrade (`postdeploy-check.sh`, all services healthy).

## Trust and permissions

- The files only instruct an assistant. What it can actually do on your host (run Docker, edit
  files) is controlled by that assistant's own permission settings, not by this package. Review
  the commands it proposes as you would a colleague's.
- An assistant follows these files literally. If you change them on your host, review the change as
  carefully as a change to a script.
