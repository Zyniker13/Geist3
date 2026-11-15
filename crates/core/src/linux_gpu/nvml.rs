//! NVML loaded at runtime (decision 0034).
//!
//! The library is `dlopen`ed on first use and every symbol resolved
//! then, so a machine without the driver — and a build machine without
//! the SDK — compiles and runs without it. A failed load is remembered
//! so later samples do not retry the `dlopen` on every refresh.

use std::ffi::{CStr, c_char, c_int, c_uint, c_void};
use std::sync::OnceLock;

use super::Gpu;
use crate::model::{Metric, Unit};

/// The NVML entry points zTop uses, resolved once per process.
///
/// Function pointers are stored raw because the library may load after
/// `main` started and the signatures come from the NVML headers; every
/// call site re-checks the pointer it needs.
#[derive(Debug, Default)]
struct Nvml {
    _lib: *mut c_void,
    init: Option<unsafe extern "C" fn() -> c_int>,
    device_count: Option<unsafe extern "C" fn(*mut c_uint) -> c_int>,
    device_handle: Option<unsafe extern "C" fn(c_uint, *mut *mut c_void) -> c_int>,
    device_name: Option<unsafe extern "C" fn(*mut c_void, *mut c_char, c_uint) -> c_int>,
    utilization: Option<unsafe extern "C" fn(*mut c_void, *mut NvmlUtilization) -> c_int>,
    memory: Option<unsafe extern "C" fn(*mut c_void, *mut NvmlMemory) -> c_int>,
    power: Option<unsafe extern "C" fn(*mut c_void, *mut c_uint) -> c_int>,
    temperature: Option<unsafe extern "C" fn(*mut c_void, c_int, *mut c_uint) -> c_int>,
    fan: Option<unsafe extern "C" fn(*mut c_void, *mut c_uint) -> c_int>,
}

// NVML values needed for the fields above (nvml.h).
const NVML_SUCCESS: c_int = 0;
const NVML_TEMPERATURE_GPU: c_int = 0;
const NVML_BUFFER_SIZE: c_uint = 96;

#[repr(C)]
struct NvmlUtilization {
    gpu: c_uint,
    memory: c_uint,
}

#[repr(C)]
struct NvmlMemory {
    total: u64,
    free: u64,
    used: u64,
}

unsafe impl Send for Nvml {}
unsafe impl Sync for Nvml {}

/// Candidate shared-library names, most specific first: the versioned
/// name is what distributions ship, the unversioned one what a -dev
/// package exposes.
const NVML_LIBRARIES: [&CStr; 2] = [c"libnvidia-ml.so.1", c"libnvidia-ml.so"];

/// The process-wide NVML handle, initialized at most once. A failed load
/// is remembered as `Some(None)` so later samples do not retry the
/// `dlopen` on every refresh.
static NVML: OnceLock<Option<Nvml>> = OnceLock::new();

unsafe extern "C" {
    fn dlopen(filename: *const c_char, flags: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
}

const RTLD_NOW: c_int = 2;

/// Load the library and resolve every symbol this build uses; `None`
/// when the library or any needed symbol is missing.
fn load_nvml() -> Option<Nvml> {
    unsafe {
        let mut lib = std::ptr::null_mut();
        for name in NVML_LIBRARIES {
            lib = dlopen(name.as_ptr(), RTLD_NOW);
            if !lib.is_null() {
                break;
            }
        }
        if lib.is_null() {
            return None;
        }
        // Every symbol must resolve: a half-loaded NVML would need
        // per-call guards everywhere. Missing any one means an old or
        // unusual driver build — treat the whole library as absent.
        let nvml = Nvml {
            _lib: lib,
            init: symbol(lib, c"nvmlInit_v2")?,
            device_count: symbol(lib, c"nvmlDeviceGetCount_v2")?,
            device_handle: symbol(lib, c"nvmlDeviceGetHandleByIndex_v2")?,
            device_name: symbol(lib, c"nvmlDeviceGetName")?,
            utilization: symbol(lib, c"nvmlDeviceGetUtilizationRates")?,
            memory: symbol(lib, c"nvmlDeviceGetMemoryInfo")?,
            power: symbol(lib, c"nvmlDeviceGetPowerUsage")?,
            temperature: symbol(lib, c"nvmlDeviceGetTemperature")?,
            fan: symbol(lib, c"nvmlDeviceGetFanSpeed")?,
        };
        Some(nvml)
    }
}

/// Resolve one dlsym symbol as a function pointer of type `T`
/// (transmute_copy: a fn pointer and the raw handle are both pointer
/// sized); `None` when the symbol is missing.
unsafe fn symbol<T>(lib: *mut c_void, name: &CStr) -> Option<T> {
    unsafe {
        let address = dlsym(lib, name.as_ptr());
        if address.is_null() {
            None
        } else {
            Some(std::mem::transmute_copy::<*mut c_void, T>(&address))
        }
    }
}

/// The NVML state for this process: loaded and initialized, or
/// definitively absent.
fn nvml() -> Option<&'static Nvml> {
    let cell = NVML.get_or_init(|| {
        let nvml = load_nvml()?;
        unsafe {
            if (nvml.init.expect("checked above"))() != NVML_SUCCESS {
                return None;
            }
        }
        Some(nvml)
    });
    cell.as_ref()
}

