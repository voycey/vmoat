# Homebrew formula for vmoat.
# Source of truth — published to the tap repo (voycey/homebrew-vmoat) as
# Formula/vmoat.rb. See packaging/README.md for the release flow.
class Vmoat < Formula
  desc "Ephemeral Colima VM per git worktree for parallel, isolated build and test"
  homepage "https://github.com/voycey/vmoat"
  url "https://github.com/voycey/vmoat/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "4a1170e5a80cdf9cf6efbc1b40b4dfea5ed96cffdcd50b8511c82e52e08bc58f"
  license "MIT"
  head "https://github.com/voycey/vmoat.git", branch: "main"

  depends_on "colima"

  def install
    libexec.install "bin", "lib"
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
