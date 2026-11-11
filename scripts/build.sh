#!/usr/bin/env bash
# Builds the packages whose project has a release newer than versions/ records. It needs neither
# the signing key nor write access, and changes nothing outside DIR: publish.sh takes it from there.
#
# Usage: build.sh --out DIR [--force] [NAME...]
#   NAME     A recipe under recipes/. All of them when none is given.
#   --force  Build even if versions/ already records the latest release.
#
# A recipe publishes to some of pacman, pacstall and homebrew (recipe_targets in lib.sh), and each
# target is built on its own: when versions/<NAME>/<target> is older than the latest release and
# the release has the files the target's template names. DIR/<NAME>/<target>/ gets them: for pacman
# the .pkg.tar.zst and the rendered PKGBUILD (unless the release carries the package itself), for
# pacstall the pacscript and its .SRCINFO, for homebrew the cask or formula; for pacman-git the
# rendered PKGBUILD, for pacstall-git the pacscript and its .SRCINFO and for homebrew-git the
# formula, which the user's machine builds from Git, so nothing is built for them here; and a file
# named tag,
# written last, so a target that failed halfway has none. A target whose files the release lacks
# is skipped, and a later run picks it up. A target or recipe that fails doesn't stop the others;
# the exit status is 1 then. A pacman or pacstall target fails when a program it installs needs a
# newer glibc than its dependencies ask for (glibc>= on Arch; libc6>= in a pacscript, libc6 (>= ) in
# a .deb), which needs
# readelf, dpkg-deb and zstd, as on the Ubuntu runner.
#
# In GitHub Actions it sets the step output built=true when DIR has something to publish.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

out="" force=false names=()
while [ $# -gt 0 ]; do
  case $1 in
    --out) out=$2; shift 2 ;;
    --force) force=true; shift ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) names+=("$1"); shift ;;
  esac
done
[ -n "$out" ] || { echo "--out is required" >&2; exit 2; }
mkdir -p "$out"
out=$(cd "$out" && pwd)
# Not mapfile < <(...): a failure there would go unnoticed.
recipes=$(recipe_names "${names[@]}")
names=()
[ -z "$recipes" ] || mapfile -t names <<<"$recipes"
gh_token

# Fills @@KEY@@ placeholders. Later steps source or run the result, so it must come out complete.
render() { # template output
  local script=() key
  for key in "${!values[@]}"; do script+=(-e "s#@@$key@@#${values[$key]}#g"); done
  sed "${script[@]}" "$1" > "$2"
  if grep -q '@@' "$2"; then
    echo "unfilled placeholder in $2" >&2
    return 1
  fi
}

# Writes .SRCINFO from the rendered pacscript, which came from this repository, not a download.
write_srcinfo() { # pacscript output
  (
    set +eu
    # shellcheck source=/dev/null
    source "$1"
    printf 'pkgbase = %s\n' "$pkgname"
    for var in gives pkgver pkgrel pkgdesc url; do
      [ -z "${!var:-}" ] || printf '\t%s = %s\n' "$var" "${!var}"
    done
    for var in arch maintainer depends makedepends optdepends pacdeps conflicts breaks replaces \
      source sha256sums source_amd64 sha256sums_amd64 source_arm64 sha256sums_arm64; do
      declare -n list=$var 2>/dev/null || continue
      for item in "${list[@]}"; do printf '\t%s = %s\n' "$var" "$item"; done
      unset -n list
    done
    printf '\npkgname = %s\n' "$pkgname"
  ) > "$2"
}

# makepkg refuses to run as root, so it builds as a throwaway user with sudo for dependencies.
build_arch_package() { # build-dir
  run_arch "$1" '
    pacman -Syu --noconfirm --needed base-devel >/dev/null
    useradd -m builder
    echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
    chown -R builder /work
    cd /work
    sudo -u builder makepkg --syncdeps --force --noconfirm 2>&1 | tail -2' pull
}

# The highest GLIBC_x.y symbol version the ELF files under a directory need, or nothing when none
# needs glibc (static, or built against musl).
glibc_needed() { # dir
  local file
  while IFS= read -r -d '' file; do
    is_elf "$file" || continue
    readelf -V --wide "$file" 2>/dev/null | grep -oE 'Name: GLIBC_[0-9]+(\.[0-9]+)+' || true
  done < <(find "$1" -type f -print0) | sed 's/^Name: GLIBC_//' | sort -uV | tail -n1
}

