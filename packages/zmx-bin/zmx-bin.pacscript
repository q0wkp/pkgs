pkgname="zmx-bin"
gives="zmx"
pkgver="0.8.2.mod.2"
pkgdesc="Session persistence for terminal processes (fork with --min-window and session info)"
url="https://github.com/lutianyu2001/ZZZ_FORKED.zmx"
arch=('amd64' 'arm64')
maintainer=("q0wkp <q0wkp@users.noreply.github.com>")
source_amd64=("${url}/releases/download/v0.8.2-mod.2/zmx-0.8.2-mod.2-linux-x86_64.tar.gz")
source_arm64=("${url}/releases/download/v0.8.2-mod.2/zmx-0.8.2-mod.2-linux-aarch64.tar.gz")
sha256sums_amd64=("a2d934ca09efaa923347e7d396f202a82d56cc94b365e3e8ba04a7cc4820bc6b")
sha256sums_arm64=("1f691edfe870b2cabb148b2613bc9a237d8d185bff25c1980d53323eafedb541")

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
