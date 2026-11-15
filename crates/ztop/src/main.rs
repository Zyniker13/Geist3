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
    /// Show only these process ids, comma separated (htop's `-p`).
    #[arg(short = 'p', long, value_delimiter = ',')]
    pids: Vec<u32>,

    /// Seconds between samples; at least 0.1 (htop's `-d`).
    #[arg(short = 'd', long, default_value_t = 1.0)]
    delay: f64,

    /// Show only this user's processes at startup (htop's `-u`).
    #[arg(short = 'u', long)]
    user: Option<String>,

    /// Sort by this key at startup: one of pid, user, cpu, mem, res, virt,
    /// shr, pri, nice, time, start, core, ppid, name, command (htop's `-s`).
    #[arg(short = 's', long)]
    sort: Option<String>,

    /// Start in tree view (htop's `-t`).
    #[arg(short = 't', long)]
    tree: bool,

    /// Render without colors, ignoring the saved theme for this run.
    #[arg(long)]
    no_color: bool,

    /// Refuse every action that changes the system: signals and renice
    /// are disabled for this run.
    #[arg(long)]
    readonly: bool,

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
        /// Show a pairing code a client can trade for a token.
        #[arg(long)]
        pair: bool,
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
    /// Render one TUI frame from a recorded fixture and print it.
    Replay {
        /// Fixture directory to load (a `ztop capture` output).
        dir: PathBuf,
    },
}

/// Build the run flags from the CLI; `readonly` is passed in so
/// `connect` can force observation-only regardless of the flag.
fn flags_from(cli: &Cli, readonly: bool) -> Result<ztop_tui::RunFlags, Box<dyn Error>> {
    if cli.delay < ztop_tui::MIN_DELAY.as_secs_f64() {
        return Err(format!(
            "delay must be at least {} seconds",
            ztop_tui::MIN_DELAY.as_secs_f64()
        )
        .into());
    }
    Ok(ztop_tui::RunFlags {
        readonly,
        user: cli.user.clone(),
        sort: match &cli.sort {
            Some(name) => Some(name.parse()?),
            None => None,
        },
        delay: std::time::Duration::from_secs_f64(cli.delay),
    })
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
    let cli = Cli::parse();
    match cli.command {
        None => {
            // The live sampler runs on Linux and macOS; other platforms get
            // a placeholder that reports itself unavailable in the TUI
            // header.
            #[cfg(target_os = "linux")]
            let mut collector = ztop_core::linux::LinuxCollector::default();
            #[cfg(target_os = "macos")]
            let mut collector = ztop_core::macos_live::MacOsCollector::default();
            #[cfg(not(any(target_os = "linux", target_os = "macos")))]
            let mut collector = ztop_tui::UnavailableCollector;
            // Load the saved setup; `--no-color` overrides the theme once,
            // without saving that override.
            let mut config = ztop_tui::Config::load();
            if cli.no_color {
                config.theme = ztop_tui::Theme::Mono;
            }
            if cli.tree {
                config.start_in_tree = true;
            }
            let flags = flags_from(&cli, cli.readonly)?;
            ztop_tui::run(&mut collector, &cli.pids, config, flags)?;
        }
        Some(Command::Capture { out }) => {
            let count = ztop_core::capture::capture_to(&out)?;
            println!("wrote {count} entries to {}", out.display());
        }
        Some(Command::Agent { port, pair }) => {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()?;
            runtime.block_on(ztop_agent::serve(port, pair))?;
        }
        Some(Command::Hub { port }) => {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()?;
            runtime.block_on(ztop_hub::serve(port))?;
        }
        Some(Command::Connect { ref target }) => {
            // A remote view is observation-only for now: signals and
            // renice through the protocol come with the pairing work
            // (decision 0003), and until then acting on a row would
            // hit the local process table under the same pid.
            let mut config = ztop_tui::Config::load();
            if cli.no_color {
                config.theme = ztop_tui::Theme::Mono;
            }
            if cli.tree {
                config.start_in_tree = true;
            }
            let flags = flags_from(&cli, true)?;
            let mut collector = ztop_core::client::RemoteCollector::new(target.clone());
            ztop_tui::run(&mut collector, &cli.pids, config, flags)?;
        }
        Some(Command::Replay { dir }) => {
            // One rendered frame through the production draw path: the same
            // journey a live sample would take, without needing a terminal.
            let sample = ztop_core::sample_from_fixture(&dir)?;
            let ui = ztop_tui::Ui {
                sample: Some(sample),
                ..ztop_tui::Ui::new()
            };
            for line in ztop_tui::draw_lines(&ui, 80, 24) {
                println!("{line}");
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

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
        assert!(matches!(
            cli.command,
            Some(Command::Agent {
                port: 8000,
                pair: false
            })
        ));
        let cli = Cli::try_parse_from(["ztop", "agent", "--pair"]).expect("parses");
        assert!(matches!(
            cli.command,
            Some(Command::Agent { pair: true, .. })
        ));
        let cli = Cli::try_parse_from(["ztop", "hub"]).expect("parses");
        assert!(matches!(cli.command, Some(Command::Hub { port: 7101 })));
    }

    #[test]
    fn connect_takes_a_target() {
        let cli = Cli::try_parse_from(["ztop", "connect", "host-b:7100"]).expect("parses");
        assert!(matches!(cli.command, Some(Command::Connect { .. })));
    }

    #[test]
    fn replay_takes_a_fixture_dir() {
        let cli = Cli::try_parse_from(["ztop", "replay", "/tmp/fixture"]).expect("parses");
        assert!(matches!(
            cli.command,
            Some(Command::Replay { dir }) if dir == Path::new("/tmp/fixture")
        ));
    }

    #[test]
    fn no_color_flag_parses() {
        let cli = Cli::try_parse_from(["ztop", "--no-color"]).expect("parses");
        assert!(cli.no_color);
        let cli = Cli::try_parse_from(["ztop"]).expect("parses");
        assert!(!cli.no_color);
    }

    #[test]
    fn pids_parse_comma_separated() {
        let cli = Cli::try_parse_from(["ztop", "-p", "7,42"]).expect("parses");
        assert!(cli.pids == vec![7, 42]);

        // Repeated flags accumulate; no `-p` means no filter.
        let cli = Cli::try_parse_from(["ztop", "-p", "7", "--pids", "42"]).expect("parses");
        assert!(cli.pids == vec![7, 42]);
        let cli = Cli::try_parse_from(["ztop"]).expect("parses");
        assert!(cli.pids.is_empty());
    }
}
