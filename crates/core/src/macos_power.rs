// SPDX-License-Identifier: MIT OR Apache-2.0
//! macOS power, temperature and fan collector via IOReport and SMC.
//!
//! Sources (decision 0011):
//! - GPU watts: `GPU Energy` channel from IOReport "Energy Model" group.
//! - SMC temperatures: TCMb (CPU composite), Te07..Te0i (CPU die),
//!   Tg01 (GPU), Ta0P (ambient).
//! - SMC fans: F0Ac (current RPM), F0Mx (max RPM).
//! - System power: PSTR (whole-system draw).

use crate::model::*;
use crate::power;
use std::time::Instant;

// ── CoreFoundation opaque types ──────────────────────────────────────
type CFAllocatorRef = *const std::os::raw::c_void;
type CFStringRef = *const std::os::raw::c_void;
type CFIndex = isize;
type CFTypeID = u64;
type CFTypeRef = *const std::os::raw::c_void;
type CFDictionaryRef = *const std::os::raw::c_void;
type CFMutableDictionaryRef = *mut std::os::raw::c_void;
type CFArrayRef = *const std::os::raw::c_void;

// ── IOKit types ──────────────────────────────────────────────────────
// Mach/IOKit names are kept verbatim from the C headers.
#[allow(non_camel_case_types)]
type io_service_t = u32;
#[allow(non_camel_case_types)]
type io_connect_t = u32;
#[allow(non_camel_case_types)]
type mach_port_t = u32;
#[allow(non_camel_case_types)]
type kern_return_t = i32;
#[allow(non_camel_case_types)]
type task_t = mach_port_t;

// ── FFI declarations ─────────────────────────────────────────────────
unsafe extern "C" {
    // CoreFoundation
    fn CFStringCreateWithCString(
        alloc: CFAllocatorRef,
        cstr: *const std::os::raw::c_char,
        encoding: u32,
    ) -> CFStringRef;
    fn CFArrayGetCount(arr: CFArrayRef) -> CFIndex;
    fn CFArrayGetValueAtIndex(arr: CFArrayRef, idx: CFIndex) -> CFTypeRef;
    fn CFDictionaryGetValue(dict: CFDictionaryRef, key: CFTypeRef) -> CFTypeRef;
    fn CFGetTypeID(obj: CFTypeRef) -> CFTypeID;
    fn CFStringGetTypeID() -> CFTypeID;
    fn CFStringCompare(a: CFStringRef, b: CFStringRef, options: u32) -> std::os::raw::c_int;
    fn CFRelease(obj: CFTypeRef);

    // IOKit
    fn IOServiceGetMatchingService(
        main_port: mach_port_t,
        matching: CFDictionaryRef,
    ) -> io_service_t;
    fn IOServiceMatching(name: *const std::os::raw::c_char) -> CFMutableDictionaryRef;
    fn IOServiceOpen(
        service: io_service_t,
        task: task_t,
        type_: u32,
        conn: *mut io_connect_t,
    ) -> kern_return_t;
    fn IOConnectCallStructMethod(
        conn: io_connect_t,
        method_index: u32,
        input: *const std::os::raw::c_void,
        input_size: usize,
        output: *mut std::os::raw::c_void,
        output_size_ptr: *mut usize,
    ) -> kern_return_t;

    // IOReport
    fn IOReportCopyChannelsInGroup(
        group: CFStringRef,
        subgroup: CFStringRef,
        options: u64,
        reserved1: u64,
        reserved2: u64,
    ) -> CFMutableDictionaryRef;
    fn IOReportCreateSubscription(
        task: task_t,
        channels: CFMutableDictionaryRef,
        subscription_out: *mut CFMutableDictionaryRef,
        reserved: u64,
        reserved2: *mut std::os::raw::c_void,
    ) -> CFDictionaryRef;
    fn IOReportCreateSamples(
        subscription: CFDictionaryRef,
        channels: CFMutableDictionaryRef,
        previous_sample: *mut std::os::raw::c_void,
    ) -> CFDictionaryRef;
    fn IOReportSimpleGetIntegerValue(channel: CFDictionaryRef, error: *mut i32) -> u64;
    fn CFArrayGetTypeID() -> CFTypeID;

    // mach_task_self() is the macro form of this global (mach/mach.h).
    static mach_task_self_: mach_port_t;
    fn IOObjectRelease(object: io_service_t) -> kern_return_t;
}

