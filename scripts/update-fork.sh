#!/usr/bin/env bash
# Manually sync the fork with upstream google/adk-python.
#
# Mirrors what .github/workflows/auto-sync.yml does, for local recovery when
# an automated sync fails (merge conflict or red tests).
#
#   main = integration branch (base_url patch + upstream merged in)
#   stable           = what consumers pin; advance it only when tests pass
#
# Usage: ./scripts/update-fork.sh
set -euo pipefail

INTEGRATION_BRANCH="main"

# Ensure an `upstream` remote exists.
if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream https://github.com/google/adk-python.git
fi

# Register merge drivers referenced by .gitattributes.
git config merge.theirs.driver 'cp -f "%B" "%A"' || true
git config merge.theirs.name   'take theirs' || true

echo ">> Fetching upstream..."
git fetch upstream main --prune

echo ">> Merging upstream/main into ${INTEGRATION_BRANCH}..."
git checkout "${INTEGRATION_BRANCH}"
BEFORE=$(git rev-parse HEAD)

# Same auto-resolution logic as auto-sync.yml — see that file for the
# rationale. Workflow-file conflicts under .github/workflows/** (except
# the two we own) get auto-resolved so we never stop on inherited-CI
# churn. Real conflicts in source/tests still stop the script.
if ! git merge --no-edit upstream/main; then
  WORKFLOW_CONFLICTS=$(git diff --name-only --diff-filter=U -- .github/workflows/ || true)
  for f in $WORKFLOW_CONFLICTS; do
    case "$f" in
      .github/workflows/auto-sync.yml|.github/workflows/fork-ci.yml)
        git checkout --ours -- "$f" && git add "$f"
        echo ">> auto-resolved (ours): $f"
        ;;
      *)
        if git checkout --theirs -- "$f" 2>/dev/null; then
          git add "$f"
        else
          git rm -f -- "$f"
        fi
        echo ">> auto-resolved (theirs): $f"
        ;;
    esac
  done
  # Any conflicts left are real work.
  if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
    echo ">> Real conflicts remain (outside .github/workflows/**):"
    git diff --name-only --diff-filter=U
    echo ">> Resolve manually, then: git merge --continue"
    exit 1
  fi
  git commit --no-edit
fi

echo ">> Running model tests..."
python -m pytest tests/unittests/models/ -q

cat <<EOF
>> Tests passed. Publish the new baseline with:
     git push origin ${INTEGRATION_BRANCH}
     git push origin ${INTEGRATION_BRANCH}:stable
EOF
