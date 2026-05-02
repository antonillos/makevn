# Copy this formula into antonillos/homebrew-tap/Formula/makevn.rb when the
# project is ready for a dedicated tap.

class Makevn < Formula
  desc "Terminal-first workflows for Java Maven repositories"
  homepage "https://github.com/antonillos/makevn"
  head "git@github.com:antonillos/makevn.git", branch: "main"

  depends_on "rust" => :build

  def install
    system "./build-rust-dispatcher.sh"

    bin.install "target/release/makevn"

    (libexec/"makevn").install(
      "libexec/makevn/backend.sh",
      "libexec/makevn/cli.sh",
      "libexec/makevn/common.sh",
      "libexec/makevn/commands",
      "libexec/makevn/common",
      "libexec/makevn/coverage",
      "libexec/makevn/docker",
      "libexec/makevn/jdk",
      "libexec/makevn/compat",
    )
    (share/"makevn").install Dir["share/makevn/*"]
    (share/"makevn/skills/makevn").install Dir["skills/makevn/*"]
  end

  test do
    assert_match "makevn", shell_output("#{bin}/makevn --help")
  end
end
