#!/usr/bin/env bash
# Publishes the latest zmx and zap releases to the pacman and Pacstall repositories in q0wkp/pkgs.
#
# Usage: sync.sh [--no-publish] [--force]
#   --no-publish  Build and sign in a temporary directory, print it, and change nothing remote.
#   --force       Rebuild even if versions/ already records the latest release.
#
# It exits quietly when nothing changed, so it is safe to run from cron. versions/ is committed
# last, so a run that fails halfway is retried by the next one.
#
# Environment:
#   PKGS_GNUPGHOME    Directory of the signing key, if it isn't in the default keyring.
#   PKGS_NOTIFY_CMD   Command run with a message when a run fails, such as a notification script.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PKGS_REPO=q0wkp/pkgs
PACMAN_REPO=q0wkp
PACMAN_RELEASE=x86_64
ZMX_REPO=lutianyu2001/ZZZ_FORKED.zmx
ZAP_REPO=q0wkp/zap
GH_ACCOUNT=q0wkp
ARCH_IMAGE=docker.io/library/archlinux:latest

if [ -n "${PKGS_GNUPGHOME:-}" ]; then export GNUPGHOME=$PKGS_GNUPGHOME; fi
GH_TOKEN=$(gh auth token -u "$GH_ACCOUNT")
export GH_TOKEN

publish=true
force=false
for arg in "$@"; do
  case $arg in
    --no-publish) publish=false ;;
    --force) force=true ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

work=$(mktemp -d "${TMPDIR:-/tmp}/q0wkp-pkgs.XXXXXX")
repo_dir=$work/repo
mkdir -p "$repo_dir"
new_packages=() # package files added to the pacman repository in this run
changed=()

on_exit() {
  local status=$?
  if [ "$status" -ne 0 ] && [ -n "${PKGS_NOTIFY_CMD:-}" ]; then
    $PKGS_NOTIFY_CMD "q0wkp/pkgs sync failed, exit $status" || true
  fi
  if $publish || [ "$status" -ne 0 ]; then
    rm -rf "$work"
  fi
}
trap on_exit EXIT

log() { echo "$(date -u +%FT%TZ) $*"; }

latest_tag() { gh api "repos/$1/releases/latest" --jq .tag_name; }
recorded_tag() { cat "$ROOT/versions/$1" 2>/dev/null || true; }
sha256() { sha256sum "$1" | cut -d' ' -f1; }

# render TEMPLATE OUTPUT KEY=VALUE...
render() {
  local template=$1 output=$2 pair script=()
  shift 2
  for pair in "$@"; do
    script+=(-e "s#@@${pair%%=*}@@#${pair#*=}#g")
  done
  mkdir -p "$(dirname "$output")"
  sed "${script[@]}" "$template" > "$output"
  if grep -q '@@' "$output"; then
    echo "unfilled placeholder in $output" >&2
    exit 1
  fi
}

sign() { gpg --batch --yes --quiet --detach-sign --no-armor -u "$(cat "$ROOT/keys/fingerprint")" -o "$1.sig" "$1"; }

