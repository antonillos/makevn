# Copy of the formula published to antonillos/homebrew-tap/Formula/makevn.rb.
# Keep in sync when updating the tap formula.

class Makevn < Formula
  desc "Terminal-first workflows for Java Maven repositories"
  homepage "https://github.com/antonillos/makevn"
  license "MIT"

  if Hardware::CPU.arm?
    url "https://github.com/antonillos/makevn/releases/download/v0.1.3/makevn-v0.1.3-aarch64-apple-darwin.tar.gz"
    sha256 "2a3b68f065f4fd3fcce9a5a8886bea7dd7696a27c073bdb8fccf0ceea04cd69f"
  else
    url "https://github.com/antonillos/makevn/releases/download/v0.1.3/makevn-v0.1.3-x86_64-apple-darwin.tar.gz"
    sha256 "71de52964fc21e96c6d7b283a53c28ecafb697a99e96b59376dabdfffbe07d2b"
  end

  def install
    bin.install "bin/makevn"
    bin.install "bin/makevn-mcp"
    libexec.install "libexec/makevn"
    share.install "share/makevn"
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