const TASK_NULL: task_t = 0;
const KCFSTR_ENCODING_UTF8: u32 = 0x0800_0100;
const SMC_INDEX: u32 = 2;
const SMC_CMD_READ_BYTES: u8 = 5;
const SMC_CMD_READ_KEYINFO: u8 = 9;
const KERN_SUCCESS: kern_return_t = 0;

// ── SMCKeyData layout (canonical smc-command, probe18-verified) ──────
// C layout with natural alignment: key@0, vers(6)@4, pLimitData(18)@10,
// keyInfo(12)@28, result@40, status@41, data8@42, data32@44, bytes(32)@48
// = 80 bytes total. keyInfo.dataSize and keyInfo.dataType are host-order
// u32s; the big-endian byte expansion of dataType spells the four-
// character type code ("sp78", "fpe2", ...).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
struct SMCKeyData {
    key: u32,
    vers: [u8; 6],
    p_limit_data: [u8; 18],
    key_info: [u8; 12],
    result: i8,
    status: i8,
    data8: i8,
    data32: u32,
    bytes: [u8; 32],
}

impl SMCKeyData {
    fn new() -> Self {
        Self {
            key: 0,
            vers: [0; 6],
            p_limit_data: [0; 18],
            key_info: [0; 12],
            result: 0,
            status: 0,
            data8: 0,
            data32: 0,
            bytes: [0; 32],
        }
    }
}

// ── SMC connection ───────────────────────────────────────────────────
#[derive(Debug)]
struct SmcConn {
    conn: io_connect_t,
}

impl SmcConn {
    fn new() -> Option<Self> {
        // Try AppleSMC first, fall back to AppleSMCKeysEndpoint (probe18)
        let names: [&[u8]; 2] = [b"AppleSMC\0", b"AppleSMCKeysEndpoint\0"];
        let mut svc: io_service_t = 0;
        for name in &names {
            unsafe {
                let dict = IOServiceMatching(name.as_ptr() as *const _);
                if !dict.is_null() {
                    // IOServiceGetMatchingService consumes the matching
                    // dictionary, so there is nothing to release here.
                    svc = IOServiceGetMatchingService(0, dict);
                    if svc != 0 {
                        break;
                    }
                }
            }
        }
        if svc == 0 {
            return None;
        }
        let mut conn: io_connect_t = 0;
        let kr = unsafe { IOServiceOpen(svc, mach_task_self_, 0, &mut conn) };
        if kr != KERN_SUCCESS || conn == 0 {
            return None;
        }
        // The connection is ours now; the service object can go.
        unsafe {
            IOObjectRelease(svc);
        }
        Some(SmcConn { conn })
    }

    fn keycode(key: &str) -> u32 {
        let b = key.as_bytes();
        ((b[0] as u32) << 24) | ((b[1] as u32) << 16) | ((b[2] as u32) << 8) | (b[3] as u32)
    }

