# Shared by the scripts beside it, which run the same way in GitHub Actions and on a machine of
# one's own. Settings for the whole repository are here; each package's are in
# recipes/<name>/package.conf.
# shellcheck shell=bash

PKGS_REPO=q0wkp/pkgs
PACMAN_REPO=q0wkp
PACMAN_RELEASE=x86_64
# The Homebrew tap that recipes with HOMEBREW write to.
TAP_REPO=q0wkp/homebrew-tap
# The gh account whose token a local run uses. In GitHub Actions the workflow gives GH_TOKEN.
GH_ACCOUNT=q0wkp
ARCH_IMAGE=docker.io/library/archlinux:latest
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

log() { echo "$(date -u +%FT%TZ) $*"; }

gh_token() {
  if [ -z "${GH_TOKEN:-}" ]; then
    GH_TOKEN=$(gh auth token -u "$GH_ACCOUNT")
    export GH_TOKEN
  fi
}

# Like gh api, but returns 2 for a 404 and 1 for any other failure. Callers must tell them apart:
# a failed request that passed for a missing one would start a new database over the shared one.
gh_get() { # endpoint jq-filter
  local err
  err=$(mktemp)
  if gh api "$1" --jq "$2" 2> "$err"; then rm -f "$err"; return 0; fi
  if grep -q 'HTTP 404' "$err"; then rm -f "$err"; return 2; fi
  cat "$err" >&2
  rm -f "$err"
  return 1
}

# Tags, asset and recipe names end up inside rendered scripts that are sourced or run, and come
# from workflow inputs and from other people's releases, so only plain names pass.
plain_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; }

# Whether a file is an ELF program or library, and not a link to one.
is_elf() { # file
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(head -c4 "$1" | od -An -c | tr -d ' ')" = 177ELF ]
}

# Prints the recipes to work on: those named, or all of them.
recipe_names() { # [name...]
  local name
  if [ $# -eq 0 ]; then
    for name in "$ROOT"/recipes/*/package.conf; do
      [ -e "$name" ] || continue
      name=${name%/package.conf}
      echo "${name##*/}"
    done
    return 0
  fi
  for name in "$@"; do
    if ! plain_name "$name" || [ ! -f "$ROOT/recipes/$name/package.conf" ]; then
      echo "no recipe named $name in recipes/" >&2
      return 1
    fi
    echo "$name"
  done
}

# Sets NAME, RECIPE and the package's settings in the calling shell.
load_recipe() { # name
  unset SOURCE_REPO PACMAN_PACKAGE PACSTALL_PACKAGE HOMEBREW ARCH_MODE ASSETS SOURCE_TARBALL README_NOTES VERIFY_COMMAND
  unset PACMAN_GIT_PACKAGE PACSTALL_GIT_PACKAGE HOMEBREW_GIT
  NAME=$1
  RECIPE=$ROOT/recipes/$1
  # shellcheck source=/dev/null
  source "$RECIPE/package.conf"
  PACMAN_PACKAGE=${PACMAN_PACKAGE:-} PACSTALL_PACKAGE=${PACSTALL_PACKAGE:-} HOMEBREW=${HOMEBREW:-}
  ARCH_MODE=${ARCH_MODE:-} SOURCE_TARBALL=${SOURCE_TARBALL:-false} README_NOTES=${README_NOTES:-}
  PACMAN_GIT_PACKAGE=${PACMAN_GIT_PACKAGE:-} PACSTALL_GIT_PACKAGE=${PACSTALL_GIT_PACKAGE:-}
  HOMEBREW_GIT=${HOMEBREW_GIT:-}
  [ -n "${ASSETS+set}" ] || ASSETS=()
}

# The targets the loaded recipe publishes to: pacman, pacstall and homebrew, each only when the
# recipe names its package, so a recipe can leave out a platform its project doesn't build for.
# pacman-git, pacstall-git and homebrew-git are the packages that build the project's default
# branch from Git on the user's own machine: for them only the PKGBUILD, the pacscript and the
# formula are published, as text, and nothing is built here.
recipe_targets() {
  [ -z "$PACMAN_PACKAGE" ] || echo pacman
  [ -z "$PACSTALL_PACKAGE" ] || echo pacstall
  [ -z "$HOMEBREW" ] || echo homebrew
  [ -z "$PACMAN_GIT_PACKAGE" ] || echo pacman-git
  [ -z "$PACSTALL_GIT_PACKAGE" ] || echo pacstall-git
  [ -z "$HOMEBREW_GIT" ] || echo homebrew-git
}

# The template that the loaded recipe renders for a target; nothing for a prebuilt pacman package.
target_template() { # target
  case $1 in
    pacman) [ "$ARCH_MODE" != build ] || echo "$RECIPE/PKGBUILD.in" ;;
    pacstall) echo "$RECIPE/$PACSTALL_PACKAGE.pacscript.in" ;;
    homebrew) echo "$RECIPE/homebrew.rb.in" ;;
    pacman-git) echo "$RECIPE/$PACMAN_GIT_PACKAGE.PKGBUILD.in" ;;
    pacstall-git) echo "$RECIPE/$PACSTALL_GIT_PACKAGE.pacscript.in" ;;
    homebrew-git) echo "$RECIPE/homebrew-git.rb.in" ;;
  esac
}

# The ASSETS keys a target needs, read from the placeholders of its template, so that each target
# is published as soon as the release has its own files; SOURCE stands for the tag's tarball.
target_keys() { # target
  local template
  if [ "$1" = pacman ] && [ "$ARCH_MODE" = prebuilt ]; then echo PKG; return 0; fi
  template=$(target_template "$1")
  # A template that names no release file, as those built from Git, needs none.
  { grep -oE '@@(ASSET|SHA256)_[A-Za-z0-9_]+@@' "$template" || true; } \
    | sed -E 's/^@@(ASSET|SHA256)_//; s/@@$//' | sort -u
}

# The release a target was last published from, or nothing.
published_tag() { # name target
  cat "$ROOT/versions/$1/$2" 2>/dev/null || true
}

# Runs a script in an Arch container with DIR at /work, and gives the files back to this user.
# Rootless podman maps this user to root in the container; docker's root is the real one.
run_arch() { # dir script [pull]
  local engine=${PKGS_CONTAINER:-} owner pull=()
  if [ -z "$engine" ]; then
    if [ "${GITHUB_ACTIONS:-}" != true ] && command -v podman >/dev/null; then engine=podman; else engine=docker; fi
  fi
  if [ "$engine" = podman ] && [ "$(podman info --format '{{.Host.Security.Rootless}}')" = true ]; then
    owner=0:0
  else
    owner=$(id -u):$(id -g)
  fi
  # An old image's keyring rejects current packages.
  if [ "${3:-}" = pull ]; then
    if [ "$engine" = podman ]; then pull=(--pull=newer); else pull=(--pull=always); fi
  fi
  "$engine" run --rm "${pull[@]}" --security-opt label=disable -v "$1:/work" -e OWNER="$owner" \
    "$ARCH_IMAGE" bash -euc 'trap '\''chown -R "$OWNER" /work'\'' EXIT
'"$2"
}
