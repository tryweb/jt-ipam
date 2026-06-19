#!/usr/bin/env bash
# ==========================================================================
# sync-upstream.sh — Sync tryweb/jt-ipam fork with upstream jt-ipam
#
# This is the automated portion of the merge-upstream skill workflow.
# It handles fetching, merging, and detecting conflicts.
# Conflict resolution is delegated to AI + user decision.
#
# Usage:
#   bash scripts/sync-upstream.sh
#
# On success: staged merge ready for review + commit.
# On conflict: exits with list of conflicting files for further handling.
# ==========================================================================
set -euo pipefail

UPSTREAM_REMOTE="upstream"
UPSTREAM_URL="https://github.com/jasoncheng7115/jt-ipam.git"
UPSTREAM_BRANCH="main"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║      jt-ipam Upstream Sync                 ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Pre-flight checks ────────────────────────────────────────────────

# Must be in a git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo -e "${RED}Error: not inside a git repository.${NC}" >&2
    exit 1
fi

# Working tree must be clean
if ! git diff --quiet HEAD 2>/dev/null; then
    echo -e "${RED}Error: working tree has uncommitted changes.${NC}" >&2
    echo "Stash or commit them first, then re-run." >&2
    echo "  git stash"
    echo "  bash scripts/sync-upstream.sh" >&2
    exit 1
fi

# ── Ensure upstream remote ────────────────────────────────────────────

echo -e "${YELLOW}[1/4]${NC} Checking upstream remote..."

if git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    CURRENT_URL=$(git remote get-url "$UPSTREAM_REMOTE")
    if [ "$CURRENT_URL" != "$UPSTREAM_URL" ]; then
        echo -e "  ${YELLOW}Upstream remote URL is different:${NC}"
        echo -e "  Current: $CURRENT_URL"
        echo -e "  Expected: $UPSTREAM_URL"
        echo -e "  Update with: git remote set-url $UPSTREAM_REMOTE $UPSTREAM_URL"
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} Upstream remote already configured: $UPSTREAM_REMOTE"
else
    echo -e "  Adding upstream remote..."
    git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
    echo -e "  ${GREEN}✓${NC} Added upstream remote: $UPSTREAM_URL"
fi

# ── Fetch upstream ────────────────────────────────────────────────────

echo -e "${YELLOW}[2/4]${NC} Fetching upstream/$UPSTREAM_BRANCH..."
git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
FORK_BRANCH=$(git branch --show-current)
echo -e "  ${GREEN}✓${NC} Fetched upstream/$UPSTREAM_BRANCH"
echo ""

# ── Check ahead/behind ────────────────────────────────────────────────

FORK_HASH=$(git rev-parse HEAD)
UPSTREAM_HASH=$(git rev-parse "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")

if [ "$FORK_HASH" = "$UPSTREAM_HASH" ]; then
    echo -e "${GREEN}Fork is already up to date with upstream.${NC}"
    echo "Nothing to do."
    exit 0
fi

BEHIND=$(git rev-list --count HEAD.."$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" 2>/dev/null)
AHEAD=$(git rev-list --count "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"..HEAD 2>/dev/null)

echo -e "  Fork branch:      ${CYAN}$FORK_BRANCH${NC}"
echo -e "  Fork HEAD:        ${CYAN}$(git rev-parse --short HEAD)${NC}"
echo -e "  Upstream HEAD:    ${CYAN}$(git rev-parse --short "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")${NC}"
echo -e "  Fork is:          ${YELLOW}$BEHIND commits behind${NC} / ${YELLOW}$AHEAD commits ahead${NC}"
echo ""

# ── Merge ─────────────────────────────────────────────────────────────

echo -e "${YELLOW}[3/4]${NC} Merging $UPSTREAM_REMOTE/$UPSTREAM_BRANCH into $FORK_BRANCH..."
echo -e "  (using --no-commit --no-ff for reviewability)"
echo ""

# Run merge; capture exit code without set -e causing exit
set +e
git merge "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" --no-commit --no-ff 2>&1
MERGE_EXIT=$?
set -e

echo ""

if [ $MERGE_EXIT -eq 0 ]; then
    # ── Success: no conflicts ─────────────────────────────────────────
    echo -e "${GREEN}[4/4]✓ Merge successful — no conflicts.${NC}"
    echo ""
    echo -e "${CYAN}Changed files:${NC}"
    git diff --cached --stat
    echo ""
    echo -e "────────────────────────────────────────────"
    echo -e "${YELLOW}Next steps:${NC}"
    echo ""
    echo -e "  1. Review the diff:"
    echo -e "     ${CYAN}git diff --cached${NC}"
    echo ""
    echo -e "  2. Commit the merge:"
    echo -e "     ${CYAN}git commit -m \"chore: sync upstream $(git rev-parse --short "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")\"${NC}"
    echo ""
    echo -e "  3. Or abort: ${CYAN}git merge --abort${NC}"
    echo -e "────────────────────────────────────────────"
else
    # ── Conflict ──────────────────────────────────────────────────────
    echo -e "${RED}[4/4]✗ Merge has conflicts.${NC}"
    echo ""

    # List conflicted files
    CONFLICTS=$(git diff --name-only --diff-filter=U 2>/dev/null | sort)
    echo -e "${YELLOW}Conflicting files:${NC}"
    if [ -z "$CONFLICTS" ]; then
        # Try alternative method
        CONFLICTS=$(git ls-files --unmerged 2>/dev/null | awk '{print $4}' | sort -u)
        echo "$CONFLICTS"
    else
        echo "$CONFLICTS"
    fi
    echo ""

    # List other uncommitted files (new/changed without conflict)
    OTHER=$(git diff --name-only --diff-filter=M 2>/dev/null | sort)
    if [ -n "$OTHER" ]; then
        echo -e "${YELLOW}Unstaged changes (non-conflicting):${NC}"
        echo "$OTHER"
        echo ""
    fi

    echo -e "────────────────────────────────────────────"
    echo -e "${RED}Resolve conflicts with AI assistance.${NC}"
    echo ""
    echo -e "  For each conflicted file:"
    echo -e "    1. Read the conflict markers (<<<<<<< / ======= / >>>>>>>)"
    echo -e "    2. Decide: keep fork (ours) or upstream (theirs) or merge"
    echo -e "    3. Edit the file, remove conflict markers"
    echo -e "    4. ${CYAN}git add <file>${NC}"
    echo ""
    echo -e "  When all resolved, commit:"
    echo -e "    ${CYAN}git commit${NC}"
    echo -e "────────────────────────────────────────────"
    exit 1
fi
