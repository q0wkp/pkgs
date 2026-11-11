class ZmxGit < Formula
  desc "Session persistence for terminal processes, built from Git"
  homepage "https://github.com/lutianyu2001/zmx"
  license "MIT"
  # Built on the user's own machine: brew install --HEAD. A formula of its own, since Homebrew
  # moves a HEAD install of a formula that also has releases back to the next release.
  head "https://github.com/lutianyu2001/zmx.git", branch: "main"

  on_linux do
    depends_on "xz" => :build
  end

  # By its full name: another tap the user has may hold a formula of the same name.
  conflicts_with "q0wkp/tap/zmx", because: "both install the zmx program"

  def install
    # The Zig the project builds with (minimum_zig_version in its build.zig.zon): read at each
    # build, so the formula follows the project to a new Zig by itself, and downloaded from
    # ziglang.org with the checksum it publishes. Homebrew's own Zig may be another version.
    zig_version = (buildpath/"build.zig.zon").read[/\.minimum_zig_version = "([^"]+)"/, 1]
    odie "build.zig.zon names no minimum_zig_version" if zig_version.nil?
    platform = "#{Hardware::CPU.arm? ? "aarch64" : "x86_64"}-#{OS.mac? ? "macos" : "linux"}"
    index = JSON.parse(Utils.safe_popen_read("curl", "-fsSL", "https://ziglang.org/download/index.json"))
    release = index.dig(zig_version, platform)
    odie "ziglang.org has no Zig #{zig_version} for #{platform}" if release.nil?
    archive = buildpath/"zig.tar.xz"
    system "curl", "-fsSL", "-o", archive, release["tarball"]
    archive.verify_checksum(Checksum.new(release["shasum"]))
    (buildpath/"zig-toolchain").mkpath
    system "tar", "-xf", archive, "-C", buildpath/"zig-toolchain", "--strip-components=1"

    # As the releases are built: static on Linux, for musl. Zig downloads the project's
    # dependencies, into a cache kept in the build directory.
    ENV["ZIG_GLOBAL_CACHE_DIR"] = buildpath/"zig-cache"
    args = ["-Doptimize=ReleaseSafe", "-Dversion=#{version}"]
    args << "-Dtarget=#{Hardware::CPU.arm? ? "aarch64" : "x86_64"}-linux-musl" if OS.linux?
    system buildpath/"zig-toolchain/zig", "build", *args
    bin.install "zig-out/bin/zmx"
    # The license texts of what is built into the program; Homebrew installs LICENSE itself.
    pkgshare.install "packaging/third-party"
    generate_completions_from_executable(bin/"zmx", "completions")
  end

  test do
    assert_match "Usage: zmx", shell_output("#{bin}/zmx help")
  end
end
