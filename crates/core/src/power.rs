// SPDX-License-Identifier: MIT OR Apache-2.0
//! Decode and unit math shared by the power-related collectors.
//!
//! The macOS sources behind these helpers are fixed by decision 0011:
//! SMC float values are little-endian in memory, IOReport energy counters
//! count in 1e-9 J units, and CPU state residency counts in mach ticks
//! with cumulative per-state values where idle states are named `ELDI`
//! and similar. The math here is pure, so tests run on every platform,
//! while the sources live in the platform collectors.

/// A little-endian 32-bit float, as SMC stores `flt ` values.
pub fn f32_le4(bytes: &[u8]) -> Option<f32> {
    let word: [u8; 4] = bytes.get(..4)?.try_into().ok()?;
    Some(f32::from_le_bytes(word))
}

/// Watts from an IOReport energy counter delta.
///
/// Energy channels count in 1e-9 J units (nanjoules), so the power over
/// the interval is the delta divided by the elapsed time, rescaled. A
/// non-positive elapsed time or a negative delta (counter reset) yields
/// no value rather than a wrong one.
pub fn watts_from_energy_delta(delta: i64, elapsed_secs: f64) -> Option<f64> {
    if elapsed_secs <= 0.0 || delta < 0 {
        return None;
    }
    Some(delta as f64 * 1e-9 / elapsed_secs)
}

/// Busy share of one CPU core from its state residency ticks.
///
/// `states` pairs state names with cumulative residency ticks; the busy
/// share is everything that is not idle. Idle states are named `ELDI` on
/// current Apple silicon and may appear as `IDLE`, `*LDI` or `OFF`
/// elsewhere (decision 0011). Returns `None` when no ticks were
/// observed, because a share cannot be computed from nothing.
pub fn busy_share_from_states(states: &[(&str, i64)]) -> Option<f64> {
    let mut total: i64 = 0;
    let mut idle: i64 = 0;
    for (name, ticks) in states {
        if *ticks < 0 {
            continue;
        }
        total += ticks;
        if *name == "ELDI" || name.ends_with("LDI") || name.contains("IDLE") || name.contains("OFF")
        {
            idle += ticks;
        }
    }
    if total <= 0 {
        return None;
    }
    Some((1.0 - idle as f64 / total as f64).clamp(0.0, 1.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn f32_reads_little_endian_words() {
        let bytes = 28.5f32.to_le_bytes();
        assert_eq!(f32_le4(&bytes), Some(28.5));
        assert_eq!(f32_le4(&bytes[..3]), None);
    }

    #[test]
    fn energy_delta_becomes_watts() {
        // 34,769,592,692 nanjoules over ~4 s is the measured Metal-load
        // GPU power from the probe (decision 0011).
        let watts = watts_from_energy_delta(34_769_592_692, 4.0).unwrap();
        assert!((watts - 8.692_4).abs() < 0.01, "{watts}");
    }

    #[test]
    fn energy_delta_refuses_bad_intervals() {
        assert_eq!(watts_from_energy_delta(1_000, 0.0), None);
        assert_eq!(watts_from_energy_delta(1_000, -1.0), None);
        assert_eq!(watts_from_energy_delta(-5, 1.0), None);
    }

    #[test]
    fn busy_share_keys_on_the_idle_state_names() {
        let states = vec![("ELDI", 750), ("0P6V", 250)];
        let share = busy_share_from_states(&states).unwrap();
        assert!((share - 0.25).abs() < 1e-9, "{share}");

        let states = vec![("IDLE", 500), ("P1", 500)];
        assert_eq!(busy_share_from_states(&states), Some(0.5));

        // No ticks at all: no share.
        assert_eq!(busy_share_from_states(&[]), None);
        assert_eq!(busy_share_from_states(&[("ELDI", 0)]), None);
    }

    #[test]
    fn busy_share_stays_in_bounds_when_counters_reset() {
        // A negative tick count is skipped, not turned into >100% busy.
        let states = vec![("ELDI", -10), ("P1", 20)];
        assert_eq!(busy_share_from_states(&states), Some(1.0));
    }
}
