#!/usr/bin/env bash
# Manually sync the fork with upstream google/adk-python.
#
# Mirrors what .github/workflows/auto-sync.yml does, for local recovery when
# an automated sync fails (merge conflict or red tests).
#
#   feature/base-url = integration branch (base_url patch + upstream merged in)
#   stable           = what consumers pin; advance it only when tests pass
#
# Usage: ./scripts/update-fork.sh
set -euo pipefail

INTEGRATION_BRANCH="feature/base-url"

# Ensure an `upstream` remote exists.
if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream https://github.com/google/adk-python.git
fi

echo ">> Fetching upstream..."
git fetch upstream main --prune

echo ">> Merging upstream/main into ${INTEGRATION_BRANCH}..."
git checkout "${INTEGRATION_BRANCH}"
git merge --no-edit upstream/main   # stops here if there are conflicts

echo ">> Running model tests..."
python -m pytest tests/unittests/models/ -q

cat <<EOF
>> Tests passed. Publish the new baseline with:
     git push origin ${INTEGRATION_BRANCH}
     git push origin ${INTEGRATION_BRANCH}:stable
EOF
