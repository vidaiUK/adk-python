#!/usr/bin/env bash
# Sync the vidaiUK/adk-python fork with upstream google/adk-python.
#
#   upstream  = https://github.com/google/adk-python.git  (never committed to)
#   origin    = git@github.com:vidaiUK/adk-python.git      (our fork)
#   main      = pristine mirror of upstream/main
#   feature/base-url = our changes, rebased on top of upstream/main
#
# Usage: ./scripts/update-fork.sh
set -euo pipefail

FEATURE_BRANCH="feature/base-url"

echo ">> Fetching upstream..."
git fetch upstream --prune

echo ">> Fast-forwarding main to upstream/main..."
git checkout main
git merge --ff-only upstream/main
git push origin main

echo ">> Rebasing ${FEATURE_BRANCH} onto upstream/main..."
git checkout "${FEATURE_BRANCH}"
git rebase upstream/main

echo ">> Running model tests..."
python -m pytest tests/unittests/models/ -q

echo ">> Tests passed. Push with:"
echo "   git push --force-with-lease origin ${FEATURE_BRANCH}"
