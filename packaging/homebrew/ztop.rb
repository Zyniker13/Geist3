# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Homebrew formula for zTop.
#
# Until zTop is in a tap, install straight from this repository:
#     brew install --build-from-source packaging/homebrew/ztop.rb
#
# The formula builds the `ztop` binary from the tagged source with Rust
# and registers a `brew services` agent: a read-only ztop agent
# (TLS + pairing, no --allow-control).
#
#     brew services start ztop     # run the agent at login
#     brew services stop ztop
#     brew services info ztop      # where the agent's log lives

class Ztop < Formula
  desc "A lightweight system monitor for macOS and Linux"
  homepage "https://github.com/Zyniker13/Geist3"
  url "https://github.com/Zyniker13/Geist3.git", tag: "v0.1.0"
  version "0.1.0"
  license any_of: ["MIT", "Apache-2.0"]

  depends_on "rust" => :build

  def install
    # The repository root is a virtual Cargo workspace; the binary lives
    # in crates/ztop.
    system "cargo", "install", "--path", "crates/ztop", "--locked", "--root", prefix
  end

  service do
    run [opt_bin/"ztop", "agent", "--tls", "--pair", "--no-advertise"]
    keep_alive true
    log_path var/"log/ztop-agent.log"
    error_log_path var/"log/ztop-agent.log"
  end
end
