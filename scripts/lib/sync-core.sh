#!/usr/bin/env bash
# Shared sync logic for the vidaiUK/adk-python fork.
#
# Sourced by BOTH:
#   * scripts/update-fork.sh              (manual/local recovery)
#   * .github/workflows/auto-sync.yml     (daily scheduled bot)
#
# Every step of a sync (merge, auto-resolve inherited workflow conflicts,
# protect fork-owned workflows, publish, re-disable inherited workflows)
# lives here as a shell function so both paths call the SAME code. This
# prevents the class of outage where a fix landed in one path (usually
# auto-sync.yml) and was silently missing from the other (update-fork.sh),
# so manual recoveries would re-introduce the exact problem the fix
# was meant to prevent. (2026-07-02: Continuous Integration re-activated
# after a manual recovery because the "Re-disable inherited workflows"
# step only lived in the YAML.)
#
# Design notes:
#   * Every function returns non-zero on failure (usable with `set -e`).
#   * Nothing runs on source — callers invoke functions by name.
#   * Callers set REPO / STABLE_BRANCH / INTEGRATION_BRANCH env vars
#     before calling. Defaults below make ad-hoc use easy.
#   * Functions that call `gh` need GH_TOKEN in the environment on CI;
#     locally they use your `gh auth login` credentials.

: "${INTEGRATION_BRANCH:=main}"
: "${STABLE_BRANCH:=stable}"
: "${UPSTREAM_REPO:=https://github.com/google/adk-python.git}"
: "${REPO:=vidaiUK/adk-python}"

# The workflows we own on this fork. Everything else under
# .github/workflows/** is considered inherited-from-upstream, whether
# it exists today or arrives on a future merge.
#
# Two things flow from this single list:
#   1. `sync_merge_upstream` treats these paths as `merge=ours` at
#      conflict-resolution time (kept in sync with .gitattributes).
#   2. `sync_redisable_inherited_workflows` uses the BASENAMES to build
#      an allowlist; every OTHER active workflow on the repo gets
#      disabled after every sync.
#
# Rationale for "disable everything else": upstream's CI (Continuous
# Integration, pre-commit linters, mypy, unit-test matrices,
# release/copybara/agent workflows, etc.) exists to protect the ADK
# codebase THEY ship. On our fork, our only responsibility is to prove
# that our env-var patch works — fork-ci.yml is the entire story on
# our side. Running upstream's full CI on this fork is strictly noise:
# it fails on lint against our patch, on infra that doesn't exist
# here (Copybara, PyPI publishing), and on flaky tests we don't own.
# It also gets in a race with a hardcoded-list disable step because a
# workflow-file rewrite in the same merge causes a transient "deleted"
# state we skip past (see 2026-07-03 outage).
#
# When adding a new fork-owned workflow: (a) add it to this array,
# (b) add a `merge=ours` line to .gitattributes for the same path.
FORK_OWNED_WORKFLOWS=(
  .github/workflows/auto-sync.yml
  .github/workflows/fork-ci.yml
)

sync_configure_git() {
  # Bot identity for automated commits. Callers on their own machine may
  # already have a personal identity configured; we set the bot identity
  # unconditionally so history is consistent.
  git config user.name  "adk-fork-bot"
  git config user.email "adk-fork-bot@users.noreply.github.com"

  # Register merge drivers referenced by .gitattributes.
  #   `ours`   ships with git (keeps the current version).
  #   `theirs` is a custom driver: cp -f "%B" "%A" replaces the current
  #            tree's version (%A) with the other side's (%B).
  # Together with .gitattributes, this makes workflow-file conflicts
  # under .github/workflows/** resolve automatically at merge time.
  git config merge.theirs.driver 'cp -f "%B" "%A"'
  git config merge.theirs.name   'take theirs'
}

sync_ensure_upstream_remote() {
  if ! git remote get-url upstream >/dev/null 2>&1; then
    git remote add upstream "$UPSTREAM_REPO"
  fi
}

