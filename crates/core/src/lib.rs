// SPDX-License-Identifier: MIT OR Apache-2.0
//! ztop-core: the data model, collectors, fixture format and protocol types.
//!
//! Everything the TUI, the agent and the hub agree on lives here, so the
//! three binaries cannot drift apart. Platform-specific reading of host
//! sources happens in the collectors; this crate defines the shapes they
//! produce and the recorded-input fixtures their tests run against.

pub mod capture;
pub mod collector;
pub mod fixture;
pub mod linux;
pub mod model;
