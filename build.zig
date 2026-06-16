const std = @import("std");

/// A (module name, module) pair for a test artifact's imports. File-scope so the
/// same named type is used everywhere (anonymous struct literals would not unify).
const Imp = struct { name: []const u8, mod: *std.Build.Module };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options exposing the absolute path to the vendored 80386 conformance
    // data so the test harness can read it at runtime WITHOUT fetching (offline /
    // reproducible per CLAUDE.md). The data is committed in the repo.
    const opts = b.addOptions();
    opts.addOption([]const u8, "testdata_80386", b.pathFromRoot("src/cpu/testdata/80386"));
    // Absolute path to the committed Borland-C++-3.1 example programs, so the DOS
    // loader regression can mount + run the real `HELLO.EXE` fixture offline.
    opts.addOption([]const u8, "dos_examples_dir", b.pathFromRoot("examples/dos-src"));

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
    //
    // The callback-trampoline bridge: the SHARED LEAF (D12/D16) both `bios` and
    // `dos` import; neither imports the other. Depends only on cpu + bus + the
    // contract leaf (already leaves). Imports NEITHER bios NOR dos.
    const bridge_mod = b.addModule("bridge", .{
        .root_source_file = b.path("src/bridge/bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    bridge_mod.addImport("cpu", cpu_mod);
    bridge_mod.addImport("bus", bus_mod);
    bridge_mod.addImport("bus_contract", bus_contract_mod);

    // The BIOS module: IVT/BDA/POST + BIOS INT handlers. Imports cpu/bus/devices/
    // timing + the bridge leaf. Does NOT import dos.
    const bios_mod = b.addModule("bios", .{
        .root_source_file = b.path("src/bios/bios.zig"),
        .target = target,
        .optimize = optimize,
    });
    bios_mod.addImport("cpu", cpu_mod);
    bios_mod.addImport("bus", bus_mod);
    bios_mod.addImport("devices", devices_mod);
    bios_mod.addImport("timing", timing_mod);
    bios_mod.addImport("bridge", bridge_mod);

    // The DOS module: INT 21h kernel + loader + VFS + EMS. Imports cpu/bus/devices/
    // timing + the bridge leaf. Does NOT import bios (D12 reversed: no dos->bios).
    const dos_mod = b.addModule("dos", .{
        .root_source_file = b.path("src/dos/dos.zig"),
        .target = target,
        .optimize = optimize,
    });
    dos_mod.addImport("cpu", cpu_mod);
    dos_mod.addImport("bus", bus_mod);
    dos_mod.addImport("devices", devices_mod);
    dos_mod.addImport("timing", timing_mod);
    dos_mod.addImport("bridge", bridge_mod);

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
    machine_mod.addImport("bridge", bridge_mod);
    machine_mod.addImport("bios", bios_mod);
    machine_mod.addImport("dos", dos_mod);

    // The debugger control core (Milestone 1): sits ABOVE machine in the module
    // graph. Imports cpu + machine only; nothing below it imports debug. It
    // OBSERVES + DRIVES the machine synchronously and is never on the emulation
    // timing path.
    const debug_mod = b.addModule("debug", .{
        .root_source_file = b.path("src/debug/debug.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_mod.addImport("cpu", cpu_mod);
    debug_mod.addImport("machine", machine_mod);
    // controller.zig (Phase 4 framebuffer capture) reads the staged ROM-font phys
    // addresses (bios.int10_mod.FONT*_PHYS) to peek real glyph bytes for text render,
    // and drives the pure rasterizer (devices.vga_render) over the live VGA state.
    debug_mod.addImport("bios", bios_mod);
    debug_mod.addImport("devices", devices_mod);
    // controller.zig imports `bus` for the memory-watchpoint (setWatch/clearWatch)
    // path. The exe never references that path so lazy analysis hid the dependency,
    // but the api module's tests do — so the `debug` module must provide `bus`.
    // (Build wiring only; no `src/debug/` source change.)
    debug_mod.addImport("bus", bus_mod);

    // The HTTP/JSON API server (Milestone 2): sits ABOVE debug + machine in the
    // module graph ("observes machine; never drives timing"). The production `api`
    // code imports only `debug` (Controller + shared types) + `cpu` (Reg32/Seg/
    // Flags enums for register-set decoding). Nothing below it imports api. The
    // listener thread never touches the machine; a single worker thread owns the
    // Controller and runs one method per command (determinism constraint #4).
    const api_mod = b.addModule("api", .{
        .root_source_file = b.path("src/api/api.zig"),
        .target = target,
        .optimize = optimize,
    });
    api_mod.addImport("debug", debug_mod);
    api_mod.addImport("cpu", cpu_mod);
    api_mod.addImport("machine", machine_mod);
    api_mod.addImport("bios", bios_mod); // for the {"char"} scancode reverse map (§5.1e)

    // The host layer (CLAUDE.md: "consumes machine output"; may thread). Sits ABOVE
    // `api` — it imports `api` (the gated queue + the clockless RunControl) and reaches
    // the worker ONLY through the submit-gated queue. The run-pacer's HOST CLOCK lives
    // here, DELIBERATELY outside the `src/api` determinism grep-gate (stream §5.1a), so
    // the api gate stays intact while the paced free-run loop can sleep on wall time.
    const host_mod = b.addModule("host", .{
        .root_source_file = b.path("src/host/host.zig"),
        .target = target,
        .optimize = optimize,
    });
    host_mod.addImport("api", api_mod);

    // The headless runner frontend: loads a real-mode DOS program through the
    // emulated loader, runs it, and dumps its CON output. `zig build run -- prog`.
    const exe = b.addExecutable(.{
        .name = "zdos",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("machine", machine_mod);
    exe.root_module.addImport("debug", debug_mod);
    exe.root_module.addImport("api", api_mod);
    exe.root_module.addImport("host", host_mod);
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run a DOS program: zig build run -- <program>");
    run_step.dependOn(&run_cmd.step);

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
            imports: []const Imp,
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
    const vga_tests = MachineTest.add(b, target, optimize, "src/devices/vga_test.zig", &.{
        .{ .name = "devices", .mod = devices_mod },
        .{ .name = "bus", .mod = bus_mod },
        .{ .name = "timing", .mod = timing_mod },
    });
    const keyboard_tests = MachineTest.add(b, target, optimize, "src/devices/keyboard_test.zig", &.{
        .{ .name = "devices", .mod = devices_mod },
        .{ .name = "bus", .mod = bus_mod },
    });
    const opl_tests = MachineTest.add(b, target, optimize, "src/devices/opl_test.zig", &.{
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
    const machine_vga_retrace = MachineTest.add(b, target, optimize, "src/machine/vga_retrace_test.zig", &.{
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
    machine_test_step.dependOn(&vga_tests.step);
    machine_test_step.dependOn(&keyboard_tests.step);
    machine_test_step.dependOn(&opl_tests.step);
    machine_test_step.dependOn(&machine_unit.step);
    machine_test_step.dependOn(&machine_determinism.step);
    machine_test_step.dependOn(&machine_integration.step);
    machine_test_step.dependOn(&machine_vga_retrace.step);

    // ---- Bridge / BIOS / DOS tests (test-bridge / test-bios / test-dos) ----
    const dosbios_imports = [_]Imp{
        .{ .name = "cpu", .mod = cpu_mod },
        .{ .name = "bus", .mod = bus_mod },
        .{ .name = "devices", .mod = devices_mod },
        .{ .name = "timing", .mod = timing_mod },
        .{ .name = "bridge", .mod = bridge_mod },
        .{ .name = "bios", .mod = bios_mod },
        .{ .name = "dos", .mod = dos_mod },
        .{ .name = "machine", .mod = machine_mod },
    };

    const bridge_unit = MachineTest.add(b, target, optimize, "src/bridge/bridge.zig", &.{
        .{ .name = "cpu", .mod = cpu_mod },
        .{ .name = "bus", .mod = bus_mod },
        .{ .name = "bridge", .mod = bridge_mod },
    });
    const bridge_rt = MachineTest.add(b, target, optimize, "src/bridge/bridge_test.zig", &dosbios_imports);
    const bridge_test_step = b.step("test-bridge", "Run the callback-bridge tests");
    bridge_test_step.dependOn(&bridge_unit.step);
    bridge_test_step.dependOn(&bridge_rt.step);

    const bios_unit = MachineTest.add(b, target, optimize, "src/bios/bios_test.zig", &dosbios_imports);
    const bios_int09 = MachineTest.add(b, target, optimize, "src/bios/int09_test.zig", &dosbios_imports);
    // Input-injection determinism (Phase 1f) — uses the debug Controller for the
    // real injection path, so it needs `debug` on top of the dosbios set.
    const bios_input_det = MachineTest.add(b, target, optimize, "src/bios/input_determinism_test.zig", &.{
        .{ .name = "cpu", .mod = cpu_mod },
        .{ .name = "bus", .mod = bus_mod },
        .{ .name = "devices", .mod = devices_mod },
        .{ .name = "timing", .mod = timing_mod },
        .{ .name = "bridge", .mod = bridge_mod },
        .{ .name = "bios", .mod = bios_mod },
        .{ .name = "dos", .mod = dos_mod },
        .{ .name = "machine", .mod = machine_mod },
        .{ .name = "debug", .mod = debug_mod },
    });
    const bios_determinism = MachineTest.add(b, target, optimize, "src/bios/determinism_test.zig", &dosbios_imports);
    // Scancode set-1 tables (input Phase 1b): a pure leaf (std only), so it builds
    // as a standalone test artifact with its in-file translation-conformance tests.
    const bios_scancodes = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bios/scancodes.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_bios_scancodes = b.addRunArtifact(bios_scancodes);
    const bios_test_step = b.step("test-bios", "Run the BIOS tests");
    bios_test_step.dependOn(&bridge_unit.step);
    bios_test_step.dependOn(&bios_unit.step);
    bios_test_step.dependOn(&bios_int09.step);
    bios_test_step.dependOn(&bios_input_det.step);
    bios_test_step.dependOn(&bios_determinism.step);
    bios_test_step.dependOn(&run_bios_scancodes.step);

    const dos_unit = MachineTest.add(b, target, optimize, "src/dos/dos_test.zig", &dosbios_imports);
    const dos_int21 = MachineTest.add(b, target, optimize, "src/dos/int21_test.zig", &dosbios_imports);
    const dos_name83 = MachineTest.add(b, target, optimize, "src/dos/name83_test.zig", &dosbios_imports);
    const dos_loader = MachineTest.add(b, target, optimize, "src/dos/loader_test.zig", &dosbios_imports);
    // Nested-EXEC debugger visibility (plans/nested-exec-debug.md): drives the
    // debug Controller INTO a child process, so it needs `debug` on top of the
    // dosbios set (like bios_input_det).
    const dos_nested_exec = MachineTest.add(b, target, optimize, "src/dos/nested_exec_debug_test.zig", &.{
        .{ .name = "cpu", .mod = cpu_mod },
        .{ .name = "bus", .mod = bus_mod },
        .{ .name = "devices", .mod = devices_mod },
        .{ .name = "timing", .mod = timing_mod },
        .{ .name = "bridge", .mod = bridge_mod },
        .{ .name = "bios", .mod = bios_mod },
        .{ .name = "dos", .mod = dos_mod },
        .{ .name = "machine", .mod = machine_mod },
        .{ .name = "debug", .mod = debug_mod },
    });
    const dos_integration = MachineTest.add(b, target, optimize, "src/dos/integration_test.zig", &dosbios_imports);
    const dos_determinism = MachineTest.add(b, target, optimize, "src/dos/determinism_test.zig", &dosbios_imports);
    // The real-CRT regression: load + run the committed Borland C++ 3.1 HELLO.EXE
    // through the full machine and assert its CON output + exit code (needs the
    // examples-dir path via build_options).
    const dos_borland_t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dos/borland_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    for (dosbios_imports) |imp| dos_borland_t.root_module.addImport(imp.name, imp.mod);
    dos_borland_t.root_module.addOptions("build_options", opts);
    const dos_borland = b.addRunArtifact(dos_borland_t);

    // The EXTERNAL-ORACLE conformance suite: for each corpus `.EXE`, run it on
    // zdos and assert its CON output + exit code == the committed dosbox-x-minted
    // `.expected` golden (offline; the goldens are vendored, minted by
    // tools/oracle.sh). Needs the examples-dir path via build_options.
    const dos_oracle_t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dos/oracle_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    for (dosbios_imports) |imp| dos_oracle_t.root_module.addImport(imp.name, imp.mod);
    dos_oracle_t.root_module.addOptions("build_options", opts);
    const dos_oracle = b.addRunArtifact(dos_oracle_t);
    const oracle_test_step = b.step("test-oracle", "Run the dosbox-x external-oracle conformance suite");
    oracle_test_step.dependOn(&dos_oracle.step);

    // The I/O-phase BINARY device-blob oracle: for each VGA corpus `.EXE`, run it
    // on zdos and assert the device-state blob it wrote (mode-13h VRAM + 6-bit DAC
    // + BDA mode) == the committed dosbox-x-minted `.expected` binary golden
    // (offline; minted by tools/oracle-io.sh, machine=vgaonly).
    const io_oracle_t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dos/io_oracle_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    for (dosbios_imports) |imp| io_oracle_t.root_module.addImport(imp.name, imp.mod);
    io_oracle_t.root_module.addOptions("build_options", opts);
    const io_oracle = b.addRunArtifact(io_oracle_t);
    const io_oracle_test_step = b.step("test-io-oracle", "Run the dosbox-x I/O binary-blob oracle suite (VGA)");
    io_oracle_test_step.dependOn(&io_oracle.step);

    const dos_test_step = b.step("test-dos", "Run the DOS kernel + loader + EMS tests");
    dos_test_step.dependOn(&dos_unit.step);
    dos_test_step.dependOn(&dos_int21.step);
    dos_test_step.dependOn(&dos_name83.step);
    dos_test_step.dependOn(&dos_loader.step);
    dos_test_step.dependOn(&dos_nested_exec.step);
    dos_test_step.dependOn(&dos_integration.step);
    dos_test_step.dependOn(&dos_determinism.step);
    dos_test_step.dependOn(&dos_borland.step);
    dos_test_step.dependOn(&dos_oracle.step);

    // ---- Debugger control-core tests (test-debug) ----
    // The debug test root imports the debug module's own submodules (via the
    // module root's `test {}` aggregator) plus cpu/machine/bus/devices/timing so
    // it can build a real machine, run corpus-style programs, and inspect
    // device-backed regions. One artifact aggregates the breakpoint-model,
    // controller, and determinism regression tests (§4 of the M1 plan).
    const debug_imports = [_]Imp{
        .{ .name = "debug", .mod = debug_mod },
        .{ .name = "machine", .mod = machine_mod },
        .{ .name = "cpu", .mod = cpu_mod },
        .{ .name = "bus", .mod = bus_mod },
        .{ .name = "devices", .mod = devices_mod },
        .{ .name = "timing", .mod = timing_mod },
    };
    const debug_tests = MachineTest.add(b, target, optimize, "src/debug/debug.zig", &debug_imports);
    const debug_test_step = b.step("test-debug", "Run the debugger control-core tests");
    debug_test_step.dependOn(&debug_tests.step);

    // ---- HTTP/JSON API server tests (test-api) ----
    // The api test root imports the api module's own submodules (via the module
    // root's `test {}` aggregator) plus debug/cpu (the production deps) and the
    // machine-building set (machine/bus/devices/timing) so an in-process test can
    // build a real machine + Controller and drive the queue/worker. The single
    // real-socket integration test gets its OWN step (test-api-integration), NOT
    // folded into `test`, so the default gate stays deterministic and CI-stable.
    const api_imports = [_]Imp{
        .{ .name = "api", .mod = api_mod },
        .{ .name = "debug", .mod = debug_mod },
        .{ .name = "machine", .mod = machine_mod },
        .{ .name = "cpu", .mod = cpu_mod },
        .{ .name = "bus", .mod = bus_mod },
        .{ .name = "devices", .mod = devices_mod },
        .{ .name = "timing", .mod = timing_mod },
        .{ .name = "bios", .mod = bios_mod }, // server.zig resolves {"char"} via scancodes
    };
    const api_tests = MachineTest.add(b, target, optimize, "src/api/api.zig", &api_imports);
    const api_test_step = b.step("test-api", "Run the HTTP/JSON API-server tests");
    api_test_step.dependOn(&api_tests.step);

    // ---- Host-layer tests (test-host) ----
    // The run-pacer (paced free-run loop). Its HOST CLOCK lives here, outside the
    // `src/api` determinism grep-gate (stream §5.1a). The tests build a real machine +
    // Controller + the api queue/worker + the pacer to prove paced ≡ unpaced
    // (byte-identical at the actual final cycle), terminal self-disarm, and the
    // run-ownership arbitration. Needs `host` + `api` + the machine-building set.
    const host_imports = [_]Imp{
        .{ .name = "host", .mod = host_mod },
        .{ .name = "api", .mod = api_mod },
        .{ .name = "debug", .mod = debug_mod },
        .{ .name = "machine", .mod = machine_mod },
        .{ .name = "cpu", .mod = cpu_mod },
        .{ .name = "bus", .mod = bus_mod },
        .{ .name = "devices", .mod = devices_mod },
        .{ .name = "timing", .mod = timing_mod },
        .{ .name = "bios", .mod = bios_mod },
    };
    const host_tests = MachineTest.add(b, target, optimize, "src/host/host.zig", &host_imports);
    const host_test_step = b.step("test-host", "Run the host-layer (run-pacer) tests");
    host_test_step.dependOn(&host_tests.step);

    // The single real-socket integration test (opt-in; not in the default `test`).
    const api_integration = MachineTest.add(b, target, optimize, "src/api/server_integration_test.zig", &api_imports);
    const api_integration_step = b.step("test-api-integration", "Run the real-socket API integration test (opt-in)");
    api_integration_step.dependOn(&api_integration.step);

    // ---- Black-box API tests (test-blackbox) ----
    // A TRUE black box: each test SPAWNS the built `./zig-out/bin/zdos --serve 0`
    // child and drives it over a real localhost socket via `std.http.Client`. It
    // imports only `api` (for the wire request structs) + `debug` (for the
    // `CpuSnapshot`/`BreakpointKind` types it parses into) so a wire-format change
    // fails to COMPILE here — but it touches NO emulator internals at runtime.
    // Because it uses real sockets + child processes it gets its OWN step, NOT folded
    // into the default `test` aggregate (mirrors `test-api-integration`), so the
    // default gate stays hermetic. It depends on the installed exe (it execs the
    // binary), so `zig build test-blackbox` builds + installs the binary first.
    const blackbox_imports = [_]Imp{
        .{ .name = "api", .mod = api_mod },
        .{ .name = "debug", .mod = debug_mod },
        .{ .name = "cpu", .mod = cpu_mod },
    };
    const blackbox = MachineTest.add(b, target, optimize, "tests/blackbox/blackbox_test.zig", &blackbox_imports);
    blackbox.step.dependOn(b.getInstallStep()); // build + install ./zig-out/bin/zdos first
    const blackbox_step = b.step("test-blackbox", "Run the black-box HTTP-API tests (spawns the real server)");
    blackbox_step.dependOn(&blackbox.step);

    // Top-level test step aggregates the CPU + bus + machine tests.
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_cpu_tests.step);
    test_step.dependOn(&run_bus_tests.step);
    test_step.dependOn(&run_bus_integration.step);
    test_step.dependOn(&run_timing_tests.step);
    test_step.dependOn(&run_sched_tests.step);
    test_step.dependOn(&pic_tests.step);
    test_step.dependOn(&pit_tests.step);
    test_step.dependOn(&vga_tests.step);
    test_step.dependOn(&keyboard_tests.step);
    test_step.dependOn(&opl_tests.step);
    test_step.dependOn(&machine_unit.step);
    test_step.dependOn(&machine_determinism.step);
    test_step.dependOn(&machine_integration.step);
    test_step.dependOn(&machine_vga_retrace.step);
    test_step.dependOn(&bridge_unit.step);
    test_step.dependOn(&bridge_rt.step);
    test_step.dependOn(&bios_unit.step);
    test_step.dependOn(&bios_int09.step);
    test_step.dependOn(&bios_input_det.step);
    test_step.dependOn(&bios_determinism.step);
    test_step.dependOn(&run_bios_scancodes.step);
    test_step.dependOn(&dos_unit.step);
    test_step.dependOn(&dos_int21.step);
    test_step.dependOn(&dos_name83.step);
    test_step.dependOn(&dos_loader.step);
    test_step.dependOn(&dos_nested_exec.step);
    test_step.dependOn(&dos_integration.step);
    test_step.dependOn(&dos_determinism.step);
    test_step.dependOn(&dos_borland.step);
    test_step.dependOn(&dos_oracle.step);
    test_step.dependOn(&io_oracle.step);
    test_step.dependOn(&debug_tests.step);
    test_step.dependOn(&api_tests.step);
    test_step.dependOn(&host_tests.step);

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
