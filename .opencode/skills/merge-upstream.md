---
name: merge-upstream
description: Use when synchronizing a git fork with its upstream repository while preserving fork-specific Docker files. Triggered by "sync upstream", "merge upstream", "同步上游". Also use when asked about merge strategy between upstream and fork.
---

# Merge Upstream (Fork Sync)

## Overview

Synchronize a fork with upstream while preserving fork-specific implementations. This fork (`tryweb/jt-ipam`) uses **root-level Docker Compose** (4 services: postgres, redis, backend, frontend with separate Dockerfiles). The upstream (`jasoncheng7115/jt-ipam`) added Docker Compose under `deploy/docker/` (5 services + sync + built-in HTTPS).

**Key insight:** Docker file paths do NOT overlap between fork and upstream, so merges are clean by default. Only shared files (README, CHANGELOG, version, .gitignore) may conflict.

## File Mapping

| Category | Fork Files (keep) | Upstream Files (accept) |
|---|---|---|
| **Compose** | `docker-compose.yml` | `deploy/docker/docker-compose.yml` |
| **Dockerfiles** | `backend/Dockerfile`, `frontend/Dockerfile` | `deploy/docker/Dockerfile` |
| **Entrypoints** | `backend/scripts/docker-entrypoint.sh` | `deploy/docker/entrypoint-backend.sh`, `deploy/docker/entrypoint-web.sh` |
| **nginx conf** | `deploy/nginx/jt-ipam-docker.conf` | `deploy/docker/nginx.conf` |
| **PG init** | `deploy/postgres/init-docker.sh` | *(upstream has none)* |
| **Env config** | `.env.docker.example` | `deploy/docker/.env.example`, `deploy/docker/gen-env.sh` |
| **Update** | *(fork has none)* | `deploy/docker/update.sh` |
| **Other** | `.dockerignore`, `.codegraph/`, `.opencode/` tooling | `.dockerignore`, `.gitignore` additions |

**No path overlap on any Docker-specific file.** Merges will never have Docker-vs-Docker conflicts.

## Process

```
User says "sync upstream"
       │
       ▼
  ┌─────────────────────────┐
  │ Run sync-upstream.sh    │
  └────────┬────────────────┘
           │
     ┌─────┴─────┐
     │           │
     ▼           ▼
  No conflict   Conflict
     │           │
     ▼           ▼
  Review diff   AI analyzes both
  in git diff   versions side-by-side
     │           │
     ▼           ▼
  Confirm &    Present options
  commit       to user
     │           │
     ▼           ▼
    Done      User decides
                 │
                 ▼
              Apply resolution
              & commit
```

## Step-by-Step

### 1. Run the Merge Script

```bash
bash scripts/sync-upstream.sh
```

The script:
- Adds upstream remote if missing (`https://github.com/jasoncheng7115/jt-ipam.git`)
- Fetches upstream/main
- Attempts `git merge --no-commit --no-ff`
- If clean: shows diff summary and instructions to commit
- If conflict: exits with list of conflicting files → proceed to step 2

### 2. If No Conflicts

Review the staged changes:
```bash
git diff --cached --stat          # file list
git diff --cached                 # full diff
```

If everything looks correct, commit:
```bash
git commit -m "chore: sync upstream $(git rev-parse --short upstream/main)"
```

To abort: `git merge --abort`

### 3. If Conflicts — AI Analysis

For each conflicting file, determine the disposition:

**Likely conflict categories:**

| File | Usual conflict | Default action |
|---|---|---|
| `README.md` / `README_zh-TW.md` | Docker description section | Keep fork's Docker section wording; accept upstream's other changes |
| `CHANGELOG.md` / `CHANGELOG_zh-TW.md` | Both added entries | Merge entries chronologically |
| `backend/app/version.py` | Version number | Accept upstream version |
| `frontend/package.json` | Version number | Accept upstream version |
| `.gitignore` | Ignore rules | Accept both |
| `.dockerignore` | New file (fork doesn't have it yet) | Accept upstream (useful for both Docker setups) |

**AI's conflict analysis should:**
1. Read the conflict markers in each file
2. Show the user a side-by-side summary of "ours" (fork) vs "theirs" (upstream) for the conflicting sections
3. Recommend a resolution based on the default actions above
4. Ask the user to confirm or decide

**To resolve a specific file after decision:**
```bash
# After editing conflict markers:
git add <file>
git commit
```

## Script Reference

The script at `scripts/sync-upstream.sh` handles the automated portion. See the script for full implementation.

## Common Mistakes

- **Forgetting to stash local changes** — script will fail on dirty working tree. Run `git stash` first.
- **Force-pushing without testing** — always test after sync before pushing.
- **Missing the upstream deploy/docker/ dir** — it coexists harmlessly with fork's Docker files. Optionally `git rm -rf deploy/docker/` after merge if you want to remove it.
