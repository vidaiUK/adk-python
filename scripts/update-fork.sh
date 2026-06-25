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

echo ">> Fetching upstream..."
git fetch upstream main --prune

echo ">> Merging upstream/main into ${INTEGRATION_BRANCH}..."
git checkout "${INTEGRATION_BRANCH}"
BEFORE=$(git rev-parse HEAD)
git merge --no-edit upstream/main   # stops here if there are conflicts

# Re-apply our version of the two workflows we own. Mirrors the
# "Protect fork-owned workflows" step in auto-sync.yml, so local and
# automated syncs produce equivalent trees. Every OTHER workflow file
# (Copybara, release pipelines, etc.) is allowed to track upstream;
# inherited workflows we don't want stay disabled via `gh workflow disable`,
# which persists across file content changes.
if [ "$BEFORE" != "$(git rev-parse HEAD)" ]; then
  AMENDED=false
  for f in .github/workflows/auto-sync.yml .github/workflows/fork-ci.yml; do
    if ! git diff --quiet "$BEFORE" HEAD -- "$f"; then
      echo ">> Restoring $f to pre-merge content"
      if git cat-file -e "$BEFORE:$f" 2>/dev/null; then
        git checkout "$BEFORE" -- "$f"
      else
        git rm -f --quiet "$f"
      fi
      AMENDED=true
    fi
  done
  if [ "$AMENDED" = true ]; then
    git commit --amend --no-edit
  fi
fi

echo ">> Running model tests..."
python -m pytest tests/unittests/models/ -q

cat <<EOF
>> Tests passed. Publish the new baseline with:
     git push origin ${INTEGRATION_BRANCH}
     git push origin ${INTEGRATION_BRANCH}:stable
EOF
