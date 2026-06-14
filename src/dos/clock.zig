//! Deterministic DOS date/time (D13). ALL DOS-visible date/time comes from the
//! pinned 1993-01-01 epoch (timing.zig) plus the emulated BDA tick — NEVER the
//! host wall clock or host file modification/creation timestamps. Packed-field re-derived
//! from the documented DOS formats:
//!   date: bits 15-9 = year-1980, 8-5 = month (1-12), 4-0 = day (1-31)
//!   time: bits 15-11 = hour (0-23), 10-5 = minute (0-59), 4-0 = second/2

const std = @import("std");
const timing = @import("timing");

/// The fixed file date/time stamp for every VFS file (D13): the pinned epoch.
/// (zdos does not read the host file modification timestamp — file CONTENT is replayed input; its
/// timestamp is the deterministic epoch.)
pub fn fileDate() u16 {
    return packDate(timing.epoch_year, timing.epoch_month, timing.epoch_day);
}
pub fn fileTime() u16 {
    return packTime(timing.epoch_hour, timing.epoch_minute, timing.epoch_second);
}

pub fn packDate(year: u16, month: u8, day: u8) u16 {
    const y: u16 = year - 1980;
    return (y << 9) | (@as(u16, month) << 5) | day;
}
pub fn packTime(hour: u8, minute: u8, second: u8) u16 {
    return (@as(u16, hour) << 11) | (@as(u16, minute) << 5) | (@as(u16, second) / 2);
}

/// Days elapsed since 1980-01-01 for a (year,month,day) — used by INT 21h AH=2A
/// (get date) to derive a day-of-week and to advance the epoch by whole days of
/// emulated ticks. Pure integer (no host time).
pub fn daysSince1980(year: u16, month: u8, day: u8) u32 {
    var days: u32 = 0;
    var y: u16 = 1980;
    while (y < year) : (y += 1) {
        days += if (isLeap(y)) 366 else 365;
    }
    const mdays = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += mdays[m - 1];
        if (m == 2 and isLeap(year)) days += 1;
    }
    days += day - 1;
    return days;
}

fn isLeap(y: u16) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

/// Convert "days since 1980 + seconds-of-day" back to (y,m,d) / (h,m,s). Used to
/// derive AH=2A/2C return values from the emulated tick. Pure integer.
pub const DateTime = struct { year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8, dow: u8 };

pub fn fromDaysSeconds(days: u32, secs: u32) DateTime {
    var dt: DateTime = undefined;
    dt.hour = @intCast((secs / 3600) % 24);
    dt.minute = @intCast((secs / 60) % 60);
    dt.second = @intCast(secs % 60);
    // 1980-01-01 was a Tuesday (dow 2; Sunday=0).
    dt.dow = @intCast((days + 2) % 7);
    var y: u16 = 1980;
    var d = days;
    while (true) {
        const yd: u32 = if (isLeap(y)) 366 else 365;
        if (d < yd) break;
        d -= yd;
        y += 1;
    }
    dt.year = y;
    const mdays = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u8 = 1;
    while (m <= 12) : (m += 1) {
        var md: u32 = mdays[m - 1];
        if (m == 2 and isLeap(y)) md += 1;
        if (d < md) break;
        d -= md;
    }
    dt.month = m;
    dt.day = @intCast(d + 1);
    return dt;
}

/// Derive the current emulated date/time from the BDA tick count: the epoch plus
/// `ticks / 18.2065` seconds. The PIT fires ~18.2065 Hz; the tick-to-second
/// conversion uses the documented BIOS rate. Pure integer (tick * 5 / 91 approx),
/// but to stay exactly deterministic we use the rational 0x1800B0 ticks = 24h.
pub fn fromTicks(ticks: u32) DateTime {
    // 0x1800B0 (1573040) ticks per 24h. seconds = ticks * 86400 / 1573040.
    const secs_total: u64 = @as(u64, ticks) * 86400 / 0x1800B0;
    const epoch_days = daysSince1980(timing.epoch_year, timing.epoch_month, timing.epoch_day);
    const total_days = epoch_days + @as(u32, @intCast(secs_total / 86400));
    const secs_of_day: u32 = @intCast(secs_total % 86400);
    return fromDaysSeconds(total_days, secs_of_day);
}

test "packDate/packTime round numbers" {
    // 1993-01-01: year-1980 = 13, month 1, day 1.
    try std.testing.expectEqual(@as(u16, (13 << 9) | (1 << 5) | 1), packDate(1993, 1, 1));
    // 00:00:00.
    try std.testing.expectEqual(@as(u16, 0), packTime(0, 0, 0));
}
