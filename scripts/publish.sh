#!/usr/bin/env bash
# Publishes what build.sh wrote: signs the pacman packages and adds them to the pacman database in
# the x86_64 release, commits the casks and formulae to the Homebrew tap, and commits the PKGBUILDs,
# the Pacstall files, versions/ and the README to main. Each target of a recipe goes out on its
# own. The packages built from Git (pacman-git, pacstall-git, homebrew-git) are text alone, a
# PKGBUILD in arch/, a pacscript in packages/ and a formula in the tap: they never enter the pacman
# database. It runs no code from the projects; it reads only the files it expects from DIR.
#
# Usage: publish.sh [--dry-run] DIR
#   --dry-run  Sign and build the pacman database and the Pacstall files in a temporary directory,
#              print it, and change nothing remote.
#
# Environment:
#   GH_TOKEN                  A token that can write to the repository; a local run takes q0wkp's
#                             from gh.
#   PKGS_TAP_DEPLOY_KEY       The private half of a deploy key with write access to the tap, for
#                             GitHub Actions, whose own token can't push there.
#   PKGS_SIGNING_KEY          The secret signing key, armored, with PKGS_SIGNING_PASSPHRASE: it is
#                             imported into a temporary keyring, as in GitHub Actions. Without it the
#                             key is taken from this user's keyring, and gpg-agent asks for the
#                             passphrase.
#
# Packages go up first and the database after them, so it never names a file that isn't there.
# versions/ is committed last, after the tap, so a run that fails halfway is redone by the next one.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dry_run=false in=""
for arg in "$@"; do
  case $arg in
    --dry-run) dry_run=true ;;
    -*) echo "unknown argument: $arg" >&2; exit 2 ;;
    *) in=$arg ;;
  esac
done
[ -n "$in" ] && [ -d "$in" ] || { echo "usage: publish.sh [--dry-run] DIR" >&2; exit 2; }
gh_token

work=$(mktemp -d "${TMPDIR:-/tmp}/pkgs-publish.XXXXXX")
keep=false
cleanup() {
  [ ! -d "$work/gnupg" ] || gpgconf --homedir "$work/gnupg" --kill gpg-agent 2>/dev/null || true
  $keep || rm -rf "$work"
}
trap cleanup EXIT
repo_dir=$work/repo
mkdir -p "$repo_dir"

# The tree that gets the text files: the checkout itself, or a copy of it for a dry run.
if $dry_run; then
  tree=$work/tree
  cp -a "$ROOT/." "$tree"
else
  tree=$ROOT
  # The README and the indexes are rewritten from what main has now.
  [ "$(git -C "$tree" symbolic-ref --short HEAD)" = main ] || { echo "$tree is not on main" >&2; exit 1; }
  git -C "$tree" pull -q --ff-only "https://github.com/$PKGS_REPO.git" main
fi
fingerprint=$(cat "$tree/keys/fingerprint")

gpg_args=(--batch --yes --quiet)
if [ -n "${PKGS_SIGNING_KEY:-}" ]; then
  install -d -m700 "$work/gnupg"
  gpg_args+=(--homedir "$work/gnupg" --pinentry-mode loopback --passphrase-fd 3)
  gpg "${gpg_args[@]}" --import 3<<<"${PKGS_SIGNING_PASSPHRASE:-}" <<<"$PKGS_SIGNING_KEY"
elif [ ! -t 0 ]; then
  # Without a terminal, gpg-agent could otherwise open a passphrase dialog nobody answers.
  gpg_args+=(--pinentry-mode error)
fi
sign() { # file
  gpg "${gpg_args[@]}" --detach-sign --no-armor -u "$fingerprint" -o "$1.sig" "$1" \
    3<<<"${PKGS_SIGNING_PASSPHRASE:-}"
}