    /// Read key bytes + dataType. Returns None if key doesn't exist.
    fn read_bytes(&self, key: &str) -> Option<(u32, Vec<u8>)> {
        // The keyinfo response overwrites the request struct in place and
        // does not echo the key back, so the key code must be carried in a
        // local and set on both requests (smc-command uses two structs for
        // the same reason).
        let key_code = Self::keycode(key);
        let mut kd = SMCKeyData::new();
        kd.key = key_code;
        kd.data8 = SMC_CMD_READ_KEYINFO as i8;
        let mut out_size = std::mem::size_of::<SMCKeyData>();
        let kr = unsafe {
            IOConnectCallStructMethod(
                self.conn,
                SMC_INDEX,
                &kd as *const _ as *const _,
                std::mem::size_of::<SMCKeyData>(),
                &mut kd as *mut _ as *mut _,
                &mut out_size,
            )
        };
        if kr != KERN_SUCCESS || kd.result != 0 {
            return None;
        }
        // keyInfo fields are host-order u32s: dataSize is little-endian,
        // and dataType's big-endian byte expansion spells the type code.
        let size = u32::from_le_bytes(kd.key_info[0..4].try_into().ok()?);
        let dt = u32::from_le_bytes(kd.key_info[4..8].try_into().ok()?);

        // Now read the actual bytes; the request carries the expected
        // size in keyInfo.dataSize (probe18).
        let mut out_size2 = std::mem::size_of::<SMCKeyData>();
        let mut kd2 = SMCKeyData::new();
        kd2.key = key_code;
        kd2.data8 = SMC_CMD_READ_BYTES as i8;
        kd2.key_info[0..4].copy_from_slice(&size.to_le_bytes());
        let kr = unsafe {
            IOConnectCallStructMethod(
                self.conn,
                SMC_INDEX,
                &kd2 as *const _ as *const _,
                std::mem::size_of::<SMCKeyData>(),
                &mut kd2 as *mut _ as *mut _,
                &mut out_size2,
            )
        };
        if kr != KERN_SUCCESS || kd2.result != 0 {
            return None;
        }
        Some((dt, kd2.bytes[..size as usize].to_vec()))
    }

    /// Decode bytes by dataType (canonical smc-command logic).
    fn decode_value(dt: u32, bytes: &[u8]) -> Option<f64> {
        let type_str = dt.to_be_bytes();
        if type_str == *b"flt " && bytes.len() == 4 {
            // Canonical smc-command reads floats with a plain memcpy, i.e.
            // little-endian in memory (smc-ref.c printFLT).
            return Some(power::f32_le4(bytes)? as f64);
        }
        if type_str == *b"fpe2" && bytes.len() == 2 {
            // Fixed-point: value = raw / 4
            let raw = u16::from_be_bytes(bytes.try_into().ok()?);
            return Some(raw as f64 / 4.0);
        }
        if type_str == *b"ui8 " && bytes.len() == 1 {
            return Some(bytes[0] as f64);
        }
        if type_str == *b"ui16" && bytes.len() == 2 {
            return Some(u16::from_be_bytes(bytes.try_into().ok()?) as f64);
        }
        if type_str == *b"ui32" && bytes.len() == 4 {
            return Some(u32::from_be_bytes(bytes.try_into().ok()?) as f64);
        }
        if type_str == *b"si8 " && bytes.len() == 1 {
            return Some(bytes[0] as i8 as f64);
        }
        if type_str == *b"sp78" && bytes.len() == 2 {
            // Signed 7.8 fixed point: big-endian, 1/256 per LSB
            // (smc-ref.c printSP78, probe18 decode).
            return Some(i16::from_be_bytes(bytes.try_into().ok()?) as f64 / 256.0);
        }
        if type_str == *b"{pwm" && bytes.len() == 2 {
            // Fan percentage: raw / 65536 * 100
            let raw = u16::from_be_bytes(bytes.try_into().ok()?);
            return Some(raw as f64 / 655.36);
        }
        None
    }

    /// Read a single SMC key, decode to f64. Returns None if key missing/unreadable.
    fn read_key(&self, key: &str) -> Option<f64> {
        let (dt, bytes) = self.read_bytes(key)?;
        Self::decode_value(dt, &bytes)
    }

