# pkgs

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

A pacman repository and a Pacstall repository for my own package builds, which also publishes them to my Homebrew
tap, [q0wkp/homebrew-tap](https://github.com/q0wkp/homebrew-tap).

| Package | pacman | Pacstall | Homebrew | From Git | Notes |
| --- | --- | --- | --- | --- | --- |
| zmx | `zmx-bin` | `zmx-bin` | `zmx` | `zmx-git` | x86_64 on pacman, amd64 and arm64 on Pacstall, Apple silicon and Intel on macOS |
| zap | `zap` | `zap-deb` | `zap-terminal` | — | x86_64 on Linux, Apple silicon and Intel on macOS |

## Arch Linux

Trust the signing key, then add the repository to `/etc/pacman.conf`:

```bash
curl -fsSL https://raw.githubusercontent.com/q0wkp/pkgs/main/keys/signing-key.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key 218CE50E9DA469385E29A1E2B1E86D84FC6B940F
```

```ini
[q0wkp]
SigLevel = Required DatabaseRequired
Server = https://github.com/q0wkp/pkgs/releases/download/$arch
```

Then `sudo pacman -Syu <package>` installs a package from the list above, and `sudo pacman -Syu` keeps it up to date.

## Ubuntu and Debian

Install [Pacstall](https://pacstall.dev), then:

```bash
pacstall -A https://github.com/q0wkp/pkgs/tree/main
pacstall -I <package>
pacstall -Up
```

The last command upgrades. Pacstall doesn't check signatures. It verifies the sha256 in each pacscript, so these
packages are only as trustworthy as this repository.

## macOS

With [Homebrew](https://brew.sh):

```bash
brew install q0wkp/tap/<package>
```

`brew upgrade` keeps it up to date, except apps that update themselves. The casks and formulae are in
[q0wkp/homebrew-tap](https://github.com/q0wkp/homebrew-tap).

## Building from Git

A package in the From Git column builds the project's default branch on your own machine, to try a change before it is
released. Once it is installed, only its own upgrades reach it: a new release doesn't put the released package back.
On Arch Linux and with Pacstall it takes the released package's place in one step, with nothing to remove first, and
installing the released package again does the same the other way; Homebrew wants the other one uninstalled first.

On Arch Linux, in a directory of your choice, which keeps the sources between builds:

```bash
mkdir -p <BUILD_DIR> && cd <BUILD_DIR>
curl -fsSLO https://raw.githubusercontent.com/q0wkp/pkgs/main/arch/<package>-git/PKGBUILD
makepkg -si
```

pacman asks whether to remove the released package, which it conflicts with. The same three commands upgrade it to the
branch's latest commit, since pacman doesn't follow a package it didn't download: `sudo pacman -Syu` leaves it as it is.

On Ubuntu and Debian, `pacstall -I <package>-git` installs it, and `pacstall -Up` rebuilds it whenever the branch has a
new commit.

With Homebrew it is a formula of its own, which has no release:

```bash
brew uninstall <package>
brew install --HEAD q0wkp/tap/<package>-git
```

`brew upgrade --fetch-HEAD` rebuilds it when the branch has a new commit; `brew upgrade` alone leaves it as it is.

## How it is published

Each package's recipe is in `recipes/<package>/`. Whenever a project's release workflow asks (or once a day, for the
recipes listed in `scheduled`), the Sync workflow compares each project's latest release with `versions/`. For a newer
one it builds the package in an Arch container, signs it, updates the pacman database in the `x86_64` release, commits
the regenerated Pacstall files here and the cask or formula to the tap. Each of them goes out as soon as the release has
the files it needs, so a package can be on one platform before the others, or only on some. Don't edit `arch/`,
`packages/`, `packagelist`, `srclist` or the tap by hand. The packages built from Git are published as text alone, a
PKGBUILD, a pacscript and a formula rendered at each release: nothing is built for them here.

The build runs without the signing key or write access, which only the publishing job has. The key signs these packages
and nothing else, and is kept in this repository's Actions secrets. `scripts/sync.sh` does the same from a checkout on
a machine of one's own.

## License

Copyright 2026 Tianyu (Sky) Lu

The entire repository is licensed under the Apache License, Version 2.0 
(the "License"); you may not use any file in this repository except in 
compliance with the License. You may obtain a copy of the License at

```plaintext
http://www.apache.org/licenses/LICENSE-2.0
```

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

## Author

Tianyu (Sky) Lu
