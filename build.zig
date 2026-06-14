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

    // The shared timing leaf (M-D8): PIT_TICK_RATE, the pinned CPU clock, and the
    // integer cpu_cycles_per_pit_tick ratio. A SHARED LEAF like bus_contract —
    // both the devices (PIT) and the machine import it so the ratio has one source.
    const timing_mod = b.addModule("timing", .{
        .root_source_file = b.path("src/abi/timing.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The devices module (8259 PIC, 8254 PIT, ...). Imports the bus (PortHandler
    // interfaces), the contract leaf (PIC implements InterruptController), and the
    // timing leaf (PIT ratio). NEVER imports cpu or machine (module graph).
    const devices_mod = b.addModule("devices", .{
        .root_source_file = b.path("src/devices/devices.zig"),
        .target = target,
        .optimize = optimize,
    });
    devices_mod.addImport("bus", bus_mod);
    devices_mod.addImport("bus_contract", bus_contract_mod);
    devices_mod.addImport("timing", timing_mod);

    // The machine module: wires cpu + bus + devices + scheduler. Imports all of
    // them plus the contract leaf (asserts Scheduler/FaultSink) and timing.
    const machine_mod = b.addModule("machine", .{
        .root_source_file = b.path("src/machine/machine.zig"),
        .target = target,
        .optimize = optimize,
    });
    machine_mod.addImport("cpu", cpu_mod);
    machine_mod.addImport("bus", bus_mod);
    machine_mod.addImport("devices", devices_mod);
    machine_mod.addImport("bus_contract", bus_contract_mod);
    machine_mod.addImport("timing", timing_mod);

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

    // ---- Machine + PIC + PIT + scheduler tests (test-machine) ----
    // Each test artifact imports the MODULES it needs (module roots cannot also be
    // relatively re-imported into one unit-test root). One step aggregates them.
    const machine_test_step = b.step("test-machine", "Run machine + PIC + PIT + scheduler tests");

    const MachineTest = struct {
        fn add(
            bld: *std.Build,
            tgt: anytype,
            opt: anytype,
            path: []const u8,
            imports: []const struct { name: []const u8, mod: *std.Build.Module },
        ) *std.Build.Step.Run {
            const t = bld.addTest(.{
                .root_module = bld.createModule(.{
                    .root_source_file = bld.path(path),
                    .target = tgt,
                    .optimize = opt,
                }),
            });
            for (imports) |imp| t.root_module.addImport(imp.name, imp.mod);
            return bld.addRunArtifact(t);
        }
    };

    // Timing leaf tests (the M-D8 integer conversion + the self-grep audit).
    const timing_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/abi/timing.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_timing_tests = b.addRunArtifact(timing_tests);

    // Scheduler unit tests (pure data structure; needs nothing but std + the
    // relative scheduler source).
    const sched_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/machine/scheduler_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_sched_tests = b.addRunArtifact(sched_tests);

    const pic_tests = MachineTest.add(b, target, optimize, "src/devices/pic_test.zig", &.{
        .{ .name = "devices", .mod = devices_mod },
        .{ .name = "bus", .mod = bus_mod },
    });
    const pit_tests = MachineTest.add(b, target, optimize, "src/devices/pit_test.zig", &.{
        .{ .name = "devices", .mod = devices_mod },
        .{ .name = "bus", .mod = bus_mod },
        .{ .name = "timing", .mod = timing_mod },
    });
    const machine_unit = MachineTest.add(b, target, optimize, "src/machine/machine_test.zig", &.{
        .{ .name = "machine", .mod = machine_mod },
        .{ .name = "cpu", .mod = cpu_mod },
        .{ .name = "bus", .mod = bus_mod },
        .{ .name = "devices", .mod = devices_mod },
        .{ .name = "timing", .mod = timing_mod },
    });
    const machine_determinism = MachineTest.add(b, target, optimize, "src/machine/determinism_test.zig", &.{
        .{ .name = "machine", .mod = machine_mod },
        .{ .name = "cpu", .mod = cpu_mod },
        .{ .name = "bus", .mod = bus_mod },
        .{ .name = "devices", .mod = devices_mod },
        .{ .name = "timing", .mod = timing_mod },
    });
    const machine_integration = MachineTest.add(b, target, optimize, "src/machine/integration_test.zig", &.{
        .{ .name = "machine", .mod = machine_mod },
        .{ .name = "cpu", .mod = cpu_mod },
        .{ .name = "bus", .mod = bus_mod },
        .{ .name = "devices", .mod = devices_mod },
        .{ .name = "timing", .mod = timing_mod },
    });

    machine_test_step.dependOn(&run_timing_tests.step);
    machine_test_step.dependOn(&run_sched_tests.step);
    machine_test_step.dependOn(&pic_tests.step);
    machine_test_step.dependOn(&pit_tests.step);
    machine_test_step.dependOn(&machine_unit.step);
    machine_test_step.dependOn(&machine_determinism.step);
    machine_test_step.dependOn(&machine_integration.step);

    // Top-level test step aggregates the CPU + bus + machine tests.
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_cpu_tests.step);
    test_step.dependOn(&run_bus_tests.step);
    test_step.dependOn(&run_bus_integration.step);
    test_step.dependOn(&run_timing_tests.step);
    test_step.dependOn(&run_sched_tests.step);
    test_step.dependOn(&pic_tests.step);
    test_step.dependOn(&pit_tests.step);
    test_step.dependOn(&machine_unit.step);
    test_step.dependOn(&machine_determinism.step);
    test_step.dependOn(&machine_integration.step);

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