/// The NVIDIA cards through NVML, in index order. A card whose reads all
/// fail still lists with its name and unavailable metrics, matching the
/// "say so, never fake" rule.
pub(crate) fn nvidia_gpus() -> Vec<Gpu> {
    let Some(nvml) = nvml() else {
        return Vec::new();
    };
    let (Some(count_fn), Some(handle_fn), Some(name_fn)) =
        (nvml.device_count, nvml.device_handle, nvml.device_name)
    else {
        return Vec::new();
    };
    unsafe {
        let mut count: c_uint = 0;
        if count_fn(&mut count) != NVML_SUCCESS || count == 0 {
            return Vec::new();
        }
        let mut gpus = Vec::new();
        for index in 0..count {
            let mut device: *mut c_void = std::ptr::null_mut();
            if handle_fn(index, &mut device) != NVML_SUCCESS {
                continue;
            }
            let mut name_buf = [0 as c_char; NVML_BUFFER_SIZE as usize];
            let name = if name_fn(device, name_buf.as_mut_ptr(), NVML_BUFFER_SIZE) == NVML_SUCCESS {
                CStr::from_ptr(name_buf.as_ptr())
                    .to_string_lossy()
                    .into_owned()
            } else {
                format!("NVIDIA GPU {index}")
            };
            // One NVML memory call serves both columns.
            let (used, total) = nvml_memory(nvml, device);
            gpus.push(Gpu {
                name,
                utilization: nvml_utilization(nvml, device),
                memory_used: used,
                memory_total: total,
                watts: nvml_power(nvml, device),
                temperature: nvml_temperature(nvml, device),
                fan_percent: nvml_fan(nvml, device),
            });
        }
        gpus
    }
}

unsafe fn nvml_utilization(nvml: &Nvml, device: *mut c_void) -> Metric {
    let Some(util_fn) = nvml.utilization else {
        return Metric::unavailable(Unit::Percent);
    };
    let mut rates = NvmlUtilization { gpu: 0, memory: 0 };
    unsafe {
        if util_fn(device, &mut rates) == NVML_SUCCESS {
            Metric::available(f64::from(rates.gpu.min(100)), Unit::Percent)
        } else {
            Metric::unavailable(Unit::Percent)
        }
    }
}

/// (used, total) as byte metrics; both unavailable unless the call
/// succeeds.
unsafe fn nvml_memory(nvml: &Nvml, device: *mut c_void) -> (Metric, Metric) {
    let Some(mem_fn) = nvml.memory else {
        return (
            Metric::unavailable(Unit::Bytes),
            Metric::unavailable(Unit::Bytes),
        );
    };
    let mut mem = NvmlMemory {
        total: 0,
        free: 0,
        used: 0,
    };
    unsafe {
        if mem_fn(device, &mut mem) == NVML_SUCCESS {
            (
                Metric::available(mem.used as f64, Unit::Bytes),
                Metric::available(mem.total as f64, Unit::Bytes),
            )
        } else {
            (
                Metric::unavailable(Unit::Bytes),
                Metric::unavailable(Unit::Bytes),
            )
        }
    }
}

unsafe fn nvml_power(nvml: &Nvml, device: *mut c_void) -> Metric {
    let Some(power_fn) = nvml.power else {
        return Metric::unavailable(Unit::Watts);
    };
    let mut milliwatts: c_uint = 0;
    unsafe {
        if power_fn(device, &mut milliwatts) == NVML_SUCCESS {
            Metric::available(f64::from(milliwatts) / 1000.0, Unit::Watts)
        } else {
            Metric::unavailable(Unit::Watts)
        }
    }
}

unsafe fn nvml_temperature(nvml: &Nvml, device: *mut c_void) -> Metric {
    let Some(temp_fn) = nvml.temperature else {
        return Metric::unavailable(Unit::Celsius);
    };
    let mut celsius: c_uint = 0;
    unsafe {
        if temp_fn(device, NVML_TEMPERATURE_GPU, &mut celsius) == NVML_SUCCESS {
            Metric::available(f64::from(celsius), Unit::Celsius)
        } else {
            Metric::unavailable(Unit::Celsius)
        }
    }
}

unsafe fn nvml_fan(nvml: &Nvml, device: *mut c_void) -> Metric {
    let Some(fan_fn) = nvml.fan else {
        return Metric::unavailable(Unit::Percent);
    };
    let mut speed: c_uint = 0;
    unsafe {
        if fan_fn(device, &mut speed) == NVML_SUCCESS {
            Metric::available(f64::from(speed.min(100)), Unit::Percent)
        } else {
            Metric::unavailable(Unit::Percent)
        }
    }
}
