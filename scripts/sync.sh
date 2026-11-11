#!/usr/bin/env bash
# Does on this machine what the Sync workflow does in GitHub Actions: build.sh, then publish.sh,
# from this checkout. For when Actions can't, or to try a recipe before publishing it.
#
# Usage: sync.sh [--no-publish] [--force] [NAME...]
#   NAME          A recipe under recipes/. All of them when none is given.
#   --no-publish  Build, sign and write the repositories in a temporary directory, print it, and
#                 change nothing remote.
#   --force       Rebuild even if versions/ already records the latest release.
#
# Needs podman (or docker), gh with a token for q0wkp, and the signing key in this user's keyring
# (or PKGS_SIGNING_KEY, see publish.sh). PKGS_NOTIFY_CMD, when set, is run with a message when the
# run fails.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

publish=true build_args=()
for arg in "$@"; do
  case $arg in
    --no-publish) publish=false ;;
    --force) build_args+=(--force) ;;
    -*) echo "unknown argument: $arg" >&2; exit 2 ;;
    *) build_args+=("$arg") ;;
  esac
done
gh_token

out=$(mktemp -d "${TMPDIR:-/tmp}/pkgs-sync.XXXXXX")
on_exit() {
  local status=$?
  rm -rf "$out"
  if [ "$status" -ne 0 ] && [ -n "${PKGS_NOTIFY_CMD:-}" ]; then
    $PKGS_NOTIFY_CMD "pkgs sync failed, exit $status" || true
  fi
}
trap on_exit EXIT

# Checked before the build and again before publishing, since a project can ask for its package
# while this builds.
workflow_idle() {
  local running
  running=$(gh run list -R "$PKGS_REPO" --workflow sync.yml --json status \
    --jq '[.[] | select(.status != "completed")] | length')
  if [ "$running" != 0 ]; then
    echo "the Sync workflow is running in $PKGS_REPO; try again when it has finished" >&2
    exit 1
  fi
}

if $publish; then
  # The pacman database is one file that every publish rewrites: two at once would drop a package.
  exec 9> "${TMPDIR:-/tmp}/q0wkp-pkgs.lock"
  flock -n 9 || { echo "another sync.sh is running on this machine" >&2; exit 1; }
  workflow_idle
  [ "$(git -C "$ROOT" symbolic-ref --short HEAD)" = main ] || { echo "$ROOT is not on main" >&2; exit 1; }
  git -C "$ROOT" pull -q --ff-only "https://github.com/$PKGS_REPO.git" main
fi

status=0
"$ROOT/scripts/build.sh" --out "$out" "${build_args[@]}" || status=$?
if $publish; then
  workflow_idle
  "$ROOT/scripts/publish.sh" "$out"
else
  "$ROOT/scripts/publish.sh" --dry-run "$out"
fi
exit "$status"
