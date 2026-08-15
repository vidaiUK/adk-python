#!/usr/bin/env bash
# Manually sync the fork with upstream google/adk-python.
#
# Mirrors what .github/workflows/auto-sync.yml does. Both paths source
# scripts/lib/sync-core.sh so the merge/protect/publish/re-disable logic
# is identical mechanically — not just "kept in sync by discipline."
#
# Usage:
#   ./scripts/update-fork.sh              # merge, test, and publish
#   ./scripts/update-fork.sh --dry-run    # merge and test only; stop before push
set -euo pipefail

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
# shellcheck source=lib/sync-core.sh
. "$REPO_ROOT/scripts/lib/sync-core.sh"

echo ">> Configuring git and merge drivers..."
sync_configure_git
sync_ensure_upstream_remote

git checkout "$INTEGRATION_BRANCH"

echo ">> Merging upstream/main..."
sync_merge_upstream
case "$SYNC_RESULT" in
  up-to-date)
    echo ">> Already in sync with upstream — no new merge, but still checking"
    echo "   for inherited workflows that may have re-activated."
    # Re-disable pass ALWAYS runs, even when there's nothing to merge.
    # Rationale: an inherited workflow can go active between our syncs
    # (e.g. a stray push from anywhere touched .github/workflows/**),
    # and gating re-disable on "merged" leaves those active until the
    # next upstream change. Run it defensively — no polling needed since
    # no push happened.
    sync_redisable_inherited_workflows quick
    echo ">> Done."
    exit 0
    ;;
  conflict)
    echo ">> Real conflicts remain (outside .github/workflows/**)."
    echo ">> Resolve manually, then: git merge --continue && $0"
    exit 1
    ;;
  merged)
    ;;
esac

echo ">> Protecting fork-owned workflow files..."
sync_protect_fork_workflows "$SYNC_BEFORE"

echo ">> Running model tests..."
python -m pytest tests/unittests/models/ \
  --ignore=tests/unittests/models/test_interactions_utils.py -q

if [ "$DRY_RUN" = true ]; then
  cat <<EOF
>> Dry run complete. To publish:
     $0
   Or manually:
     git push origin $INTEGRATION_BRANCH
     git push origin $INTEGRATION_BRANCH:$STABLE_BRANCH
EOF
  exit 0
fi

echo ">> Publishing new baseline..."
sync_publish_baseline

echo ">> Re-disabling inherited workflows that upstream may have re-activated..."
echo "   (polling for up to 90s — GitHub takes seconds to register new"
echo "    workflow files after our push before the disable API sees them)"
sync_redisable_inherited_workflows polling

echo ">> Done."
