pkgname="zmx-bin"
gives="zmx"
pkgver="0.8.2.mod.1.1"
pkgdesc="Session persistence for terminal processes (fork with --min-window and session info)"
url="https://github.com/lutianyu2001/zmx"
arch=('amd64' 'arm64')
maintainer=("q0wkp <q0wkp@users.noreply.github.com>")
source_amd64=("${url}/releases/download/v0.8.2-mod.1.1/zmx-0.8.2-mod.1.1-linux-x86_64.tar.gz")
source_arm64=("${url}/releases/download/v0.8.2-mod.1.1/zmx-0.8.2-mod.1.1-linux-aarch64.tar.gz")
sha256sums_amd64=("3c45ade1d6b25956d744c8a803f94ac2e6047df0f0347e4bd02b5de6020a8c17")
sha256sums_arm64=("c0bd4da8b60aaf21a8acf4bd6920a8f061f28cc667b19c24f58b4027fee377b4")

package() {
  install -Dm755 "${srcdir}/zmx" -t "${pkgdir}/usr/bin"
  # The license texts the archive carries: the project's, and those of what is built into it.
  local f
  for f in "${srcdir}"/LICENSE* "${srcdir}"/COPYING* "${srcdir}"/NOTICE*; do
    if [ -f "$f" ]; then install -Dm644 "$f" -t "${pkgdir}/usr/share/doc/${pkgname}"; fi
  done
  if [ -d "${srcdir}/third-party" ]; then
    install -dm755 "${pkgdir}/usr/share/doc/${pkgname}"
    cp -r --no-preserve=ownership "${srcdir}/third-party" "${pkgdir}/usr/share/doc/${pkgname}/"
  fi
}
