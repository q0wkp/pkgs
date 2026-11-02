# pkgs

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

A pacman repository and a Pacstall repository for my builds of
[zmx](https://github.com/lutianyu2001/ZZZ_FORKED.zmx) and [Zap](https://github.com/q0wkp/zap).

| Package | pacman | Pacstall | Notes |
| --- | --- | --- | --- |
| zmx | `zmx-bin` | `zmx-bin` | x86_64 on pacman, amd64 and arm64 on Pacstall |
| Zap | `zap` | `zap-deb` | x86_64 only, published from `v2026.07.09.2-mod.3` on |

## Arch Linux

Trust the signing key, then add the repository to `/etc/pacman.conf`:

```bash
curl -fsSL https://raw.githubusercontent.com/q0wkp/pkgs/main/keys/signing-key.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key EF4B7FA5E3A7C4B35DB1E1DF641030CFD2C34DD3
```

```ini
[q0wkp]
SigLevel = Required DatabaseRequired
Server = https://github.com/q0wkp/pkgs/releases/download/$arch
```

Then `sudo pacman -Sy zmx-bin` installs it, and `sudo pacman -Syu` keeps it up to date.

## Ubuntu and Debian

Install [Pacstall](https://pacstall.dev), then:

```bash
pacstall -A https://github.com/q0wkp/pkgs/tree/main
pacstall -I zmx-bin
pacstall -Up
```

The last command upgrades. Pacstall doesn't check signatures. It verifies the sha256 in each pacscript, so these
packages are only as trustworthy as this repository.

## How it is published

`scripts/sync.sh` compares the latest zmx and Zap releases with `versions/`. If one is newer, it builds or fetches the
package, signs it, updates the pacman database in the `x86_64` release, regenerates the Pacstall files from
`templates/`, and commits them. Don't edit `arch/`, `packages/`, `packagelist` or `srclist` by hand.

It runs on my own machine, and `scripts/pkgs-sync.cron` is the crontab for it. Packages are signed with my personal
GPG key, the one that signs my commits, so its passphrase has to be cached in gpg-agent. If it isn't, the run fails
before anything is published.

zmx's IPC can change between versions, so upgrading it on a machine with live sessions can leave them unreachable from
the new client. Upgrade once those sessions can end.

## License

Copyright 2026 Tianyu (Sky) Lu

The entire repository is licensed under the Apache License, Version 2.0 
(the "License"); you may not use any file in this repository except in 
compliance with the License. You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

## Author

Tianyu (Sky) Lu
