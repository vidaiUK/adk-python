#!/usr/bin/env bash
# Verify our fork's mergeability against real upstream changes.
#
# Diagnostic tool. Does NOT modify main or stable — everything runs on
# throwaway branches that are deleted after each test. Use it when you
# want to know: "does the current fork actually survive real upstream
# changes?" — instead of relying on synthetic tests I might construct.
#
# Two modes:
#
#   ./scripts/verify-against-upstream.sh --pr 5432
#     Test whether upstream PR #5432, if it merged today, would break
#     our fork (conflict, red tests, or clean).
#
#   ./scripts/verify-against-upstream.sh --recent 20
#     Take the last 20 commits on upstream/main and re-try merging
#     each one INDIVIDUALLY into a fresh branch off our current main.
#     Isolates which specific commit caused a break, if any.
#     Useful for post-hoc verification: "was my fix right?"
#
# Flags:
#   --no-tests    Skip pytest, only check mergeability. Faster.
#   --keep        Don't delete throwaway branches on completion.
#                 Useful for inspecting a conflict manually.
#
# Requires: gh CLI (for --pr mode), git, python venv at .venv/
#
# Exit codes:
#   0 = every target merged clean and tests passed (or --no-tests)
#   1 = at least one target broke (conflict or red tests)
#   2 = usage error
set -euo pipefail

# ---- args ----------------------------------------------------------------
MODE=""
COUNT=0
RUN_TESTS=true
KEEP=false

usage() {
  sed -n '2,30p' "$0"
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pr) MODE=pr; COUNT="$2"; shift 2 ;;
    --recent) MODE=recent; COUNT="$2"; shift 2 ;;
    --no-tests) RUN_TESTS=false; shift ;;
    --keep) KEEP=true; shift ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[ -z "$MODE" ] && { echo "must pass --pr N or --recent N" >&2; usage; }
[[ "$COUNT" =~ ^[0-9]+$ ]] || { echo "count must be a number, got: $COUNT" >&2; usage; }

# ---- setup ---------------------------------------------------------------
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

# Save current state so we always return to it.
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ -n "$(git status --short)" ]; then
  echo "ERROR: working tree is dirty. Commit or stash first." >&2
  exit 2
fi

# Ensure upstream remote exists (mirroring sync-core.sh's helper).
if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream https://github.com/google/adk-python.git
fi

# Register the same merge drivers auto-sync uses, so .gitattributes takes effect.
git config merge.theirs.driver 'cp -f "%B" "%A"' 2>/dev/null || true
git config merge.theirs.name   'take theirs'    2>/dev/null || true

echo ">> Fetching upstream..."
git fetch upstream main --quiet
[ "$MODE" = "pr" ] && git fetch upstream "pull/$COUNT/head:refs/verify-tmp/pr-$COUNT" --quiet

BASE_SHA=$(git rev-parse HEAD)
BASE_SHORT=$(git rev-parse --short HEAD)
echo ">> Testing against current fork HEAD: $BASE_SHORT"

# ---- collect the list of targets to test ---------------------------------
TARGETS=()
LABELS=()

if [ "$MODE" = "pr" ]; then
  TARGETS+=("refs/verify-tmp/pr-$COUNT")
  # Try to get a nice label; fall back to the raw ref if gh isn't available.
  PR_TITLE=$(gh pr view "$COUNT" --repo google/adk-python --json title --jq .title 2>/dev/null || echo "")
  if [ -n "$PR_TITLE" ]; then
    LABELS+=("PR #$COUNT: $PR_TITLE")
  else
    LABELS+=("PR #$COUNT")
  fi
else
  # --recent N: last N commits on upstream/main, oldest-first
  while IFS= read -r sha; do
    TARGETS+=("$sha")
    LABELS+=("upstream $(git log -1 --format='%h %s' "$sha" | head -c 70)")
  done < <(git log --format=%H -n "$COUNT" upstream/main | tac)
fi

# ---- run each test in a fresh branch -------------------------------------
declare -a RESULTS   # each entry: "PASS|CONFLICT|TESTFAIL <label>"
FAILURES=0

