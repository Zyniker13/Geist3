// SPDX-License-Identifier: MIT OR Apache-2.0
//! The `ztop` command line: one binary for the TUI, capture, the agent and the hub.

use std::error::Error;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};

/// The `ztop` command line.
#[derive(Debug, Parser)]
#[command(
    name = "ztop",
    version,
    about = "A system monitor for one host and your fleet, in a terminal."
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Record this host's raw inputs as a fixture for collector tests.
    Capture {
        /// Directory to write the fixture into.
        #[arg(long, default_value = "capture")]
        out: PathBuf,
    },
    /// Serve the agent protocol on the loopback interface.
    Agent {
        /// TCP port to listen on (loopback only).
        #[arg(long, default_value_t = 7100)]
        port: u16,
    },
    /// Serve the hub protocol on the loopback interface.
    Hub {
        /// TCP port to listen on (loopback only).
        #[arg(long, default_value_t = 7101)]
        port: u16,
    },
    /// Drive the TUI from a remote agent or hub (lands with the protocol, M4).
    Connect {
        /// Target to connect to, e.g. `127.0.0.1:7100`.
        target: String,
    },
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("ztop: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    match Cli::parse().command {
        None => ztop_tui::run()?,
        Some(Command::Capture { out }) => {
            let count = ztop_core::capture::capture_to(&out)?;
            println!("wrote {count} entries to {}", out.display());
        }
        Some(Command::Agent { port }) => {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()?;
            runtime.block_on(ztop_agent::serve(port))?;
        }
        Some(Command::Hub { port }) => {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()?;
            runtime.block_on(ztop_hub::serve(port))?;
        }
        Some(Command::Connect { .. }) => {
            return Err("connect lands with the protocol work in milestone M4".into());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_subcommand_is_the_tui() {
        let cli = Cli::try_parse_from(["ztop"]).expect("parses");
        assert!(cli.command.is_none());
    }

    #[test]
    fn capture_takes_an_out_dir() {
        let cli =
            Cli::try_parse_from(["ztop", "capture", "--out", "/tmp/fixture"]).expect("parses");
        assert!(matches!(cli.command, Some(Command::Capture { .. })));
    }

    #[test]
    fn agent_and_hub_take_a_port() {
        let cli = Cli::try_parse_from(["ztop", "agent", "--port", "8000"]).expect("parses");
        assert!(matches!(cli.command, Some(Command::Agent { port: 8000 })));
        let cli = Cli::try_parse_from(["ztop", "hub"]).expect("parses");
        assert!(matches!(cli.command, Some(Command::Hub { port: 7101 })));
    }

    #[test]
    fn connect_takes_a_target() {
        let cli = Cli::try_parse_from(["ztop", "connect", "host-b:7100"]).expect("parses");
        assert!(matches!(cli.command, Some(Command::Connect { .. })));
    }
}