# Fails when what a package needs is newer than the glibc its dependencies ask for, so that a
# system too old for it refuses to install it rather than installing a program that can't start.
glibc_floor_ok() { # file needed declared fix
  [ -n "$2" ] || return 0
  if [ -z "$3" ] || [ "$(printf '%s\n%s\n' "$2" "$3" | sort -V | tail -n1)" != "$3" ]; then
    echo "$NAME: $(basename "$1") needs glibc $2 but its dependencies ask for ${3:-no version of it}: ${4//X/$2}" >&2
    return 1
  fi
}

# Checks the minimum glibc of what a target installs. A source pacscript is left out: it builds on
# the user's system, against the glibc there.
check_glibc_floor() { # target dir
  local file key unpacked declared fix status=0
  case $1 in
    pacman)
      if [ "$ARCH_MODE" = build ]; then
        fix="add 'glibc>=X' to depends in recipes/$NAME/PKGBUILD.in"
      else
        fix="the project's package has to depend on 'glibc>=X'"
      fi
      for file in "$2"/*.pkg.tar.zst; do
        unpacked=$(mktemp -d "$work/unpacked.XXXXXX")
        tar --zstd -xf "$file" -C "$unpacked"
        declared=$(sed -n 's/^depend = glibc>=//p' "$unpacked/.PKGINFO" | head -n1)
        glibc_floor_ok "$file" "$(glibc_needed "$unpacked")" "$declared" "$fix" || status=1
        rm -rf "$unpacked"
      done ;;
    pacstall)
      for key in $(target_keys pacstall); do
        [ "$key" != SOURCE ] || continue
        file=$work/assets/${values[ASSET_$key]}
        unpacked=$(mktemp -d "$work/unpacked.XXXXXX")
        if [[ $file == *.deb ]]; then
          dpkg-deb -x "$file" "$unpacked"
          # Debian's control syntax.
          declared=$(dpkg-deb -f "$file" Depends | grep -oE 'libc6(:[a-z0-9]+)? \(>= *[0-9][0-9.]*\)' || true)
          fix="the project's .deb has to depend on 'libc6 (>= X)'"
        else
          tar -xf "$file" -C "$unpacked"
          # Pacstall's syntax, name>=version, which it writes into the .deb as libc6 (>= version).
          declared=$(grep -v '^ *#' "$2/$PACSTALL_PACKAGE.pacscript" \
            | grep -oE 'libc6(:[a-z0-9]+)?>= *[0-9][0-9.]*' || true)
          fix="add 'libc6>=X' to depends in recipes/$NAME/$PACSTALL_PACKAGE.pacscript.in"
        fi
        declared=$(sed -E 's/.*>= *//; s/\)$//' <<<"$declared" | head -n1)
        glibc_floor_ok "$file" "$(glibc_needed "$unpacked")" "$declared" "$fix" || status=1
        rm -rf "$unpacked"
      done ;;
  esac
  return "$status"
}