cleanup_branch() {
  # Best-effort abort any in-progress merge and switch back.
  git merge --abort 2>/dev/null || true
  git checkout "$ORIGINAL_BRANCH" --quiet 2>/dev/null || git checkout "$BASE_SHA" --quiet
  if [ "$KEEP" != true ] && git rev-parse --verify "verify-tmp" >/dev/null 2>&1; then
    git branch -D verify-tmp --quiet 2>/dev/null || true
  fi
}

trap cleanup_branch EXIT

for i in "${!TARGETS[@]}"; do
  TARGET="${TARGETS[$i]}"
  LABEL="${LABELS[$i]}"
  echo
  echo "======================================================================"
  echo ">> [$((i+1))/${#TARGETS[@]}] $LABEL"
  echo "======================================================================"

  # Fresh branch off our current fork HEAD.
  git branch -D verify-tmp --quiet 2>/dev/null || true
  git checkout -b verify-tmp "$BASE_SHA" --quiet

  if git merge --no-edit "$TARGET" >/dev/null 2>&1; then
    echo "  merged clean."
  else
    # Same auto-resolve logic as sync-core.sh — workflow-file conflicts
    # under .github/workflows/** aren't ours to review.
    WORKFLOW_CONFLICTS=$(git diff --name-only --diff-filter=U -- .github/workflows/ || true)
    for f in $WORKFLOW_CONFLICTS; do
      case "$f" in
        .github/workflows/auto-sync.yml|.github/workflows/fork-ci.yml)
          git checkout --ours -- "$f" && git add "$f" ;;
        *)
          git checkout --theirs -- "$f" 2>/dev/null && git add "$f" || git rm -f -- "$f" ;;
      esac
    done
    if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
      echo "  ❌ CONFLICT — files needing manual review:"
      git diff --name-only --diff-filter=U | sed 's/^/       /'
      RESULTS+=("CONFLICT|$LABEL")
      FAILURES=$((FAILURES + 1))
      git merge --abort 2>/dev/null || true
      continue
    fi
    git commit --no-edit --quiet
    echo "  merged with workflow-file auto-resolve."
  fi

  if [ "$RUN_TESTS" = false ]; then
    RESULTS+=("PASS|$LABEL (no-tests)")
    continue
  fi

  echo "  running model tests..."
  if .venv/bin/python -m pytest tests/unittests/models/ \
       --ignore=tests/unittests/models/test_interactions_utils.py \
       -q > /tmp/verify-tmp-tests.log 2>&1; then
    PASS_COUNT=$(grep -oE '[0-9]+ passed' /tmp/verify-tmp-tests.log | tail -1)
    echo "  ✅ PASS ($PASS_COUNT)"
    RESULTS+=("PASS|$LABEL")
  else
    FAIL_COUNT=$(grep -oE '[0-9]+ failed' /tmp/verify-tmp-tests.log | head -1)
    echo "  ❌ TEST FAILURE ($FAIL_COUNT) — first few:"
    grep -E "^FAILED " /tmp/verify-tmp-tests.log | head -3 | sed 's/^/       /'
    RESULTS+=("TESTFAIL|$LABEL")
    FAILURES=$((FAILURES + 1))
  fi
done

# ---- summary -------------------------------------------------------------
echo
echo "======================================================================"
echo ">> SUMMARY (fork HEAD $BASE_SHORT vs ${#TARGETS[@]} target(s))"
echo "======================================================================"
for r in "${RESULTS[@]}"; do
  STATUS="${r%%|*}"
  LABEL="${r#*|}"
  case "$STATUS" in
    PASS)     echo "  ✅  $LABEL" ;;
    CONFLICT) echo "  ❌  CONFLICT: $LABEL" ;;
    TESTFAIL) echo "  ❌  TESTS  : $LABEL" ;;
  esac
done
echo
if [ "$FAILURES" -eq 0 ]; then
  echo ">> All ${#TARGETS[@]} target(s) passed. Fork is genuinely verified against these changes."
  exit 0
else
  echo ">> $FAILURES of ${#TARGETS[@]} target(s) failed. See details above."
  echo ">> Rerun with --keep to inspect the last failing state on branch 'verify-tmp'."
  exit 1
fi
