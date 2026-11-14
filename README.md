# zTop

Resource monitoring for a mixed fleet of Macs and Linux machines.

- **`ztop`**, a terminal utility for macOS (Homebrew) and Linux (apt). Run it on its own and it is a full interactive monitor, at least the equal of `htop` for processes and of `asitop` for Apple Silicon power, frequency and GPU data. Run `ztop agent` and it serves those metrics to the app.
- **zTop**, a universal SwiftUI app for iPad and Mac that watches every machine at once and drills into any one of them. On a Mac it can also run the hub that collects from every agent, so an iPad needs to reach only one place.

Status: planning. See [ROADMAP.md](ROADMAP.md) for the plan, [DESIGN.md](DESIGN.md) for how it works, and [STATUS.md](STATUS.md) for where work stands.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT), at your option. Unless you explicitly state otherwise, any contribution you submit for inclusion in this work, as defined in the Apache-2.0 license, is dual licensed as above, without any additional terms or conditions.

## History

This repository earlier held an end-to-end encrypted messenger, now [Thrum](https://github.com/BITS-Freeware/Thrum).
