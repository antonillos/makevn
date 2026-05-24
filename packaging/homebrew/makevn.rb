# Copy of the formula published to antonillos/homebrew-tap/Formula/makevn.rb.
# Keep in sync when updating the tap formula.

class Makevn < Formula
  desc "Terminal-first workflows for Java Maven repositories"
  homepage "https://github.com/antonillos/makevn"
  license "MIT"

  if Hardware::CPU.arm?
    url "https://github.com/antonillos/makevn/releases/download/v0.1.0/makevn-v0.1.0-aarch64-apple-darwin.tar.gz"
    sha256 "d4199327615da6e793846e4527711a5317e3804767b3515bad29a4fd602db888"
  else
    url "https://github.com/antonillos/makevn/releases/download/v0.1.0/makevn-v0.1.0-x86_64-apple-darwin.tar.gz"
    sha256 "4a60fd6cb689db774c1ed1ef7a4e0c09b578af847d9eddb3a15601ad304c060d"
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
