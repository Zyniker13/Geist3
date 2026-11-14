// SPDX-License-Identifier: MIT OR Apache-2.0
//! ztop-core: the data model, collectors, fixture format and protocol types.
//!
//! Everything the TUI, the agent and the hub agree on lives here, so the
//! three binaries cannot drift apart. Platform-specific reading of host
//! sources happens in the collectors; this crate defines the shapes they
//! produce and the recorded-input fixtures their tests run against.

pub mod capture;
#[cfg(target_os = "macos")]
mod capture_macos;
pub mod collector;
pub mod fixture;
pub mod linux;
pub mod macos;
#[cfg(target_os = "macos")]
pub mod macos_live;
pub mod model;

/// Reads a recorded fixture into a [`Sample`], choosing the platform
/// reader by the manifest's `platform` field.
///
/// # Errors
///
/// Returns [`FixtureSampleError`] when reading fails, a required source
/// is missing or does not parse, or the manifest names a platform with
/// no reader.
pub fn sample_from_fixture(
    dir: &std::path::Path,
) -> Result<model::Sample, linux::FixtureSampleError> {
    let fixture = fixture::Fixture::open(dir)?;
    match fixture.manifest().platform.as_str() {
        "linux" => linux::sample_from_fixture(dir),
        "macos" => macos::sample_from_fixture(dir),
        platform => Err(linux::FixtureSampleError::UnknownPlatform {
            platform: platform.to_string(),
        }),
    }
}
