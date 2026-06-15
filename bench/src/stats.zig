//! Pure summary statistics over a sample of run times (in seconds).
//!
//! Kept free of any I/O or allocation so it is trivially unit-testable.

const std = @import("std");

/// Summary statistics for a set of measurements.
pub const Summary = struct {
    /// Number of samples the summary was computed from. Always >= 1.
    count: usize,
    min: f64,
    max: f64,
    mean: f64,
    /// Sample standard deviation (Bessel-corrected, i.e. divided by N-1).
    /// Zero when there is a single sample.
    stddev: f64,

    /// Compute summary statistics for `samples`.
    /// Asserts `samples.len >= 1`.
    pub fn compute(samples: []const f64) Summary {
        std.debug.assert(samples.len >= 1);

        var min = samples[0];
        var max = samples[0];
        var sum: f64 = 0;
        for (samples) |x| {
            if (x < min) min = x;
            if (x > max) max = x;
            sum += x;
        }
        const n: f64 = @floatFromInt(samples.len);
        const mean = sum / n;

        // Sum of squared deviations from the mean.
        var sq_dev: f64 = 0;
        for (samples) |x| {
            const d = x - mean;
            sq_dev += d * d;
        }
        // Bessel's correction; undefined for a single sample, so report 0.
        const variance = if (samples.len > 1) sq_dev / (n - 1) else 0;

        return .{
            .count = samples.len,
            .min = min,
            .max = max,
            .mean = mean,
            .stddev = @sqrt(variance),
        };
    }
};

const testing = std.testing;

test "compute over a single sample" {
    const s = Summary.compute(&.{42.0});
    try testing.expectEqual(@as(usize, 1), s.count);
    try testing.expectEqual(@as(f64, 42.0), s.min);
    try testing.expectEqual(@as(f64, 42.0), s.max);
    try testing.expectEqual(@as(f64, 42.0), s.mean);
    try testing.expectEqual(@as(f64, 0.0), s.stddev);
}

test "compute min/max/mean over several samples" {
    const s = Summary.compute(&.{ 2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0 });
    try testing.expectEqual(@as(usize, 8), s.count);
    try testing.expectEqual(@as(f64, 2.0), s.min);
    try testing.expectEqual(@as(f64, 9.0), s.max);
    try testing.expectEqual(@as(f64, 5.0), s.mean);
    // Known sample stddev of this textbook dataset is sqrt(32/7).
    try testing.expectApproxEqAbs(@sqrt(32.0 / 7.0), s.stddev, 1e-12);
}

test "stddev is zero for identical samples" {
    const s = Summary.compute(&.{ 3.0, 3.0, 3.0 });
    try testing.expectEqual(@as(f64, 3.0), s.mean);
    try testing.expectEqual(@as(f64, 0.0), s.stddev);
}
