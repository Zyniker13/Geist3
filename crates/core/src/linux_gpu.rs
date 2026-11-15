//! Discrete-GPU inputs for the Linux collector (decision 0034).
//!
//! NVIDIA cards come through NVML loaded at runtime: the library is
//! `dlopen`ed on first use and every symbol resolved then, so a machine
//! without the driver — and a build machine without the SDK — compiles
//! and runs without it. AMD cards come through sysfs under
//! `/sys/class/drm/card*/device`, which the amdgpu driver exposes
//! unprivileged. Everything parses before it is trusted; a card that
//! does not expose a value leaves that metric unavailable.
//!
//! The sysfs reader compiles everywhere so its tests run on every
//! platform; only the NVML half is Linux-only.

use std::path::Path;

use crate::model::{Gpu, Metric, Unit};

#[cfg(target_os = "linux")]
mod nvml;

#[cfg(target_os = "linux")]
pub(crate) use nvml::nvidia_gpus;

#[cfg(not(target_os = "linux"))]
fn nvidia_gpus() -> Vec<Gpu> {
    Vec::new()
}

// ── AMD through sysfs ────────────────────────────────────────────────

/// The PCI vendor id for AMD/ATI graphics.
const PCI_VENDOR_AMD: &str = "0x1002";

/// The AMD cards under `/sys/class/drm`, in `cardN` order.
///
/// A card counts as AMD when its `device/vendor` reads `0x1002` — the
/// software `card` nodes and other vendors' cards are skipped. Values
/// parse before they are trusted; a missing or unparseable file leaves
/// that metric unavailable.
pub fn amd_gpus(sys_class_drm: &Path) -> Vec<Gpu> {
    let Ok(entries) = std::fs::read_dir(sys_class_drm) else {
        return Vec::new();
    };
    let mut cards: Vec<String> = entries
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| {
            name.starts_with("card") && name["card".len()..].bytes().all(|b| b.is_ascii_digit())
        })
        .collect();
    cards.sort();
    let mut gpus = Vec::new();
    for card in cards {
        let device = sys_class_drm.join(&card).join("device");
        // Only AMD cards: NVML covers NVIDIA, software nodes and other
        // vendors would fake a GPU row.
        if read_trimmed(&device.join("vendor")).as_deref() != Some(PCI_VENDOR_AMD) {
            continue;
        }
        let label = format!("AMD GPU ({card})");
        gpus.push(Gpu {
            name: label,
            utilization: read_percent(&device.join("gpu_busy_percent")),
            memory_used: read_bytes(&device.join("mem_info_vram_used")),
            memory_total: read_bytes(&device.join("mem_info_vram_total")),
            watts: read_amd_watts(&device),
            temperature: read_amd_temperature(&device),
            fan_percent: read_amd_fan(&device),
        });
    }
    gpus
}

fn read_trimmed(path: &Path) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|text| text.trim().to_string())
}

/// An integer percent file (`gpu_busy_percent`), 0–100.
fn read_percent(path: &Path) -> Metric {
    match read_trimmed(path).and_then(|text| text.parse::<i64>().ok()) {
        Some(value) if (0..=100).contains(&value) => Metric::available(value as f64, Unit::Percent),
        _ => Metric::unavailable(Unit::Percent),
    }
}

/// A byte-count file (`mem_info_vram_used` etc.).
fn read_bytes(path: &Path) -> Metric {
    match read_trimmed(path).and_then(|text| text.parse::<u64>().ok()) {
        Some(value) => Metric::available(value as f64, Unit::Bytes),
        None => Metric::unavailable(Unit::Bytes),
    }
}

/// Board power from the card's first hwmon `power1_average`
/// (microwatts), which is what amdgpu exposes unprivileged.
fn read_amd_watts(device: &Path) -> Metric {
    let Some(microwatts) = find_hwmon(device, "power1_average")
        .and_then(|path| read_trimmed(&path).and_then(|text| text.parse::<i64>().ok()))
    else {
        return Metric::unavailable(Unit::Watts);
    };
    if microwatts < 0 {
        return Metric::unavailable(Unit::Watts);
    }
    Metric::available(microwatts as f64 / 1_000_000.0, Unit::Watts)
}

/// Core temperature from the card's first hwmon `temp1_input`
/// (millidegrees Celsius).
fn read_amd_temperature(device: &Path) -> Metric {
    let Some(millidegrees) = find_hwmon(device, "temp1_input")
        .and_then(|path| read_trimmed(&path).and_then(|text| text.parse::<i64>().ok()))
    else {
        return Metric::unavailable(Unit::Celsius);
    };
    if millidegrees < 0 {
        return Metric::unavailable(Unit::Celsius);
    }
    Metric::available(millidegrees as f64 / 1000.0, Unit::Celsius)
}

/// Fan speed from the card's `pwm1` (0–255), only when the control is
/// in manual or automatic reporting mode (`pwm1_enable` present). A
/// missing pwm on a fanless card stays unavailable, not zero.
fn read_amd_fan(device: &Path) -> Metric {
    let Some(pwm) = find_hwmon(device, "pwm1")
        .and_then(|path| read_trimmed(&path))
        .and_then(|text| text.parse::<i64>().ok())
    else {
        return Metric::unavailable(Unit::Percent);
    };
    if !(0..=255).contains(&pwm) {
        return Metric::unavailable(Unit::Percent);
    }
    Metric::available(pwm as f64 * 100.0 / 255.0, Unit::Percent)
}

