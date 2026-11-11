#!/usr/bin/env bash
# Installs the packages this repository has published for one target from the live repositories,
# the way the README tells users to, and checks them. The Verify workflow runs it on each platform;
# it can be run by hand on a clean system of the same kind.
#
# Usage: verify.sh pacman|pacstall|homebrew [NAME...]
#   NAME  A recipe under recipes/. All of them when none is given; recipes not yet published for
#         the target (no versions/<NAME>/<target>) are passed over.
#
#   pacman    On Arch, as root: trusts keys/signing-key.asc as published, adds the repository to
#             /etc/pacman.conf, installs each package, and checks that no ELF file it installed
#             lacks a shared library.
#   pacstall  On Ubuntu or Debian, as a user with sudo: installs Pacstall if missing, adds the
#             repository, installs each package, and checks its ELF files the same way.
#   homebrew  On macOS: taps the tap and checks its style. A cask is installed, and its app must
#             exist, run on this machine's architecture, pass codesign --verify, and have no
#             quarantine attribute when the cask removes it. A formula is installed and checked
#             with brew linkage.
# Then each package's VERIFY_COMMAND from its package.conf, when it has one, except for casks.
# A package that fails doesn't stop the others; the exit status is 1 then. It changes the system
# it runs on, so run it in a container or on a runner, not on a machine of one's own.
# The homebrew target runs under macOS's own bash, 3.2: no mapfile or associative arrays there, and
# an empty array is expanded as ${a[@]+"${a[@]}"} because set -u rejects it otherwise.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

target=${1:-}
case $target in
  pacman | pacstall | homebrew) shift ;;
  *) echo "usage: verify.sh pacman|pacstall|homebrew [NAME...]" >&2; exit 2 ;;
esac
recipes=$(recipe_names ${1+"$@"})
names=()
while IFS= read -r name; do [ -z "$name" ] || names+=("$name"); done <<<"$recipes"
raw=https://raw.githubusercontent.com/$PKGS_REPO/main

# Fails when an ELF file among those given needs a shared library the system lacks.
check_libraries() { # file...
  local file status=0 missing
  for file in "$@"; do
    is_elf "$file" || continue
    missing=$(ldd "$file" 2>/dev/null | grep 'not found' || true)
    if [ -n "$missing" ]; then
      echo "$file lacks: $missing" >&2
      status=1
    fi
  done
  return "$status"
}

setup_pacman() {
  grep -q "^\[$PACMAN_REPO\]" /etc/pacman.conf && return 0
  pacman-key --init >/dev/null
  curl -fsSL "$raw/keys/signing-key.asc" | pacman-key --add - >/dev/null
  pacman-key --lsign-key "$(curl -fsSL "$raw/keys/fingerprint")" >/dev/null
  printf '\n[%s]\nSigLevel = Required DatabaseRequired\nServer = %s\n' "$PACMAN_REPO" \
    "https://github.com/$PKGS_REPO/releases/download/\$arch" >> /etc/pacman.conf
}

setup_pacstall() {
  local url
  if ! command -v pacstall >/dev/null; then
    url=$(curl -fsSL https://api.github.com/repos/pacstall/pacstall/releases/latest \
      | grep -oE '"browser_download_url": *"[^"]+\.deb"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')
    curl -fsSL -o "$work/pacstall.deb" "$url"
    sudo apt-get update -qq
    sudo apt-get install -y -qq "$work/pacstall.deb" >/dev/null
  fi
  # Pacstall wants a terminal, and refuses to run without one.
  TERM=xterm script -qec "pacstall -P -A https://github.com/$PKGS_REPO/tree/main" /dev/null
}

tap_name() { local owner=${TAP_REPO%%/*} repo=${TAP_REPO#*/}; echo "$owner/${repo#homebrew-}"; }

setup_homebrew() {
  brew --version | head -1
  brew tap "$(tap_name)"
  # As the README has every user do: a Homebrew that asks for tap trust trusts the formula it is
  # told to install, but some versions then refuse to load another formula of the tap that this
  # one's conflicts_with names (6.0.18 on the macos-26-intel image did; 7.0.11 doesn't). A
  # Homebrew too old to know the command needs none.
  brew trust "$(tap_name)" 2>/dev/null || true
  brew style "$(tap_name)"
}

verify_pacman() {
  pacman -Syu --noconfirm --needed "$PACMAN_REPO/$PACMAN_PACKAGE"
  mapfile -t files < <(pacman -Qlq "$PACMAN_PACKAGE")
  check_libraries "${files[@]}"
}

verify_pacstall() {
  local gives
  gives=$(sed -n 's/^\tgives = //p' "$ROOT/packages/$PACSTALL_PACKAGE/.SRCINFO")
  TERM=xterm script -qec "pacstall -P -I $PACSTALL_PACKAGE" /dev/null
  mapfile -t files < <(dpkg -L "${gives:-$PACSTALL_PACKAGE}")
  check_libraries "${files[@]}"
}

verify_homebrew() {
  local name app executable only
  name=$(tap_name)/$(basename "$HOMEBREW" .rb)
  if [[ $HOMEBREW == Casks/* ]]; then
    # A cask for one architecture, which Homebrew refuses to install on the other Mac.
    only=$(sed -n 's/^  depends_on arch: :\([a-z0-9_]*\).*/\1/p' "$(brew --repository "$(tap_name)")/$HOMEBREW")
    case "$only:$(uname -m)" in
      arm64:x86_64 | x86_64:arm64 | intel:arm64)
        echo "$name is for $only only: not checked on $(uname -m)"
        return 0 ;;
    esac
    brew install --cask "$name"
    app=$(brew info --cask --json=v2 "$name" | jq -r '.casks[0].artifacts[] | .app? // empty | .[0]' | head -1)
    app=/Applications/$app
    [ -d "$app" ] || { echo "$app is missing" >&2; return 1; }
    executable=$(defaults read "$app/Contents/Info" CFBundleExecutable)
    [[ " $(lipo -archs "$app/Contents/MacOS/$executable") " == *" $(uname -m) "* ]] \
      || { echo "$app doesn't run on $(uname -m)" >&2; return 1; }
    codesign --verify --deep "$app"
    if grep -q com.apple.quarantine "$(brew --repository "$(tap_name)")/$HOMEBREW" \
      && xattr -p com.apple.quarantine "$app" >/dev/null 2>&1; then
      echo "$app still has the quarantine attribute" >&2
      return 1
    fi
  else
    brew install "$name"
    brew linkage --test "$name"
  fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/pkgs-verify.XXXXXX")
trap 'rm -rf "$work"' EXIT
"setup_$target"

failed=() checked=()
for name in ${names[@]+"${names[@]}"}; do
  load_recipe "$name"
  grep -qx "$target" <<<"$(recipe_targets)" || continue
  tag=$(published_tag "$name" "$target")
  [ -n "$tag" ] || { log "$name: not published for $target yet, skipping"; continue; }
  log "$name: verifying $target ($tag)"
  set +e
  (
    set -e
    "verify_$target"
    if [ -n "${VERIFY_COMMAND:-}" ] && [[ $target != homebrew || $HOMEBREW == Formula/* ]]; then
      bash -c "$VERIFY_COMMAND"
    fi
  )
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then checked+=("$name"); else log "$name: $target failed"; failed+=("$name"); fi
done
log "verified for $target: ${checked[*]:-nothing}"
if [ ${#failed[@]} -gt 0 ]; then
  echo "failed: ${failed[*]}" >&2
  exit 1
fi
