# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Homebrew formula for zTop.
#
# Install with:
#     brew install ztop
#
# The formula installs the ztop binary and a launchd agent service.
# The agent runs as a read-only service (TLS + pairing, no --allow-control).
#
# To start the agent:
#     brew services start ztop
#
# To stop the agent:
#     brew services stop ztop

class Ztop < Formula
  desc "A lightweight system monitor for macOS and Linux"
  homepage "https://github.com/Zyniker13/Geist3"
  url "https://github.com/Zyniker13/Geist3/releases/download/0.1.0/ztop-0.1.0-macos.tar.gz"
  version "0.1.0"
  sha256 "REPLACE_WITH_ACTUAL_SHA256"

  depends_on "rust"

  def install
    system "cargo", "install", "--path", ".", "--root", prefix
    system "cargo", "install", "--path", ".", "--root", prefix, "--bin", "ztop"
  end

  service do
    generate_launchd_arguments = lambda do
      [
        "#{bin}/ztop",
        "agent",
        "--tls",
        "--pair",
      ]
    end

    run generate_launchd_arguments
    keep_alive true
    standard_output path "/tmp/ztop-agent.out"
    standard_error path "/tmp/ztop-agent.err"
  end
end
