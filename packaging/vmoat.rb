# Homebrew formula for vmoat.
# Source of truth — published to the tap repo (voycey/homebrew-vmoat) as
# Formula/vmoat.rb. See packaging/README.md for the release flow.
class Vmoat < Formula
  desc "Ephemeral Colima VM per git worktree for parallel, isolated build and test"
  homepage "https://github.com/voycey/vmoat"
  url "https://github.com/voycey/vmoat/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "d1a8e8be2304c99111fdc11c2586d2f6515e63bdbac449e34bd195b678c8bd81"
  license "MIT"
  head "https://github.com/voycey/vmoat.git", branch: "main"

  depends_on "colima"

  def install
    libexec.install "bin", "lib", "scripts"   # scripts/build-krunkit.sh for --reclaim
    bin.install_symlink libexec/"bin/vmoat"
  end

  def caveats
    <<~EOS
      vmoat drives Colima and needs a `docker` CLI on PATH:
        brew install docker        # or use Docker Desktop / OrbStack

      Optional — let an AI agent drive vmoat (Claude Code plugin):
        /plugin marketplace add voycey/vmoat
        /plugin install vmoat@vmoat
    EOS
  end

  test do
    assert_match "vmoat", shell_output("#{bin}/vmoat version")
  end
end