    /// Read all configured SMC sensors.
    fn read_sensors(&self, sensors: &mut Sensors) {
        // Temperatures
        let temp_keys = [
            ("TCMb", "CPU composite"),
            ("Te07", "CPU die 7"),
            ("Te08", "CPU die 8"),
            ("Te09", "CPU die 9"),
            ("Te0i", "CPU die i"),
            ("Tg01", "GPU"),
            ("Ta0P", "Ambient"),
        ];
        for (key, label) in &temp_keys {
            if let Some(value) = self.read_key(key) {
                sensors.temps.push(TempSensor {
                    label: label.to_string(),
                    celsius: Metric::available(value, Unit::Celsius),
                });
            }
        }

        // Fans
        let fan_keys = [("F0Ac", "Fan 0 current"), ("F0Mx", "Fan 0 max")];
        for (key, label) in &fan_keys {
            if let Some(value) = self.read_key(key) {
                sensors.fans.push(Fan {
                    label: label.to_string(),
                    rpm: Metric::available(value, Unit::RevolutionsPerMinute),
                });
            }
        }

        // System power (PSTR)
        if let Some(value) = self.read_key("PSTR") {
            sensors.system_watts = Metric::available(value, Unit::Watts);
        }
    }
}

// ── GPU Energy from IOReport ─────────────────────────────────────────
// Call shapes verified by probes 17 and 20: IOReportCreateSubscription
// takes TASK_NULL and returns the root dictionary plus the subscription
// out-parameter; IOReportCreateSamples(root, subscription, previous)
// yields a cooked sample whose IOReportSimpleGetIntegerValue reads the
// cumulative counter, so the window energy is the difference of two
// cooked readings. Channel names live in LegendChannel[2]; the channel
// dicts in a sample carry no IOReportChannelName key. Dictionaries here
// live for the life of the collector, like the collector itself.
#[derive(Debug)]
struct GpuEnergy {
    root: CFDictionaryRef,
    subscription: CFMutableDictionaryRef,
    prev_sample: CFDictionaryRef,
    prev_value: Option<i64>,
    prev_at: Instant,
    index: Option<CFIndex>,
    primed: bool,
}

impl GpuEnergy {
    fn new() -> Option<Self> {
        unsafe {
            let name = CFStringCreateWithCString(
                std::ptr::null(),
                c"Energy Model".as_ptr() as *const _,
                KCFSTR_ENCODING_UTF8,
            );
            let channels = IOReportCopyChannelsInGroup(name, std::ptr::null(), 0, 0, 0);
            CFRelease(name as CFTypeRef);
            if channels.is_null() {
                return None;
            }
            let mut sub: CFMutableDictionaryRef = std::ptr::null_mut();
            let root =
                IOReportCreateSubscription(TASK_NULL, channels, &mut sub, 0, std::ptr::null_mut());
            if root.is_null() || sub.is_null() {
                return None;
            }
            // Baseline sample, then a cooked sample over a zero window:
            // cooked dicts carry LegendChannel names and readable values.
            let s1 = IOReportCreateSamples(root, sub, std::ptr::null_mut());
            if s1.is_null() {
                return None;
            }
            let s2 = IOReportCreateSamples(root, sub, s1 as *mut _);
            CFRelease(s1 as CFTypeRef);
            if s2.is_null() {
                return None;
            }
            let index = Self::gpu_index(s2);
            let value = match index {
                Some(i) => Self::read_index(s2, i),
                None => None,
            };
            if index.is_some() && value.is_none() {
                return None;
            }
            Some(GpuEnergy {
                root,
                subscription: sub,
                prev_sample: s2,
                prev_value: value,
                prev_at: Instant::now(),
                index,
                primed: false,
            })
        }
    }

