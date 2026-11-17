# 0058 — Closing the packaging milestone

## Context

M7's "Done when" requires the packaging to be verified: the Homebrew
formula and the .deb must install, and a test client must pair with an
agent started by the package. As of the M7 commit, none of that was
true:

- `packaging/homebrew/ztop.rb` pointed at a release tarball that does
  not exist (with a placeholder sha256), built with `cargo install
  --path .` (the repository root is a virtual workspace, not a
  package), and its `service` block was not the Homebrew services DSL.
- The packaging CI job built the .deb but never installed it, never
  measured the agent, and never paired a client.
- The three Packaging items in `docs/parity.md` were unchecked.
- `scripts/measure-agent.sh` gated on RSS only, not the CPU budget.
- `ztop connect` had no non-interactive mode, so a CI job could not
  pair a test client without a TTY.

GitHub releases cannot be created from this environment (that needs a
credential only Mahler holds), so the formula cannot build from a
release tarball.

## Decision

- The formula builds from the git tag: `url
  "https://github.com/Zyniker13/Geist3.git", tag: "v0.1.0"`, with
  `cargo install --path crates/ztop --locked --root prefix`. When a
  release tarball exists (Mahler creates the GitHub release), the
  formula switches to it in one line.
- The formula's `service` block uses the real Homebrew services DSL
  (`run [opt_bin/"ztop", "agent", "--tls", "--pair", "--no-advertise"]`,
  `keep_alive true`, explicit log paths), so `brew services start ztop`
  runs a read-only TLS agent at login.
- `ztop connect` gained `--once`: read one sample, print a one-line
  summary (`target · os · up H:MM:SS · cpu N.N% · mem used/total GiB ·
  swap used/total GiB · load a b c · N processes`), exit. It is the
  non-interactive pairing test client for scripts and CI.
- The packaging workflow now: builds and installs the .deb (0.1.0),
  upgrades it (0.1.1 over 0.1.0, exercising dpkg's upgrade path),
  measures the installed agent against the CPU and RSS budgets with
  `scripts/measure-agent.sh`, and pairs a test client
  (`ztop connect --tls --pin … --code … --once`) with an agent the
  package installed. The Homebrew job installs the real formula
  pointed at the checkout via a `file://` git URL (the tag does not
  exist until release), starts the agent with `brew services start`,
  reads the pairing code and TLS fingerprint from the service log,
  pairs with `connect --once`, then stops and uninstalls.
- `scripts/measure-agent.sh` now checks both budgets (CPU < 1%, RSS <
  30 MB) with `awk` instead of `bc`, which is not installed on every
  runner.
- The three Packaging items in `docs/parity.md` are checked once the
  packaging workflow is green.

## Consequences

- Packaging is verified on every push that touches `crates/**` or
  `packaging/**`, not just at release time.
- The formula is installable from the repository today
  (`brew install --build-from-source packaging/homebrew/ztop.rb`);
  the `file://` override in CI is the only deviation from the shipped
  formula.
- `connect --once` is a stable, greppable interface for scripts: the
  agent prints `Pairing code: XXXXXX` and
  `TLS fingerprint: SHA256:<hex>` at startup, and the client prints
  exactly one summary line.
