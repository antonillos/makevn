# Copy of the formula published to antonillos/homebrew-tap/Formula/makevn.rb.
# Keep in sync when updating the tap formula.

class Makevn < Formula
  desc "Terminal-first workflows for Java Maven repositories"
  homepage "https://github.com/antonillos/makevn"
  license "MIT"

  head "https://github.com/antonillos/makevn.git", branch: "main"

  stable do
    url "https://github.com/antonillos/makevn/releases/download/v0.1.0/makevn-v0.1.0.tar.gz"
    sha256 "TBD_AFTER_RELEASE"
  end

  depends_on "rust" => :build

  def install
    if build.head?
      system "./build-rust-dispatcher.sh"
    else
      system "cargo", "build", "--release", "--manifest-path", "rust/dispatcher/Cargo.toml"
    end

    bin.install "target/release/makevn"
    bin.install "target/release/makevn-mcp"

    (libexec/"makevn").install Dir[
      "libexec/makevn/backend.sh",
      "libexec/makevn/cli.sh",
      "libexec/makevn/common.sh",
      "libexec/makevn/commands",
      "libexec/makevn/common",
      "libexec/makevn/coverage",
      "libexec/makevn/docker",
      "libexec/makevn/jdk",
      "libexec/makevn/compat",
    ]

    (share/"makevn").install Dir["share/makevn/*"]
    (share/"makevn/skills/makevn").install Dir["skills/makevn/*"]
  end

  def caveats
    <<~EOS
      makevn has been installed. To get started:

        makevn --help

      For MCP (Model Context Protocol) support, add to your client config:

      {
        "mcpServers": {
          "makevn": {
            "command": "#{HOMEBREW_PREFIX}/bin/makevn-mcp"
          }
        }
      }
    EOS
  end

  test do
    assert_match "makevn", shell_output("#{bin}/makevn --help")
    assert_path_exists bin/"makevn-mcp"
  end
end