# What build.sh wrote, checked against the recipes, since DIR may come from another job. Each entry
# is one target of one recipe: "name target tag file", file being the target's main output.
entries=()
for tagfile in "$in"/*/*/tag; do
  [ -e "$tagfile" ] || continue
  dir=${tagfile%/tag}
  target=${dir##*/}
  name=${dir%/*}
  name=${name##*/}
  recipe_names "$name" >/dev/null
  load_recipe "$name"
  grep -qx "$target" <<<"$(recipe_targets)" || { echo "$name: no target $target in its recipe" >&2; exit 1; }
  tag=$(cat "$tagfile")
  plain_name "$tag" || { echo "$name: unusual tag: $tag" >&2; exit 1; }
  case $target in
    pacman)
      found=("$dir/$PACMAN_PACKAGE"-*-*-*.pkg.tar.zst)
      if [ ${#found[@]} -ne 1 ] || [ ! -f "${found[0]}" ] || ! plain_name "$(basename "${found[0]}")"; then
        echo "$name: expected one $PACMAN_PACKAGE package in $dir" >&2
        exit 1
      fi
      if [ "$ARCH_MODE" = build ] && [ ! -f "$dir/PKGBUILD" ]; then
        echo "$name: $dir/PKGBUILD is missing" >&2
        exit 1
      fi
      file=${found[0]} ;;
    pacstall)
      for file in "$PACSTALL_PACKAGE.pacscript" .SRCINFO; do
        [ -f "$dir/$file" ] || { echo "$name: $dir/$file is missing" >&2; exit 1; }
      done
      file=$dir/$PACSTALL_PACKAGE.pacscript ;;
    homebrew)
      [[ $HOMEBREW =~ ^(Casks|Formula)/[a-z0-9][a-z0-9@._+-]*\.rb$ ]] \
        || { echo "$name: HOMEBREW must be Casks/<token>.rb or Formula/<name>.rb" >&2; exit 1; }
      file=$dir/${HOMEBREW##*/}
      [ -f "$file" ] || { echo "$name: $file is missing" >&2; exit 1; } ;;
    pacman-git)
      file=$dir/PKGBUILD
      [ -f "$file" ] || { echo "$name: $file is missing" >&2; exit 1; } ;;
    pacstall-git)
      for file in "$PACSTALL_GIT_PACKAGE.pacscript" .SRCINFO; do
        [ -f "$dir/$file" ] || { echo "$name: $dir/$file is missing" >&2; exit 1; }
      done
      file=$dir/$PACSTALL_GIT_PACKAGE.pacscript ;;
    homebrew-git)
      [[ $HOMEBREW_GIT =~ ^Formula/[a-z0-9][a-z0-9@._+-]*\.rb$ ]] \
        || { echo "$name: HOMEBREW_GIT must be Formula/<name>.rb" >&2; exit 1; }
      file=$dir/${HOMEBREW_GIT##*/}
      [ -f "$file" ] || { echo "$name: $file is missing" >&2; exit 1; } ;;
    *) echo "$name: unknown target $target" >&2; exit 1 ;;
  esac
  entries+=("$name $target $tag $file")
done
if [ ${#entries[@]} -eq 0 ]; then
  log "nothing to publish"
  exit 0
fi
has_target() { printf '%s\n' "${entries[@]}" | cut -d' ' -f2 | grep -qx "$1"; }
# Whether anything goes to the Homebrew tap.
has_tap_target() { has_target homebrew || has_target homebrew-git; }

if has_target pacman; then
  # Fails here, before anything is uploaded, if the key can't sign.
  sign "$tree/keys/fingerprint"
  rm "$tree/keys/fingerprint.sig"

  # Adds the packages to the existing database, so every other package stays listed.
  assets="" status=0
  assets=$(gh_get "repos/$PKGS_REPO/releases/tags/$PACMAN_RELEASE" '.assets[].name') || status=$?
  [ "$status" -ne 1 ] || exit 1
  # gh deletes an asset before re-uploading it, so a failed upload can leave packages without a
  # database. Starting a new one would drop every other package.
  if grep -q '\.pkg\.tar\.zst$' <<<"$assets" && ! grep -qx "$PACMAN_REPO.db" <<<"$assets"; then
    echo "$PKGS_REPO has packages but no $PACMAN_REPO.db, restore it before publishing" >&2
    exit 1
  fi
  for kind in db files; do
    if grep -qx "$PACMAN_REPO.$kind" <<<"$assets"; then
      gh release download "$PACMAN_RELEASE" -R "$PKGS_REPO" -D "$work" -p "$PACMAN_REPO.$kind"
      mv "$work/$PACMAN_REPO.$kind" "$repo_dir/$PACMAN_REPO.$kind.tar.gz"
    fi
  done
  for entry in "${entries[@]}"; do
    read -r name target tag file <<<"$entry"
    [ "$target" = pacman ] || continue
    cp "$file" "$repo_dir/"
    sign "$repo_dir/$(basename "$file")"
  done
  run_arch "$repo_dir" "repo-add -q /work/$PACMAN_REPO.db.tar.gz /work/*.pkg.tar.zst"
  # repo-add leaves symlinks, and a release can only hold real files.
  for kind in db files; do
    cp --remove-destination "$repo_dir/$PACMAN_REPO.$kind.tar.gz" "$repo_dir/$PACMAN_REPO.$kind"
    sign "$repo_dir/$PACMAN_REPO.$kind"
  done
fi

# The Homebrew tap, cloned read-only here; pushed below, after the pacman release.
tap=$work/tap
if has_tap_target; then
  git clone -q --depth 1 "https://github.com/$TAP_REPO.git" "$tap"
fi

# The text files: the PKGBUILDs, the pacscripts and the casks and formulae.
for entry in "${entries[@]}"; do
  read -r name target tag file <<<"$entry"
  load_recipe "$name"
  case $target in
    pacman)
      if [ "$ARCH_MODE" = build ]; then
        mkdir -p "$tree/arch/$PACMAN_PACKAGE"
        cp "$(dirname "$file")/PKGBUILD" "$tree/arch/$PACMAN_PACKAGE/"
      fi ;;
    pacstall)
      mkdir -p "$tree/packages/$PACSTALL_PACKAGE"
      cp "$file" "$(dirname "$file")/.SRCINFO" "$tree/packages/$PACSTALL_PACKAGE/" ;;
    homebrew)
      mkdir -p "$tap/${HOMEBREW%/*}"
      cp "$file" "$tap/$HOMEBREW" ;;
    pacman-git)
      mkdir -p "$tree/arch/$PACMAN_GIT_PACKAGE"
      cp "$file" "$tree/arch/$PACMAN_GIT_PACKAGE/" ;;
    pacstall-git)
      mkdir -p "$tree/packages/$PACSTALL_GIT_PACKAGE"
      cp "$file" "$(dirname "$file")/.SRCINFO" "$tree/packages/$PACSTALL_GIT_PACKAGE/" ;;
    homebrew-git)
      mkdir -p "$tap/${HOMEBREW_GIT%/*}"
      cp "$file" "$tap/$HOMEBREW_GIT" ;;
  esac
  mkdir -p "$tree/versions/$name"
  echo "$tag" > "$tree/versions/$name/$target"
