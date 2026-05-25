# Copy of the formula published to antonillos/homebrew-tap/Formula/makevn.rb.
# Keep in sync when updating the tap formula.

class Makevn < Formula
  desc "Terminal-first workflows for Java Maven repositories"
  homepage "https://github.com/antonillos/makevn"
  license "MIT"

  if Hardware::CPU.arm?
    url "https://github.com/antonillos/makevn/releases/download/v0.1.3/makevn-v0.1.3.tar.gz"
    sha256 "TBD_AFTER_RELEASE"
  else
    url "https://github.com/antonillos/makevn/releases/download/v0.1.3/makevn-v0.1.3.tar.gz"
    sha256 "TBD_AFTER_RELEASE"
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
