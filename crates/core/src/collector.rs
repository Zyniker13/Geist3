// SPDX-License-Identifier: MIT OR Apache-2.0
//! The collector interface every platform source implements.

use crate::model::Sample;

/// Errors a collector can hit.
#[derive(Debug, thiserror::Error)]
pub enum CollectError {
    /// Reading a host source (sysctl, /proc, IOKit, ...) failed.
    #[error("reading a host source failed: {0}")]
    Io(#[from] std::io::Error),
    /// The host does not provide this source at all; collectors report it as
    /// an unavailable [`crate::model::Metric`] instead of failing the sample.
    /// thiserror reserves the field name `source` for the wrapped cause, so
    /// the name of the missing source is called `origin` here.
    #[error("this host does not provide {what} ({origin})")]
    Unavailable {
        origin: &'static str,
        what: &'static str,
    },
}

/// One platform source of [`Sample`]s.
///
/// Collectors are pull-based: the TUI, the agent and the recorder all call
/// [`Collector::sample`] on their own cadence. A collector must be cheap
/// enough to run about once per second and must never block the caller for
/// long; anything slow belongs in its own thread or task.
pub trait Collector {
    /// Take one sample of the host.
    fn sample(&mut self) -> Result<Sample, CollectError>;
}
