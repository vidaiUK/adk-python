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

# Do one enumerate-and-disable pass. Returns via stdout: two integers
# separated by a space — "<disabled_this_pass> <active_after>". Callers can
# use these to decide whether to poll again.
_sync_disable_pass_once() {
  local basenames_joined="$1"
  local rows
  rows=$(gh api "repos/$REPO/actions/workflows" --paginate \
           --jq '.workflows[] | "\(.state)\t\(.path | sub(".*/"; ""))"' 2>/dev/null || true)

  if [ -z "$rows" ]; then
    echo "0 0"
    return 0
  fi

  local disabled=0 remaining_active=0
  local state basename
  while IFS=$'\t' read -r state basename; do
    [ -z "$basename" ] && continue
    case "|$basenames_joined|" in
      *"|$basename|"*) continue ;;  # fork-owned, skip
    esac
    if [ "$state" = "active" ]; then
      if gh api -X PUT "repos/$REPO/actions/workflows/$basename/disable" >/dev/null 2>&1; then
        echo "  disabled: $basename" >&2
        disabled=$((disabled + 1))
      else
        # Disable failed (permissions, transient, etc.) — count as still active
        # so the poll loop tries again.
        remaining_active=$((remaining_active + 1))
      fi
    fi
  done <<< "$rows"

  echo "$disabled $remaining_active"
}

# Disable every workflow on the repo that isn't in FORK_OWNED_WORKFLOWS.
#
# This is the "upstream CI is upstream's problem" rule expressed in code.
# Anything active we don't own gets disabled, regardless of whether we've
# seen it before. This means:
#   * No UNWANTED list to maintain. New inherited workflows added by upstream
#     land already-disabled after the next sync.
#   * A workflow that re-activates due to an upstream file rewrite gets
#     re-disabled on the next sync.
#
# THE RACE (fixed as of commit c8595de85+... 2026-08-15):
# When our push lands a modified workflow file, GitHub's registration of the
# new file is ASYNC — the file arrives, then some seconds later GitHub
# reconciles it as a workflow the API knows about, then any push triggers
# fire. If we query the workflows API too fast, the newly-modified
# workflow isn't in the response yet, so we skip it — then it fires
# a moment later on the same push. That's what caused the 2026-07-03,
# 2026-08-14, and 2026-08-15 red-X-on-Continuous-Integration outages.
#
# Fix: when called from the merged path (arg: "polling"), poll every 10s
# for up to 90s, disabling anything that appears. Exit early after two
# consecutive clean polls — no point waiting the full 90s if GitHub
# reconciled quickly. When called from the up-to-date path (arg: "quick"
# or unset), do one pass and return — no push happened, nothing to race.
#
# Usage:
#   sync_redisable_inherited_workflows           # single pass (up-to-date path)
#   sync_redisable_inherited_workflows polling   # poll for 90s (merged path)
sync_redisable_inherited_workflows() {
  local mode="${1:-quick}"

  # Derive the basename allowlist from FORK_OWNED_WORKFLOWS (single source
  # of truth). GitHub's actions/workflows API keys are basenames, not
  # full paths, so we strip the leading .github/workflows/ prefix.
  local basenames_joined="" f base
  for f in "${FORK_OWNED_WORKFLOWS[@]}"; do
    base="${f##*/}"
    basenames_joined="${basenames_joined}|${base}"
  done
  basenames_joined="${basenames_joined:1}"   # drop leading '|'

  echo "  fork-owned (allowlist): $(echo "$basenames_joined" | tr '|' ' ')"

  if [ "$mode" != "polling" ]; then
    # Single pass — no push happened, no race to worry about.
    local result disabled remaining
    result=$(_sync_disable_pass_once "$basenames_joined")
    disabled="${result% *}"
    remaining="${result#* }"
    echo "  single pass: $disabled disabled, $remaining still-active-and-failed-to-disable"
    return 0
  fi

  # Polling mode: after a push, GitHub takes seconds to register any
  # newly-modified workflow file. Poll every 10s up to 9 times (90s total),
  # exiting early after 2 consecutive clean polls.
  local attempt=0 clean_streak=0 total_disabled=0
  local result disabled remaining
  local max_attempts=9 sleep_secs=10

  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt + 1))
    result=$(_sync_disable_pass_once "$basenames_joined")
    disabled="${result% *}"
    remaining="${result#* }"
    total_disabled=$((total_disabled + disabled))

    if [ "$disabled" -eq 0 ] && [ "$remaining" -eq 0 ]; then
      clean_streak=$((clean_streak + 1))
      echo "  poll $attempt/$max_attempts: nothing to disable (clean streak: $clean_streak)"
      if [ $clean_streak -ge 2 ]; then
        echo "  → 2 consecutive clean polls, GitHub has reconciled — exiting early"
        break
      fi
    else
      clean_streak=0
      echo "  poll $attempt/$max_attempts: disabled $disabled this pass, $remaining failed"
    fi

    if [ $attempt -lt $max_attempts ]; then
      sleep $sleep_secs
    fi
  done

  echo "  summary: $total_disabled disabled across $attempt poll(s)"
}

# Push main and fast-forward stable. This is the "advance the baseline"
# step. Consumers pin @stable so anything that reaches stable is what
# they get. Only ever called after tests pass.
sync_publish_baseline() {
  git push origin "HEAD:$INTEGRATION_BRANCH"
  git push origin "HEAD:$STABLE_BRANCH"
  echo "  advanced $STABLE_BRANCH to $(git rev-parse --short HEAD)"
}