sync_zmx() {
  local tag version pkgver sha_x86_64 sha_aarch64 dir=$work/zmx file package
  tag=$(latest_tag "$ZMX_REPO")
  if ! $force && [ "$tag" = "$(recorded_tag zmx)" ]; then return 0; fi
  log "zmx: $tag"
  version=${tag#v}
  pkgver=${version//-/.}
  mkdir -p "$dir"
  gh release download "$tag" -R "$ZMX_REPO" -D "$dir" \
    -p "zmx-$version-linux-x86_64.tar.gz" -p "zmx-$version-linux-aarch64.tar.gz"
  sha_x86_64=$(sha256 "$dir/zmx-$version-linux-x86_64.tar.gz")
  sha_aarch64=$(sha256 "$dir/zmx-$version-linux-aarch64.tar.gz")

  local values=("TAG=$tag" "VERSION=$version" "PKGVER=$pkgver"
    "SHA256_X86_64=$sha_x86_64" "SHA256_AARCH64=$sha_aarch64")
  render "$ROOT/templates/zmx-bin/PKGBUILD.in" "$ROOT/arch/zmx-bin/PKGBUILD" "${values[@]}"
  render "$ROOT/templates/zmx-bin/zmx-bin.pacscript.in" \
    "$ROOT/packages/zmx-bin/zmx-bin.pacscript" "${values[@]}"
  render "$ROOT/templates/zmx-bin/SRCINFO.in" "$ROOT/packages/zmx-bin/.SRCINFO" "${values[@]}"

  # makepkg refuses to run as root, and root in a rootless container is this user.
  cp "$ROOT/arch/zmx-bin/PKGBUILD" "$dir/"
  podman run --rm --security-opt label=disable -v "$dir:/build" "$ARCH_IMAGE" bash -euc '
    pacman -Sy --noconfirm --needed base-devel >/dev/null
    useradd -m builder
    chown -R builder /build
    cd /build
    sudo -u builder makepkg --force --noconfirm 2>&1 | tail -2
    chown -R root:root /build'
  for file in "$dir"/zmx-bin-*.pkg.tar.zst; do
    package=$repo_dir/$(basename "$file")
    mv "$file" "$package"
    new_packages+=("$package")
  done
  changed+=("zmx $tag")
}

sync_zap() {
  local tag pkgver deb_asset arch_asset dir=$work/zap package
  tag=$(latest_tag "$ZAP_REPO")
  if ! $force && [ "$tag" = "$(recorded_tag zap)" ]; then return 0; fi

  # Releases before mod.3 have no Arch package, and their deb lacks dependencies. Skip those.
  arch_asset=$(gh api "repos/$ZAP_REPO/releases/tags/$tag" \
    --jq '[.assets[].name|select(endswith(".pkg.tar.zst"))]|first // ""')
  if [ -z "$arch_asset" ]; then
    log "zap: $tag has no Arch package, skipping"
    return 0
  fi
  deb_asset=$(gh api "repos/$ZAP_REPO/releases/tags/$tag" \
    --jq '[.assets[].name|select(endswith(".deb"))]|first // ""')
  [ -n "$deb_asset" ] || { echo "zap: $tag has no deb package" >&2; exit 1; }
  log "zap: $tag"

  mkdir -p "$dir"
  gh release download "$tag" -R "$ZAP_REPO" -D "$dir" -p "$arch_asset" -p "$deb_asset"
  pkgver=${tag#v}
  pkgver=${pkgver//-/.}
  local values=("TAG=$tag" "PKGVER=$pkgver" "DEB_ASSET=$deb_asset"
    "SHA256_DEB=$(sha256 "$dir/$deb_asset")")
  render "$ROOT/templates/zap-deb/zap-deb.pacscript.in" \
    "$ROOT/packages/zap-deb/zap-deb.pacscript" "${values[@]}"
  render "$ROOT/templates/zap-deb/SRCINFO.in" "$ROOT/packages/zap-deb/.SRCINFO" "${values[@]}"

  package=$repo_dir/$arch_asset
  mv "$dir/$arch_asset" "$package"
  new_packages+=("$package")
  changed+=("zap $tag")
}

# Adds the new packages to the existing database, so packages not updated in this run stay listed.
update_pacman_repo() {
  local package
  for package in "${new_packages[@]}"; do sign "$package"; done
  if gh release view "$PACMAN_RELEASE" -R "$PKGS_REPO" --json assets --jq '.assets[].name' 2>/dev/null \
    | grep -qx "$PACMAN_REPO.db"; then
    gh release download "$PACMAN_RELEASE" -R "$PKGS_REPO" -D "$work" -p "$PACMAN_REPO.db"
    mv "$work/$PACMAN_REPO.db" "$repo_dir/$PACMAN_REPO.db.tar.gz"
  fi
  podman run --rm --security-opt label=disable -v "$repo_dir:/repo" "$ARCH_IMAGE" bash -euc '
    cd /repo
    repo-add -q '"$PACMAN_REPO"'.db.tar.gz *.pkg.tar.zst'
  # repo-add leaves symlinks, and a release can only hold real files.
  for package in db files; do
    cp --remove-destination "$repo_dir/$PACMAN_REPO.$package.tar.gz" "$repo_dir/$PACMAN_REPO.$package"
    sign "$repo_dir/$PACMAN_REPO.$package"
  done
}

# Written here rather than with pacstall-programs' srcinfo.sh, so that this script, which holds a
# GitHub token and the signing key, never runs code it downloaded.
update_pacstall_index() {
  local dir
  (
    cd "$ROOT"
    ls -1 packages > packagelist
    {
      printf '### Auto-generated by scripts/sync.sh\n'
      for dir in packages/*/; do
        printf -- '---\n'
        cat "$dir.SRCINFO"
      done
    } > srclist
  )
}

publish_pacman_repo() {
  local package name asset
  gh release view "$PACMAN_RELEASE" -R "$PKGS_REPO" >/dev/null 2>&1 \
    || gh release create "$PACMAN_RELEASE" -R "$PKGS_REPO" --title "pacman repository ($PACMAN_RELEASE)" \
      --notes "Package files for the pacman repository. See the README." --latest=false
  # Packages go first, so the database never names a file that isn't there yet.
  gh release upload "$PACMAN_RELEASE" -R "$PKGS_REPO" --clobber \
    "${new_packages[@]}" "${new_packages[@]/%/.sig}"
  gh release upload "$PACMAN_RELEASE" -R "$PKGS_REPO" --clobber \
    "$repo_dir/$PACMAN_REPO.db" "$repo_dir/$PACMAN_REPO.db.sig" \
    "$repo_dir/$PACMAN_REPO.files" "$repo_dir/$PACMAN_REPO.files.sig"

  # Old versions are no longer in the database, so their files can go.
  for package in "${new_packages[@]}"; do
    name=$(basename "$package")
    name=${name%-*-*-*.pkg.tar.zst}
    while read -r asset; do
      [ -n "$asset" ] || continue
      case $asset in
        "$(basename "$package")" | "$(basename "$package").sig") ;;
        *) gh release delete-asset "$PACMAN_RELEASE" "$asset" -R "$PKGS_REPO" --yes ;;
      esac
    done < <(gh release view "$PACMAN_RELEASE" -R "$PKGS_REPO" --json assets --jq '.assets[].name' \
      | grep -E "^$name-[0-9].*\.pkg\.tar\.zst(\.sig)?$" || true)
  done
}

record_and_push() {
  local entry
  for entry in "${changed[@]}"; do
    echo "${entry#* }" > "$ROOT/versions/${entry%% *}"
  done
  (
    cd "$ROOT"
    git add arch packages packagelist srclist versions
    git commit -q -m "chore: update to ${changed[*]}"
    # The helper reads the token from the environment, which keeps it out of the process list.
    git -c credential.helper= \
      -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' \
      push -q "https://github.com/$PKGS_REPO.git" HEAD:main
  )
}

# Projects with their own packaging/pkgs/sync.sh share the database and this branch, so only one
# sync on this machine runs at a time, and this checkout starts from their latest commit.
exec 9> /tmp/q0wkp-pkgs.lock
flock 9
git -C "$ROOT" pull -q --ff-only origin main

sync_zmx
sync_zap
[ ${#changed[@]} -gt 0 ] || exit 0

update_pacman_repo
update_pacstall_index

if ! $publish; then
  echo "built in $work, nothing published:"
  ls -l "$repo_dir"
  exit 0
fi
publish_pacman_repo
record_and_push
log "published: ${changed[*]}"
