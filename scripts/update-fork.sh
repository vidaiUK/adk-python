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

# Revert any upstream changes to .github/workflows/** so disabled workflows
# stay disabled and the fork's CI surface stays stable. (The auto-sync
# GitHub workflow does the same — for the same reason GITHUB_TOKEN cannot
# push these files, mirroring its behaviour here keeps local and automated
# syncs equivalent.) Skip when nothing was merged.
if [ "$BEFORE" != "$(git rev-parse HEAD)" ] && \
   ! git diff --quiet "$BEFORE" HEAD -- .github/workflows/; then
  echo ">> Reverting upstream changes under .github/workflows/ (keep fork CI stable)"
  git checkout "$BEFORE" -- .github/workflows/
  if ! git diff --quiet --cached; then
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
