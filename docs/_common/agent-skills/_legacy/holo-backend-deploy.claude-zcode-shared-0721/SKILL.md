---
name: holo-backend-deploy
description: Deploy HoloBackend to the Aliyun ECS production server. Use when the user asks to deploy backend changes, publish HoloBackend, update ECS backend, run the Holo backend deployment, or says backend code is ready and should go online. This skill runs the full automated HoloBackend deployment workflow: test local backend, commit only HoloBackend changes when present, push the current branch, SSH to ECS, pull latest code, rebuild the holo-backend Docker Compose service, and verify health/prompts.
metadata:
  short-description: Deploy HoloBackend to ECS
---

# HoloBackend Deploy

## Default Action

When triggered, run the bundled script:

```bash
bash /Users/tangyuxuan/.claude/skills/holo-backend-deploy/scripts/deploy-backend.sh
```

This is intended to be the normal path. Do not reconstruct the deployment command sequence by hand unless the script itself fails and the failure needs investigation.

## What The Script Does

1. Uses `/Users/tangyuxuan/Desktop/Claude/HOLO` as the local repo by default.
2. Detects the current git branch and pushes to `origin/<branch>`.
3. Runs `npm test --prefix HoloBackend`.
4. If there are local changes under `HoloBackend/`, commits only those backend files with a generated deployment commit message.
5. Pushes the current branch.
6. SSHes to `root@123.56.104.9`.
7. On ECS, enters `/root/Holo`, then diagnoses any dirty working-tree state: it diffs each modified tracked file against `origin/<branch>`. If every change equals the target branch content (the common case after past rsync/cp-based deploys that never committed/reset HEAD), it aligns HEAD with `git reset --hard origin/<branch>` safely. If any file truly diverges, it stops and reports.
8. Calls the project's own `HoloBackend/deploy/deploy.sh`, which builds the image with `DOCKER_BUILDKIT=0` (avoids trying to pull the local base image `deploy-holo-backend:latest` from Docker Hub, which times out on China ECS), recreates the container, and runs full acceptance checks (local health, public health, release status, admin release status).
9. Verifies public health at `https://api.holoapp.cn/v1/health` (the production domain — nginx on the ECS only reverse-proxies the domain, not the raw IP).

## Safety Rules

- The script commits only paths under `HoloBackend/`; it must not stage iOS, docs, or unrelated files.
- On ECS dirty working tree, the script never force-overwrites blindly. It first diffs each modified file against `origin/<branch>`; only when all changes are byte-identical to the target branch (a safe no-op content-wise) does it `reset --hard`. If any file truly diverges from the target branch, it stops and asks for human judgment.
- Docker build uses `DOCKER_BUILDKIT=0` via the project `deploy.sh`, because the Dockerfile's `FROM deploy-holo-backend:latest` references a locally built image that BuildKit tries to verify against Docker Hub (unreachable from China ECS).
- Do not use `docker compose build --no-cache` by default. Use no-cache only when Docker cache is the suspected root cause or when system/native dependencies changed and a normal rebuild has been verified insufficient.
- Do not paste or store ECS passwords, API keys, admin passwords, or `.env.production` contents.
- If SSH asks for a password, let the user type it into the terminal; do not ask the user to send the password in chat.

## Failure Handling

- Local tests fail: stop. Summarize the failing test command and the first actionable error.
- Git push fails: stop. Check branch/upstream/auth before retrying.
- SSH fails: stop. Ask the user to verify SSH access or key/password state.
- ECS dirty-tree diagnosis finds a file that truly diverges from `origin/<branch>`: stop. Report which files diverge and how many diff lines; let the user decide whether those changes are stale (safe to discard) or valuable (must be preserved before proceeding).
- `git reset --hard` fails: stop. Inspect the ECS repo state manually.
- Docker build fails: stop. Inspect `docker compose logs holo-backend` only if the container starts but health checks fail. If the build fails with a Docker Hub / registry timeout, confirm the project `deploy.sh` is being invoked (it sets `DOCKER_BUILDKIT=0`).
- Health check fails: fetch recent `docker compose logs --tail=120 holo-backend` and summarize the likely cause.

## Useful Overrides

The script supports environment variables when needed:

```bash
HOLO_REPO=/path/to/HOLO \
HOLO_REMOTE_HOST=root@123.56.104.9 \
HOLO_REMOTE_REPO=/root/Holo \
HOLO_PUBLIC_BASE_URL=https://api.holoapp.cn \
bash /Users/tangyuxuan/.claude/skills/holo-backend-deploy/scripts/deploy-backend.sh
```