build_one() { # name
  load_recipe "$1"
  local tag status=0 version dest entry key pattern asset candidate release_assets target missing
  local -a wanted=() ready=() needed=()
  local -A found=()
  tag=$(gh_get "repos/$SOURCE_REPO/releases/latest" .tag_name) || status=$?
  [ "$status" -ne 1 ] || return 1
  if [ "$status" -eq 2 ]; then
    log "$NAME: $SOURCE_REPO has no release yet, skipping"
    return 0
  fi
  plain_name "$tag" || { echo "$NAME: unusual tag name: $tag" >&2; return 1; }
  for target in $(recipe_targets); do
    if $force || [ "$tag" != "$(published_tag "$NAME" "$target")" ]; then wanted+=("$target"); fi
  done
  [ ${#wanted[@]} -gt 0 ] || return 0

  version=${tag#v}
  declare -A values=([TAG]=$tag [VERSION]=$version [PKGVER]=${version//[^0-9A-Za-z.]/.})
  release_assets=$(gh api "repos/$SOURCE_REPO/releases/tags/$tag" --jq '.assets[].name')
  for entry in "${ASSETS[@]}"; do
    key=${entry%%=*}
    pattern=${entry#*=}
    pattern=${pattern//\{version\}/$version}
    while read -r candidate; do
      # shellcheck disable=SC2254
      case $candidate in $pattern) found[$key]=$candidate; break ;; esac
    done <<< "$release_assets"
  done
  [ "$SOURCE_TARBALL" != true ] || found[SOURCE]=source

  # Each target goes out once the release has the files it needs, whatever the others lack: a
  # release with only a .deb still reaches Pacstall, and the rest follow when they are uploaded.
  for target in "${wanted[@]}"; do
    missing=()
    for key in $(target_keys "$target"); do
      [ -n "${found[$key]:-}" ] || missing+=("$key")
    done
    if [ ${#missing[@]} -gt 0 ]; then
      log "$NAME: $tag has no ${missing[*]} for $target yet, skipping $target"
      continue
    fi
    ready+=("$target")
    mapfile -t -O "${#needed[@]}" needed < <(target_keys "$target")
  done
  [ ${#ready[@]} -gt 0 ] || return 0

  work=$(mktemp -d "${TMPDIR:-/tmp}/pkgs-build-$NAME.XXXXXX")
  # build_one runs in a subshell of its own, so this fires when it returns. work is not local: the
  # trap runs after the function has returned.
  trap 'rm -rf "$work"' EXIT
  mkdir "$work/assets"
  for key in $(printf '%s\n' "${needed[@]}" | sort -u); do
    [ "$key" != SOURCE ] || continue
    asset=${found[$key]}
    plain_name "$asset" || { echo "$NAME: unusual asset name: $asset" >&2; return 1; }
    gh release download "$tag" -R "$SOURCE_REPO" -D "$work/assets" -p "$asset"
    values[ASSET_$key]=$asset
    values[SHA256_$key]=$(sha256sum "$work/assets/$asset" | cut -d' ' -f1)
  done
  if [[ " ${needed[*]} " == *" SOURCE "* ]]; then
    curl -fsSL --proto =https -o "$work/assets/$NAME-$version.tar.gz" \
      "https://github.com/$SOURCE_REPO/archive/refs/tags/$tag.tar.gz"
    values[SHA256_SOURCE]=$(sha256sum "$work/assets/$NAME-$version.tar.gz" | cut -d' ' -f1)
  fi

  dest=$out/$NAME
  mkdir -p "$dest"
  status=0
  for target in "${ready[@]}"; do
    log "$NAME: building $tag for $target"
    rm -rf "${dest:?}/$target"
    mkdir "$dest/$target"
    # One target failing, such as a makepkg run cut off by a mirror, leaves the others to publish.
    # Its directory gets no tag, so publish.sh passes it over. errexit is off around the subshell
    # because bash would ignore it inside one that is the left of a ||.
    set +e
    (set -e; build_target "$target" "$dest/$target")
    if [ $? -ne 0 ]; then
      log "$NAME: $target failed"
      rm -rf "${dest:?}/$target"
      status=1
    fi
    set -e
  done
  return "$status"
}

build_target() { # target dir
  case $1 in
    pacstall)
      render "$RECIPE/$PACSTALL_PACKAGE.pacscript.in" "$2/$PACSTALL_PACKAGE.pacscript"
      write_srcinfo "$2/$PACSTALL_PACKAGE.pacscript" "$2/.SRCINFO"
      check_glibc_floor pacstall "$2" ;;
    pacman)
      if [ "$ARCH_MODE" = build ]; then
        render "$RECIPE/PKGBUILD.in" "$2/PKGBUILD"
        rm -rf "$work/build"
        mkdir "$work/build"
        cp "$2/PKGBUILD" "$work/assets"/* "$work/build/"
        build_arch_package "$work/build"
        mv "$work/build"/*.pkg.tar.zst "$2/"
      else
        cp "$work/assets/${values[ASSET_PKG]}" "$2/"
      fi
      check_glibc_floor pacman "$2" ;;
    homebrew)
      render "$RECIPE/homebrew.rb.in" "$2/${HOMEBREW##*/}" ;;
    # Rendered at each release only for the version they start from: the user's machine builds
    # them, against the libraries there, so there is no package to check either.
    pacman-git)
      render "$RECIPE/$PACMAN_GIT_PACKAGE.PKGBUILD.in" "$2/PKGBUILD" ;;
    pacstall-git)
      render "$RECIPE/$PACSTALL_GIT_PACKAGE.pacscript.in" "$2/$PACSTALL_GIT_PACKAGE.pacscript"
      write_srcinfo "$2/$PACSTALL_GIT_PACKAGE.pacscript" "$2/.SRCINFO" ;;
    homebrew-git)
      render "$RECIPE/homebrew-git.rb.in" "$2/${HOMEBREW_GIT##*/}" ;;
  esac
  echo "$tag" > "$2/tag"
}

failed=()
for name in "${names[@]}"; do
  # A subshell, so one recipe's settings and failure stay its own. errexit is off around it because
  # bash would ignore it inside a subshell that is the condition of an if or the left of a ||.
  set +e
  (set -e; build_one "$name")
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    log "$name: build failed"
    failed+=("$name")
  fi
done

built=false
for file in "$out"/*/*/tag; do [ -e "$file" ] && built=true; done
[ -z "${GITHUB_OUTPUT:-}" ] || echo "built=$built" >> "$GITHUB_OUTPUT"
if [ ${#failed[@]} -gt 0 ]; then
  echo "failed: ${failed[*]}" >&2
  exit 1
fi