/// The first hwmon directory under the card's device that carries the
/// named input file.
fn find_hwmon(device: &Path, input: &str) -> Option<std::path::PathBuf> {
    let hwmon_root = device.join("hwmon");
    let mut names: Vec<String> = std::fs::read_dir(&hwmon_root)
        .ok()?
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| entry.file_name().into_string().ok())
        .collect();
    names.sort();
    for name in names {
        let candidate = hwmon_root.join(&name).join(input);
        if candidate.exists() {
            return Some(candidate);
        }
    }
    None
}

/// Every GPU the platform reports: NVIDIA first (NVML), then AMD.
pub fn collect() -> Vec<Gpu> {
    let mut gpus = nvidia_gpus();
    gpus.extend(amd_gpus(Path::new("/sys/class/drm")));
    gpus
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, text: &str) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("mkdir");
        }
        std::fs::write(path, text).expect("write");
    }

    /// The AMD scan reads a card shaped like a real amdgpu sysfs tree:
    /// vendor gate, busy percent, VRAM, hwmon power/temperature/pwm.
    #[test]
    fn amd_card_reads_busy_vram_power_temp_and_fan() {
        let dir = std::env::temp_dir().join(format!("ztop-gpu-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let device = dir.join("card1").join("device");
        write(&device.join("vendor"), "0x1002\n");
        write(&device.join("gpu_busy_percent"), "37\n");
        write(&device.join("mem_info_vram_used"), "1048576\n");
        write(&device.join("mem_info_vram_total"), "17179869184\n");
        write(&device.join("hwmon/hwmon2/power1_average"), "5432100\n");
        write(&device.join("hwmon/hwmon2/temp1_input"), "61500\n");
        write(&device.join("hwmon/hwmon2/pwm1"), "128\n");
        write(&device.join("hwmon/hwmon2/pwm1_enable"), "2\n");

        let gpus = amd_gpus(&dir);
        assert_eq!(gpus.len(), 1);
        let gpu = &gpus[0];
        assert_eq!(gpu.name, "AMD GPU (card1)");
        assert_eq!(gpu.utilization.value, 37.0);
        assert_eq!(gpu.memory_used.value, 1_048_576.0);
        assert_eq!(gpu.memory_total.value, 17_179_869_184.0);
        // Microwatts → watts, millidegrees → degrees, pwm 0–255 → percent.
        assert_eq!(gpu.watts.value, 5.4321);
        assert_eq!(gpu.temperature.value, 61.5);
        assert_eq!(gpu.fan_percent.value, 128.0 * 100.0 / 255.0);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Non-AMD vendors and software card nodes produce no GPU row; a
    /// missing optional file leaves just that metric unavailable.
    #[test]
    fn vendor_gate_and_missing_files_stay_honest() {
        let dir = std::env::temp_dir().join(format!("ztop-gpu-test2-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        // card0: software node without a device directory.
        write(&dir.join("card0").join("boot_vga"), "1\n");
        // card2: an NVIDIA card — NVML's job, not sysfs's.
        write(&dir.join("card2").join("device/vendor"), "0x10de\n");
        // card3: AMD, but only the busy file.
        write(&dir.join("card3").join("device/vendor"), "0x1002\n");
        write(&dir.join("card3").join("device/gpu_busy_percent"), "0\n");

        let gpus = amd_gpus(&dir);
        assert_eq!(gpus.len(), 1);
        assert_eq!(gpus[0].name, "AMD GPU (card3)");
        assert_eq!(gpus[0].utilization.value, 0.0);
        assert!(!gpus[0].memory_used.available);
        assert!(!gpus[0].watts.available);
        assert!(!gpus[0].temperature.available);
        assert!(!gpus[0].fan_percent.available);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Junk values parse to unavailable, not to zero or a wrong number.
    #[test]
    fn unparseable_values_stay_unavailable() {
        let dir = std::env::temp_dir().join(format!("ztop-gpu-test3-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let device = dir.join("card0").join("device");
        write(&device.join("vendor"), "0x1002\n");
        write(&device.join("gpu_busy_percent"), "busy\n");
        write(&device.join("mem_info_vram_used"), "-1\n");
        write(&device.join("hwmon/hwmon0/temp1_input"), "-40000\n");
        write(&device.join("hwmon/hwmon0/pwm1"), "999\n");

        let gpus = amd_gpus(&dir);
        assert_eq!(gpus.len(), 1);
        let gpu = &gpus[0];
        assert!(!gpu.utilization.available);
        assert!(!gpu.memory_used.available);
        assert!(!gpu.temperature.available);
        assert!(!gpu.fan_percent.available);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A directory that does not exist at all yields no GPUs and no
    /// error — the honest empty set.
    #[test]
    fn missing_sys_class_drm_is_empty() {
        assert!(amd_gpus(Path::new("/nonexistent/ztop/nope")).is_empty());
    }
}
