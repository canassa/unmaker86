const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options exposing the absolute path to the vendored 80386 conformance
    // data so the test harness can read it at runtime WITHOUT fetching (offline /
    // reproducible per CLAUDE.md). The data is committed in the repo.
    const opts = b.addOptions();
    opts.addOption([]const u8, "testdata_80386", b.pathFromRoot("src/cpu/testdata/80386"));

    // The shared contract leaf module (B10): the single source of truth for the
    // comptime Bus/hook contracts. BOTH `cpu` and `bus` import it; neither
    // imports the other, so the module graph stays acyclic.
    const bus_contract_mod = b.addModule("bus_contract", .{
        .root_source_file = b.path("src/abi/bus_contract.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The CPU as an importable module (the machine module will later
    // `addImport("cpu", cpu_mod)`). It imports nothing outside std + the
    // contract leaf.
    const cpu_mod = b.addModule("cpu", .{
        .root_source_file = b.path("src/cpu/cpu.zig"),
        .target = target,
        .optimize = optimize,
    });
    cpu_mod.addImport("bus_contract", bus_contract_mod);

    // The bus as an importable module (the machine will `addImport("bus",
    // bus_mod)` and instantiate `Cpu(Bus)`). It imports nothing outside std +
    // the contract leaf.
    const bus_mod = b.addModule("bus", .{
        .root_source_file = b.path("src/bus/bus.zig"),
        .target = target,
        .optimize = optimize,
    });
    bus_mod.addImport("bus_contract", bus_contract_mod);

    // Dedicated CPU test step.
    const cpu_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cpu/cpu_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cpu_tests.root_module.addImport("bus_contract", bus_contract_mod);
    cpu_tests.root_module.addOptions("build_options", opts);
    const run_cpu_tests = b.addRunArtifact(cpu_tests);
    const cpu_test_step = b.step("test-cpu", "Run CPU unit + conformance tests");
    cpu_test_step.dependOn(&run_cpu_tests.step);

    // Dedicated bus test step. The bus test root imports the bus module's own
    // sources (incl. the comptime `assertBusContract(Bus)` gate) and its
    // per-area tests; the integration test additionally imports `cpu` to run a
    // real program on `Cpu(Bus)`.
    const bus_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bus/bus_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bus_tests.root_module.addImport("bus_contract", bus_contract_mod);
    const run_bus_tests = b.addRunArtifact(bus_tests);

    // The M0 integration test is a SEPARATE artifact: it imports the `cpu` and
    // `bus` MODULES (whose root files cannot also be relatively imported into the
    // unit-test root module) and runs a real program on `Cpu(Bus)`.
    const bus_integration = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bus/integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bus_integration.root_module.addImport("cpu", cpu_mod);
    bus_integration.root_module.addImport("bus", bus_mod);
    const run_bus_integration = b.addRunArtifact(bus_integration);

    const bus_test_step = b.step("test-bus", "Run bus unit + integration tests");
    bus_test_step.dependOn(&run_bus_tests.step);
    bus_test_step.dependOn(&run_bus_integration.step);

    // Top-level test step aggregates the CPU + bus tests.
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_cpu_tests.step);
    test_step.dependOn(&run_bus_tests.step);
    test_step.dependOn(&run_bus_integration.step);

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
    conf.root_module.addImport("bus_contract", bus_contract_mod);
    conf.root_module.addOptions("build_options", opts);
    const run_conf = b.addRunArtifact(conf);
    const conf_step = b.step("conformance", "Run the full 80386 real-mode conformance sweep");
    conf_step.dependOn(&run_conf.step);
}