done
(
  cd "$tree"
  find packages -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort > packagelist
  {
    printf '### Auto-generated by scripts/publish.sh\n'
    while read -r package; do
      printf -- '---\n'
      cat "packages/$package/.SRCINFO"
    done < packagelist
  } > srclist
)

# The README's package list: a row per recipe, naming each package once it has been published.
cell() { # target package
  if [ -n "$2" ] && [ -e "$tree/versions/$NAME/$1" ]; then printf '`%s`' "$2"; else printf -- '—'; fi
}
# The packages built from Git, in one cell: one name when every repository that has one calls it
# the same, else each with its repository.
git_cell() {
  local pair where package labeled=() names=()
  for pair in "pacman-git:pacman:$PACMAN_GIT_PACKAGE" "pacstall-git:Pacstall:$PACSTALL_GIT_PACKAGE" \
    "homebrew-git:Homebrew:$(basename "$HOMEBREW_GIT" .rb)"; do
    IFS=: read -r target where package <<<"$pair"
    package=$(cell "$target" "$package")
    [ "$package" != — ] || continue
    labeled+=("$package ($where)")
    names+=("$package")
  done
  if [ ${#names[@]} -eq 0 ]; then
    printf -- '—'
  elif [ "$(printf '%s\n' "${names[@]}" | sort -u | wc -l)" -eq 1 ]; then
    printf '%s' "${names[0]}"
  else
    printf '%s' "${labeled[0]}"
    [ ${#labeled[@]} -lt 2 ] || printf ', %s' "${labeled[@]:1}"
  fi
}
for name in $(printf '%s\n' "${entries[@]}" | cut -d' ' -f1 | sort -u); do
  load_recipe "$name"
  brew_name=""
  [ -z "$HOMEBREW" ] || brew_name=$(basename "$HOMEBREW" .rb)
  row="| $NAME | $(cell pacman "$PACMAN_PACKAGE") | $(cell pacstall "$PACSTALL_PACKAGE") | $(cell homebrew "$brew_name")"
  row+=" | $(git_cell) | $README_NOTES |"
  awk -v name="$NAME" -v row="$row" '
    BEGIN { prefix = "| " tolower(name) " |" }
    /^\|/ { in_table = 1 }
    in_table && index(tolower($0), prefix) == 1 { print row; done = 1; next }
    in_table && !/^\|/ { if (!done) print row; in_table = 0; done = 1 }
    { print }
    END { if (in_table && !done) print row }' "$tree/README.md" > "$work/README.md"
  mv "$work/README.md" "$tree/README.md"
done

if $dry_run; then
  keep=true
  echo "built in $work, nothing published: the pacman repository in $repo_dir, the files in $tree"
  [ ! -d "$tap" ] || echo "and the Homebrew tap in $tap"
  ls -l "$repo_dir"
  exit 0
fi

if has_target pacman; then
  gh release view "$PACMAN_RELEASE" -R "$PKGS_REPO" >/dev/null 2>&1 \
    || gh release create "$PACMAN_RELEASE" -R "$PKGS_REPO" --title "pacman repository ($PACMAN_RELEASE)" \
      --notes "Package files for the pacman repository. See the README." --latest=false
  for entry in "${entries[@]}"; do
    read -r name target tag file <<<"$entry"
    [ "$target" = pacman ] || continue
    base=$(basename "$file")
    gh release upload "$PACMAN_RELEASE" -R "$PKGS_REPO" --clobber "$repo_dir/$base" "$repo_dir/$base.sig"
  done
  gh release upload "$PACMAN_RELEASE" -R "$PKGS_REPO" --clobber \
    "$repo_dir/$PACMAN_REPO.db" "$repo_dir/$PACMAN_REPO.db.sig" \
    "$repo_dir/$PACMAN_REPO.files" "$repo_dir/$PACMAN_REPO.files.sig"
  # Old versions are no longer in the database, so their files can go.
  current=$(gh release view "$PACMAN_RELEASE" -R "$PKGS_REPO" --json assets --jq '.assets[].name')
  for entry in "${entries[@]}"; do
    read -r name target tag file <<<"$entry"
    [ "$target" = pacman ] || continue
    load_recipe "$name"
    base=$(basename "$file")
    pattern=$(sed 's/[.+]/\\&/g' <<<"$PACMAN_PACKAGE")
    while read -r asset; do
      [ -n "$asset" ] || continue
      case $asset in
        "$base" | "$base.sig") ;;
        *) gh release delete-asset "$PACMAN_RELEASE" "$asset" -R "$PKGS_REPO" --yes ;;
      esac
    done < <(grep -E "^$pattern-[^-]+-[^-]+-[^-]+\.pkg\.tar\.zst(\.sig)?$" <<<"$current" || true)
  done
fi

summary=()
for entry in "${entries[@]}"; do
  read -r name target tag file <<<"$entry"
  summary+=("$name $target to $tag")
done
# The helper reads the token from the environment, which keeps it out of the process list.
git_auth=(-c credential.helper=
  -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f')

if has_tap_target; then
  tap_summary=()
  for entry in "${entries[@]}"; do
    read -r name target tag file <<<"$entry"
    load_recipe "$name"
    case $target in
      homebrew) tap_summary+=("$(basename "$HOMEBREW" .rb) to $tag") ;;
      homebrew-git) tap_summary+=("$(basename "$HOMEBREW_GIT" .rb) for $tag") ;;
    esac
  done
  tap_message="chore: update $(printf '%s, ' "${tap_summary[@]}")"
  # In GitHub Actions the run's token can't write to another repository, so a deploy key of the
  # tap's does; GitHub's host keys come from its API, over HTTPS. A local run uses q0wkp's token.
  tap_git=()
  if [ -n "${PKGS_TAP_DEPLOY_KEY:-}" ]; then
    install -m600 /dev/null "$work/tap_key"
    printf '%s\n' "$PKGS_TAP_DEPLOY_KEY" > "$work/tap_key"
    gh api meta --jq '.ssh_keys[] | "github.com " + .' > "$work/known_hosts"
    export GIT_SSH_COMMAND="ssh -i $work/tap_key -o IdentitiesOnly=yes -o UserKnownHostsFile=$work/known_hosts"
    tap_url=git@github.com:$TAP_REPO.git
  else
    tap_git=("${git_auth[@]}")
    tap_url=https://github.com/$TAP_REPO.git
  fi
  (
    cd "$tap"
    git add -A
    git diff --cached --quiet || git commit -q -m "${tap_message%, }"
    git "${tap_git[@]}" push -q "$tap_url" HEAD:main \
      || { git "${tap_git[@]}" pull -q --rebase "$tap_url" main && git "${tap_git[@]}" push -q "$tap_url" HEAD:main; }
  )
fi

message="chore: update $(printf '%s, ' "${summary[@]}")"
url=https://github.com/$PKGS_REPO.git
(
  cd "$tree"
  git add arch packages packagelist srclist versions README.md
  # A forced rerun of the same release can leave nothing to commit.
  git diff --cached --quiet || git commit -q -m "${message%, }" -- arch packages packagelist srclist versions README.md
  git "${git_auth[@]}" push -q "$url" HEAD:main \
    || { git "${git_auth[@]}" pull -q --rebase "$url" main && git "${git_auth[@]}" push -q "$url" HEAD:main; }
)
log "published ${summary[*]}"
