# Homebrew formula template for the `sempere` CLI.
#
# Lives in the tap repository anthonytw/homebrew-tap as Formula/sempere.rb.
# packaging/homebrew/README.md explains how to fill in VERSION and the checksums
# from a release's SHA256SUMS (or run scripts/update-formula.sh).
class Sempere < Formula
  desc "Keys, verification, export and recovery for Sempere encrypted handwriting vaults"
  homepage "https://github.com/anthonytw/sempere"
  version "@VERSION@"
  license "GPL-3.0-or-later"

  on_macos do
    # One universal (arm64 + x86_64) binary.
    url "https://github.com/anthonytw/sempere/releases/download/v#{version}/sempere-#{version}-macos-universal.tar.gz"
    sha256 "@SHA256_MACOS_UNIVERSAL@"
  end

  on_linux do
    on_intel do
      url "https://github.com/anthonytw/sempere/releases/download/v#{version}/sempere-#{version}-linux-x86_64.tar.gz"
      sha256 "@SHA256_LINUX_X86_64@"
    end
    on_arm do
      url "https://github.com/anthonytw/sempere/releases/download/v#{version}/sempere-#{version}-linux-aarch64.tar.gz"
      sha256 "@SHA256_LINUX_AARCH64@"
    end
  end

  def install
    bin.install "sempere"
    # Fonts for text in exports (Noto, OFL 1.1); found at ../share/sempere/fonts from the binary.
    (share/"sempere/fonts").install Dir["fonts/*"]
    doc.install "README.md", "CHANGELOG.md", "LICENSE-EXCEPTION", "docs/cli.md"
  end

  test do
    assert_equal "sempere #{version}", shell_output("#{bin}/sempere --version").lines.first.strip
    assert_match "ABSOLUTELY NO WARRANTY", shell_output("#{bin}/sempere --version")
    # A fresh identity is an age secret key.
    assert_match "AGE-SECRET-KEY-", shell_output("#{bin}/sempere keys generate")
  end
end
