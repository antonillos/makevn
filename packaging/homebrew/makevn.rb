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
      "libexec/makevn/calculate_coverage.sh",
      "libexec/makevn/coverage_changes.sh",
      "libexec/makevn/verify_changes.sh",
      "libexec/makevn/docker.sh",
      "libexec/makevn/docker_ps.sh",
      "libexec/makevn/extract_services.sh",
      "libexec/makevn/jdk_manager.sh",
    )
    (share/"makevn").install Dir["share/makevn/*"]
    (share/"makevn/skills/makevn").install Dir["skills/makevn/*"]
  end

  test do
    assert_match "makevn", shell_output("#{bin}/makevn --help")
  end
end
