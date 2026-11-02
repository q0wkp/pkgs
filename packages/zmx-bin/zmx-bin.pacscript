pkgname="zmx-bin"
gives="zmx"
pkgver="0.8.2.mod.1"
pkgdesc="Session persistence for terminal processes (fork with --min-window and session info)"
url="https://github.com/lutianyu2001/ZZZ_FORKED.zmx"
arch=('amd64' 'arm64')
maintainer=("q0wkp <q0wkp@users.noreply.github.com>")
source_amd64=("${url}/releases/download/v0.8.2-mod.1/zmx-0.8.2-mod.1-linux-x86_64.tar.gz")
source_arm64=("${url}/releases/download/v0.8.2-mod.1/zmx-0.8.2-mod.1-linux-aarch64.tar.gz")
sha256sums_amd64=("517953ba387fd982a2f5b37de1bc4bdd4ee8b052af20a590b8f667204a99c621")
sha256sums_arm64=("2c9053cec5f65b654d9f353adddc58af243f41f2cb8ad4d86fb454b7f4e0fdc9")

package() {
  install -Dm755 "${srcdir}/zmx" -t "${pkgdir}/usr/bin"
}