# Attempt the merge. Sets three globals when it returns:
#   SYNC_RESULT: 'up-to-date' | 'merged' | 'conflict'
#   SYNC_BEFORE: HEAD SHA before the merge
#   SYNC_AFTER:  HEAD SHA after the merge (equals BEFORE for up-to-date
#                or conflict; caller inspects SYNC_RESULT to distinguish).
#
# Content conflicts under .github/workflows/** are resolved silently at
# merge time via .gitattributes' merge=theirs / merge=ours. This function
# additionally auto-resolves the modify/delete case, which merge drivers
# do not cover. Real conflicts outside .github/workflows/** are left
# in the index; SYNC_RESULT is set to 'conflict' and the merge is aborted.
sync_merge_upstream() {
  git fetch upstream main
  SYNC_BEFORE=$(git rev-parse HEAD)

  if git merge --no-edit upstream/main; then
    :   # clean merge, fall through
  else
    # Try to auto-resolve any workflow-file conflicts that survived
    # .gitattributes (mainly modify/delete).
    local f
    local conflicts
    conflicts=$(git diff --name-only --diff-filter=U -- .github/workflows/ || true)
    for f in $conflicts; do
      case " ${FORK_OWNED_WORKFLOWS[*]} " in
        *" $f "*)
          git checkout --ours -- "$f" && git add "$f"
          echo "  auto-resolved (ours): $f"
          ;;
        *)
          if git checkout --theirs -- "$f" 2>/dev/null; then
            git add "$f"
          else
            git rm -f -- "$f"
          fi
          echo "  auto-resolved (theirs): $f"
          ;;
      esac
    done

    # Anything left is real work.
    if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
      echo "  real conflicts remain:"
      git diff --name-only --diff-filter=U | sed 's/^/    /'
      git merge --abort
      SYNC_AFTER=$SYNC_BEFORE
      SYNC_RESULT=conflict
      return 0
    fi
    git commit --no-edit
  fi

  SYNC_AFTER=$(git rev-parse HEAD)
  if [ "$SYNC_BEFORE" = "$SYNC_AFTER" ]; then
    SYNC_RESULT=up-to-date
  else
    SYNC_RESULT=merged
  fi
}

# Belt-and-braces: if `.gitattributes` itself was rewritten by the same
# merge that touched our workflow files, `merge=ours` may not have been
# in effect. Re-apply our version of the fork-owned workflows from the
# pre-merge tree. No-op if the files are already at the pre-merge content.
sync_protect_fork_workflows() {
  local before=$1
  local amended=false
  local f
  for f in "${FORK_OWNED_WORKFLOWS[@]}"; do
    if ! git diff --quiet "$before" HEAD -- "$f"; then
      echo "  restoring $f to pre-merge content"
      if git cat-file -e "$before:$f" 2>/dev/null; then
        git checkout "$before" -- "$f"
      else
        git rm -f --quiet "$f"
      fi
      amended=true
    fi
  done
  if [ "$amended" = true ]; then
    git commit --amend --no-edit
  fi
}

# Disable every workflow on the repo that isn't in FORK_OWNED_WORKFLOW_BASENAMES.
#
# This is the "upstream CI is upstream's problem" rule expressed in code.
# Anything active that we don't own gets disabled, regardless of whether we've
# seen it before. This means:
#   * No UNWANTED list to maintain. New inherited workflows added by upstream
#     land already-disabled after the next sync.
#   * A workflow that re-activates due to an upstream file rewrite gets
#     re-disabled on the next sync, not after we notice red X.
#   * The one race we can't prevent: a workflow that fires ONCE during the
#     transient window between our push landing and the disable step running.
#     That single fire produces at most one red X per sync, and only for
#     push-triggered workflows. Consumers pin @stable which is already green.
sync_redisable_inherited_workflows() {
  # Derive the basename allowlist from FORK_OWNED_WORKFLOWS (single source
  # of truth). GitHub's actions/workflows API keys are basenames, not
  # full paths, so we strip the leading .github/workflows/ prefix.
  local basenames_joined="" f base
  for f in "${FORK_OWNED_WORKFLOWS[@]}"; do
    base="${f##*/}"
    basenames_joined="${basenames_joined}|${base}"
  done
  basenames_joined="${basenames_joined:1}"   # drop leading '|'

  # Enumerate all workflows on the repo, one per line as "state<TAB>basename".
  local rows
  rows=$(gh api "repos/$REPO/actions/workflows" --paginate \
           --jq '.workflows[] | "\(.state)\t\(.path | sub(".*/"; ""))"' 2>/dev/null || true)

  if [ -z "$rows" ]; then
    echo "  (no workflows returned by API — nothing to do)"
    return 0
  fi

  local disabled_count=0
  local kept_count=0
  local state basename
  while IFS=$'\t' read -r state basename; do
    [ -z "$basename" ] && continue
    # Skip anything in the fork-owned allowlist.
    case "|$basenames_joined|" in
      *"|$basename|"*)
        echo "  keeping (fork-owned): $basename [state=$state]"
        kept_count=$((kept_count + 1))
        continue
        ;;
    esac
    # For everything else: if active, disable. Otherwise leave it.
    if [ "$state" = "active" ]; then
      echo "  disabling inherited: $basename"
      gh api -X PUT "repos/$REPO/actions/workflows/$basename/disable" >/dev/null
      disabled_count=$((disabled_count + 1))
    fi
  done <<< "$rows"

  echo "  summary: $disabled_count disabled this run, $kept_count kept (fork-owned)"
}

# Push main and fast-forward stable. This is the "advance the baseline"
# step. Consumers pin @stable so anything that reaches stable is what
# they get. Only ever called after tests pass.
sync_publish_baseline() {
  git push origin "HEAD:$INTEGRATION_BRANCH"
  git push origin "HEAD:$STABLE_BRANCH"
  echo "  advanced $STABLE_BRANCH to $(git rev-parse --short HEAD)"
}
