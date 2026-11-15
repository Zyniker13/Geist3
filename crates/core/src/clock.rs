// SPDX-License-Identifier: MIT OR Apache-2.0
//! The sample clock: local wall-clock text for the header.
//!
//! Collectors stamp samples with Unix milliseconds; the header shows them
//! as the local clock. Formatting goes through libc's `localtime_r` and
//! `strftime`, so no time crate is added and the text follows the
//! machine's time zone like every other tool on the host.

/// Local `HH:MM:SS` for a Unix millisecond timestamp. `n/a` when the
/// timestamp cannot be converted, so a caller never shows a made-up
/// time. A timestamp of 0 (recorded fixtures before the field existed)
/// still formats as the local time of the epoch.
pub fn local_time_text(timestamp_ms: u64) -> String {
    let secs = (timestamp_ms / 1000) as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let filled = unsafe { libc::localtime_r(&secs, &mut tm) };
    if filled.is_null() {
        return String::from("n/a");
    }
    let mut buffer = [0u8; 32];
    let format = b"%H:%M:%S\0";
    let written = unsafe {
        libc::strftime(
            buffer.as_mut_ptr().cast::<libc::c_char>(),
            buffer.len(),
            format.as_ptr().cast::<libc::c_char>(),
            &tm,
        )
    };
    if written == 0 {
        return String::from("n/a");
    }
    String::from_utf8_lossy(&buffer[..written]).into_owned()
}

/// Local `MM/DD HH:MM` for a Unix second timestamp (a process's start
/// time, shown in wide terminals). `n/a` when the timestamp cannot be
/// converted, so a caller never shows a made-up date.
pub fn local_start_text(start_secs: u64) -> String {
    let secs = start_secs as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let filled = unsafe { libc::localtime_r(&secs, &mut tm) };
    if filled.is_null() {
        return String::from("n/a");
    }
    let mut buffer = [0u8; 32];
    let format = b"%m/%d %H:%M\0";
    let written = unsafe {
        libc::strftime(
            buffer.as_mut_ptr().cast::<libc::c_char>(),
            buffer.len(),
            format.as_ptr().cast::<libc::c_char>(),
            &tm,
        )
    };
    if written == 0 {
        return String::from("n/a");
    }
    String::from_utf8_lossy(&buffer[..written]).into_owned()
}

#[cfg(test)]
mod tests {
    use super::{local_start_text, local_time_text};

    #[test]
    fn local_time_formats_as_clock() {
        // The digits depend on the machine's time zone, so assert only
        // the HH:MM:SS shape, which every zone produces.
        let text = local_time_text(1_700_000_000_000);
        assert_eq!(text.len(), 8, "{text}");
        let bytes = text.as_bytes();
        assert_eq!(bytes[2], b':');
        assert_eq!(bytes[5], b':');
        for (index, byte) in bytes.iter().enumerate() {
            if index == 2 || index == 5 {
                continue;
            }
            assert!(byte.is_ascii_digit(), "{text}");
        }
    }

    #[test]
    fn local_start_text_formats_as_date_and_time() {
        // The digits depend on the machine's time zone, so assert only
        // the MM/DD HH:MM shape, which every zone produces.
        let text = local_start_text(1_700_000_000);
        assert_eq!(text.len(), 11, "{text}");
        let bytes = text.as_bytes();
        assert_eq!(bytes[2], b'/');
        assert_eq!(bytes[5], b' ');
        assert_eq!(bytes[8], b':');
        for (index, byte) in bytes.iter().enumerate() {
            if index == 2 || index == 5 || index == 8 {
                continue;
            }
            assert!(byte.is_ascii_digit(), "{text}");
        }
    }
}