    /// Index of the `GPU Energy` channel in a sample's channel array.
    fn gpu_index(sample: CFDictionaryRef) -> Option<CFIndex> {
        unsafe {
            let channels_key = CFStringCreateWithCString(
                std::ptr::null(),
                c"IOReportChannels".as_ptr() as *const _,
                KCFSTR_ENCODING_UTF8,
            );
            let arr = CFDictionaryGetValue(sample, channels_key);
            CFRelease(channels_key as CFTypeRef);
            if arr.is_null() {
                return None;
            }
            let legend_key = CFStringCreateWithCString(
                std::ptr::null(),
                c"LegendChannel".as_ptr() as *const _,
                KCFSTR_ENCODING_UTF8,
            );
            let target = CFStringCreateWithCString(
                std::ptr::null(),
                c"GPU Energy".as_ptr() as *const _,
                KCFSTR_ENCODING_UTF8,
            );
            let mut found: Option<CFIndex> = None;
            let count = CFArrayGetCount(arr);
            for i in 0..count {
                let chan = CFArrayGetValueAtIndex(arr, i);
                if chan.is_null() {
                    continue;
                }
                // The display name is the third element of the legend array.
                let legend = CFDictionaryGetValue(chan, legend_key);
                if legend.is_null() || CFGetTypeID(legend) != CFArrayGetTypeID() {
                    continue;
                }
                let name = CFArrayGetValueAtIndex(legend, 2);
                if name.is_null() || CFGetTypeID(name) != CFStringGetTypeID() {
                    continue;
                }
                if CFStringCompare(name, target, 0) == 0 {
                    found = Some(i);
                    break;
                }
            }
            CFRelease(legend_key as CFTypeRef);
            CFRelease(target as CFTypeRef);
            found
        }
    }

    /// Cumulative GPU Energy reading at `index`, None when unreadable.
    fn read_index(sample: CFDictionaryRef, index: CFIndex) -> Option<i64> {
        unsafe {
            let channels_key = CFStringCreateWithCString(
                std::ptr::null(),
                c"IOReportChannels".as_ptr() as *const _,
                KCFSTR_ENCODING_UTF8,
            );
            let arr = CFDictionaryGetValue(sample, channels_key);
            CFRelease(channels_key as CFTypeRef);
            if arr.is_null() || index < 0 || index >= CFArrayGetCount(arr) {
                return None;
            }
            let chan = CFArrayGetValueAtIndex(arr, index);
            if chan.is_null() {
                return None;
            }
            let mut err: i32 = 0;
            let value = IOReportSimpleGetIntegerValue(chan, &mut err);
            if err != 0 {
                return None;
            }
            Some(value as i64)
        }
    }

    /// Watts over the window since the previous readable sample. The
    /// first call only primes the baseline (no rate yet), mirroring the
    /// CPU-rate contract of the live collector.
    fn sample(&mut self) -> Option<f64> {
        let now = Instant::now();
        let cooked = unsafe {
            IOReportCreateSamples(self.root, self.subscription, self.prev_sample as *mut _)
        };
        if cooked.is_null() {
            return None;
        }
        self.prev_sample = cooked;
        let index = self.index?;
        let value = Self::read_index(cooked, index)?;
        let elapsed = now.duration_since(self.prev_at).as_secs_f64();
        let watts = if self.primed {
            let delta = value.checked_sub(self.prev_value?)?;
            power::watts_from_energy_delta(delta, elapsed)
        } else {
            None
        };
        self.prev_value = Some(value);
        self.prev_at = now;
        self.primed = true;
        watts
    }
}

// ── Combined power collector ─────────────────────────────────────────
#[derive(Debug)]
pub struct MacOsPower {
    smc: Option<SmcConn>,
    gpu: Option<GpuEnergy>,
}

impl Default for MacOsPower {
    fn default() -> Self {
        Self::new()
    }
}

impl MacOsPower {
    pub fn new() -> Self {
        Self {
            smc: SmcConn::new(),
            gpu: GpuEnergy::new(),
        }
    }

    /// Read all power-related sensors. Fills Sensors fields in-place.
    /// Never fails the whole sample — missing sources stay unavailable.
    pub fn sample(&mut self, sensors: &mut Sensors) {
        // SMC sensors (temps, fans, system power)
        if let Some(ref smc) = self.smc {
            smc.read_sensors(sensors);
        }

        // GPU energy (delta-based, first sample is unavailable)
        if let Some(ref mut gpu) = self.gpu {
            if let Some(watts) = gpu.sample() {
                sensors.gpu_watts = Metric::available(watts, Unit::Watts);
            }
        }
    }
}
