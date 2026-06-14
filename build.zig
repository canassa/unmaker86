const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options exposing the absolute path to the vendored 80386 conformance
    // data so the test harness can read it at runtime WITHOUT fetching (offline /
    // reproducible per CLAUDE.md). The data is committed in the repo.
    const opts = b.addOptions();
    opts.addOption([]const u8, "testdata_80386", b.pathFromRoot("src/cpu/testdata/80386"));

    // The CPU as an importable module (the machine module will later
    // `addImport("cpu", cpu_mod)`). It imports nothing outside std.
    const cpu_mod = b.addModule("cpu", .{
        .root_source_file = b.path("src/cpu/cpu.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = cpu_mod;

    // Dedicated CPU test step.
    const cpu_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cpu/cpu_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cpu_tests.root_module.addOptions("build_options", opts);
    const run_cpu_tests = b.addRunArtifact(cpu_tests);
    const cpu_test_step = b.step("test-cpu", "Run CPU unit + conformance tests");
    cpu_test_step.dependOn(&run_cpu_tests.step);

    // Top-level test step aggregates the CPU tests.
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_cpu_tests.step);

    // Dedicated full-conformance sweep: runs ALL vendored 80386 real-mode
    // vectors and reports per-opcode pass/fail/revoked counts. Separate from
    // `test` so the unit suite stays fast; run with `zig build conformance`.
    const conf = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cpu/conformance_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    conf.root_module.addOptions("build_options", opts);
    const run_conf = b.addRunArtifact(conf);
    const conf_step = b.step("conformance", "Run the full 80386 real-mode conformance sweep");
    conf_step.dependOn(&run_conf.step);
}
