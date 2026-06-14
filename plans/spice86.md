# Spice86 Architecture — A Reverse-Engineering DOS Emulator (deep dive for a from-scratch rebuild)

This document reverse-engineers the *architecture* of Spice86 (C#/.NET, ~1381 source files) so a
team could build a new real-mode DOS emulator from scratch. It focuses on structure, algorithms,
strategy, and the DOS/BIOS API surface — not per-opcode minutiae. Every major claim cites a file
(or `file:line`). Where I infer rather than confirm, I say so.

Source root analyzed: `references/spice86/`. Paths below are relative to that root unless absolute.

Spice86 is unusual: it is not just an emulator, it is a *reverse-engineering and rewriting tool* for
real-mode DOS programs. Its CPU builds a Control Flow Graph (CFG) as it runs, JIT-compiles nodes,
records every executed function, and on exit **emits a self-contained runnable C# project** that
overrides the original assembly with equivalent C#. That RE pipeline shapes the whole design.

---

## 1. Solution / source layout

Solution: `src/Spice86.sln`. Projects (`src/*/`):

| Project | Purpose |
|---|---|
| `Spice86.Core` | The entire emulator: CPU, memory, devices, DOS/BIOS, interrupts, RE tooling, GDB/HTTP/MCP servers. This is the heart. (`src/Spice86.Core/Spice86.Core.csproj`) |
| `Spice86` | The host application: Avalonia UI, ViewModels/Views, the **compile-time DI wiring** (`Spice86DependencyInjection.cs`), entry point (`Program.cs`). |
| `Spice86.Shared` | Cross-cutting value types and interfaces: `SegmentedAddress`, logging interfaces, serializable breakpoint records, collections (e.g. the time priority queue). (`src/Spice86.Shared/`) |
| `Spice86.Logging` | `LoggerService` (Serilog wrapper) with a per-thread `LoggerPropertyBag` carrying CS:IP. |
| `Spice86.Storage.Fat`, `Spice86.Storage.Cd` | FAT image and CD-ROM (ISO/cue) backends for emulated drives. |
| `Spice86.MicroBenchmarkTemplate` | BenchmarkDotNet harness scaffold. |
| `tests/Spice86.Tests`, `tests/Spice86.Tests.UI` | xUnit tests (CPU, BIOS, DOS, CFG codegen, video, HTTP, boot, function tracking). |

### `Spice86.Core/Emulator/` namespace map (the navigable core)

- `CPU/` — CPU state, registers, flags, ALU, stack, IVT. `CPU/CfgCpu/` is the **CFG/JIT CPU** (parser, AST, feeder, executor, linker, control-flow graph). `CPU/Registers/` models register file with overlapping 8/16/32-bit views.
- `Memory/` — the memory bus (`Memory.cs`), `Ram`, `A20Gate`, `Mmu/` (segmentation translation), `Indexable/` and `Indexer/`/`ReaderWriter/` (typed memory access), `IMemoryDevice` (MMIO indirection).
- `Devices/` — hardware: `Video/` (VGA), `Timer/` (PIT), `ExternalInput/` (PIC), `DirectMemoryAccess/` (DMA), `Input/` (keyboard/mouse/joystick), `Sound/` (PC speaker, OPL3, SoundBlaster, GUS, MIDI/MT-32), `Cmos/` (RTC), `CdRom/`.
- `InterruptHandlers/` — BIOS (`Bios/`, `VGA/`, `Timer/`, `SystemClock/`), DOS (`Dos/`, plus `Dos/Ems`, `Dos/Xms`), input (`Input/Keyboard`, `Input/Mouse`), `Mscdex/`, and the shared dispatch/install plumbing in `Common/` (`Callback/`, `IndexBasedDispatcher/`, `RoutineInstall/`, `MemoryWriter/`).
- `OperatingSystem/` — the DOS *kernel*: `Dos.cs` facade, `DosFileManager`, `DosMemoryManager`, `DosProcessManager`, `DosDriveManager`, `DosProgramLoader`, `Structures/` (PSP, MCB, FCB, DTA, SDA, sysvars, country info, etc.), `Devices/` (CON/AUX/PRN/NUL char devices, block devices), `Batch/` (an internal COMMAND.COM-style batch engine).
- `Function/` — call/return tracking and the **override mechanism**: `FunctionHandler`, `FunctionCatalogue`, `FunctionInformation`, `IOverrideSupplier`, `CallType`.
- `ReverseEngineer/` — `CSharpOverrideHelper` (override authoring API), `CfgCodeGeneration/` (CFG → C# project emitter), `ControlFlowGraph/` analysis, `FunctionPartitioning/`, `JumpDispatcher`, `ArgumentFetcher`, `DataStructure/`.
- `VM/` — `Machine` (the assembled hardware bag), `EmulationLoop`, `PauseHandler`, `Clock/` (emulated time), `DeviceScheduler/` (event queue + scheduler thread), `Breakpoint/`, `CpuSpeedLimit/`.
- `Gdb/` — GDB-stub remote debugging server. `Http/` — REST debug API. `Mcp/` — Model Context Protocol server (LLM-facing tools). `StateSerialization/` — read/write of recorded data (memory dump, CFG, symbols, breakpoints). `LoadableFile/`, `Boot/`, `IOPorts/`, `Errors/`, `Debugger/`.

### DI / wiring approach

There is **no IoC container**. Wiring is "poor-man's DI": one giant constructor,
`Spice86DependencyInjection` (`src/Spice86/Spice86DependencyInjection.cs:115-829`), news up every
component in dependency order and passes them by constructor parameters. This is *compile-time DI*
(the class doc literally says so, line 73). It is verbose (~700 lines) but completely explicit,
debuggable, and free of reflection magic — every dependency edge is visible in one file.

---

## 2. Top-level lifecycle

- **Entry point**: `Program.Main` (`src/Spice86/Program.cs:34`). Parses CLI into a `Configuration`
  (`new CommandLineParser().ParseCommandLine(args)`), then branches on headless mode:
  - `HeadlessType.Minimal` → `new Spice86DependencyInjection(configuration); .HeadlessModeStart()` (no UI).
  - Avalonia/headless-Avalonia → starts the Avalonia desktop lifetime (`Program.cs:40-55`).
- **Alternate entry for RE**: `Program.RunWithOverrides<T>(args, checksum)` (`Program.cs:20`) injects
  `--OverrideSupplierClassName=<T>` and `--ExpectedChecksum`. This is the entry the *generated*
  C# override projects use.
- **Construction**: `Spice86DependencyInjection` builds everything (memory → PIC → clock → scheduler
  → CPU → devices → BIOS handlers → DOS → `Machine` → `ProgramExecutor`). Notable ordering
  decisions: breakpoint holders are created before the breakpoints manager to break a cycle
  (`Spice86DependencyInjection.cs:162-204`); the `MemoryAsmWriter` is shared between interrupt and
  routine installers so both write callback stubs into the same BIOS segment F000
  (`:367-373`).
- **Interrupt install** happens only when `InitializeDOS` is set: BIOS handlers
  (`:590-608`) then DOS handlers (`:637-660`) are written into emulated RAM and registered in the
  IVT via `InterruptInstaller`.
- **Run**: `ProgramExecutor` (`src/Spice86.Core/Emulator/ProgramExecutor.cs`) is a thin facade.
  Its constructor eagerly calls `programBootstrapper.LoadInitialProgram()` (`:44`). `Run()`
  (`:50-66`) applies startup breakpoints, starts the GDB server, registers a stop-after-cycles
  breakpoint, runs `EmulationLoop.Run()`, then writes recorded state (`EmulationStateDataWriter`),
  and finally shuts down via the `ShutdownCoordinator`.
- **Shutdown**: `ShutdownCoordinator` (`Spice86DependencyInjection.cs:696-704`) idempotently tears
  down the VGA timing thread, clock, HTTP server, JIT compiler threads, and the machine.

---

## 3. Main emulation loop & timing model

### The loop
`EmulationLoop.RunLoop()` (`src/Spice86.Core/Emulator/VM/EmulationLoop.cs:129-141`) is the heart:

```
_cpu.SignalEntry();
while (_cpuState.IsRunning) {
    _pauseHandler.WaitIfPaused();
    _emulationLoopScheduler.ProcessEvents();   // fire due timer/device events
    _cpu.ExecuteNext();                          // run one node or a whole hot block
    _cyclesLimiter.RegulateCycles();             // throttle to target cycles/ms
}
```

This is a **single-threaded cooperative loop**: CPU and devices interleave on one thread. Devices do
not run on their own threads (except VGA timing in async render mode and JIT background compilers —
see §11). The loop is wrapped (`StartRunLoop`, `:119-124`) by `FunctionHandler.Call(MACHINE,...)`
/`Ret(...)` so the whole run is tracked as one top-level "function" for the RE call graph.

### Timing model
- An **emulated clock** is the master time source: `EmulatedClock` (wall-clock based) or
  `CyclesClock` (advances time per executed instruction, for deterministic replay). Selected by
  `InstructionTimeScale` config (`Spice86DependencyInjection.cs:218-221`). Both implement
  `IEmulatedClock` (`Emulator/VM/Clock/`). Pause/resume hook the clock (`:223-224`).
- **`DeviceScheduler`** (`Emulator/VM/DeviceScheduler/DeviceScheduler.cs`) is a deterministic event
  queue keyed on emulated time (a `TimePriorityQueue`). Devices schedule callbacks with
  `AddEvent(handler, delayMs)`; `ProcessEvents()` fires everything due `<= clock.ElapsedTimeMs`
  (`:119-142`). Re-scheduling during servicing uses the active event's scheduled time as the base so
  periodic events stay phase-correct and don't drift on a slow host (`:67-85`). Entries are pooled to
  avoid GC churn.
- The PIT, RTC, PC speaker, SoundBlaster, floppy timing, and (in sync mode) VGA all push events onto
  the **emulation-loop scheduler**; the loop drains them once per iteration before each CPU step.
  This is the scheduling strategy: *the CPU drives the clock; the clock drives a single event queue;
  the queue fans out to devices.*
- **Cycle limiting**: `ICyclesLimiter` (`Emulator/VM/CpuSpeedLimit/`) throttles to a target
  instructions-per-ms (default ~3000; config `--Cycles`). `EmulationLoop` exposes
  Increase/DecreaseCycles for UI speed control.

### PIC / interrupts vs. the loop
External interrupts are *not* checked in the loop; they are checked by the CPU after each node, via
`CfgCpu.HandleExternalInterrupt` (see §4). The `DualPic` (8259 pair) computes the pending vector,
respecting IF and "interrupt shadowing" (the one-instruction inhibit after STI/POP SS/MOV SS).

---

## 4. CPU emulation strategy — the CFG/JIT interpreter

This is Spice86's most distinctive engineering choice. There is **one CPU**: `CfgCpu`
(`src/Spice86.Core/Emulator/CPU/CfgCpu/CfgCpu.cs`). It is not a flat opcode-switch interpreter; it
incrementally builds a **Control Flow Graph** of parsed instructions and executes nodes from it,
JIT-compiling each node to a delegate. This serves both speed *and* the RE goal (the CFG is the
artifact later turned into C#).

### Pipeline shape (parse → AST → compile → cache → link → execute)

1. **Parse** (`CfgCpu/Parser/InstructionParser.cs`). Two 256-entry handler tables:
   `_handlers[256]` for one-byte opcodes and `_handlers0F[256]` for `0F`-prefixed opcodes
   (`:27-28`). Each entry is a `Func<ParsingContext, CfgInstruction>`. Instruction *families* are
   delegated to dozens of small **specific parsers** (`Parser/SpecificParsers/`: `AluOperationParser`,
   `MovModRmParser`, `JccParser`, `Grp1Parser`, `CallParser`, ...; see the field list at
   `InstructionParser.cs:31-90`). ModR/M is decoded by a dedicated `ModRmParser`. The parser produces
   a `CfgInstruction` (`ParsedInstruction/CfgInstruction.cs`) plus two ASTs: a representation AST and
   an *execution* AST (`AttachAsts`, `CfgInstruction.cs:57`). `InstructionKind` flags classify the
   control-flow role (Call/Jump/Return/Invalid) so the graph linker knows how to wire successors.
2. **Compile** (`InstructionExecutor/Expressions/CfgNodeExecutionCompiler.cs`). The execution AST is
   turned into a `CfgNodeExecutionAction` delegate assigned to `ICfgNode.CompiledExecution`. JIT
   strategy is configurable (`JitMode`, doc at `:18-28`):
   - `InterpretedThenCompiled` (default): an interpreted delegate runs immediately; background
     threads (`max(1, CPUs-2)`) compile an optimized delegate via `System.Linq.Expressions` +
     FastExpressionCompiler and hot-swap it in (`:44-67`).
   - `InterpretedOnly` / `CompiledOnly` alternatives.
3. **Feed & cache** (`Feeder/InstructionsFeeder.cs`). Instructions are parsed *once per address* and
   cached. `CurrentInstructions` holds the cache that matches *current* memory; `PreviousInstructions`
   holds historical versions. `GetInstructionFromMemory` (`:39-50`) returns the cached node if memory
   is unchanged, else re-derives.
4. **Self-modifying code** is a first-class concern. The `CfgNodeFeeder`
   (`Feeder/CfgNodeFeeder.cs:13-19`, `58-97`) checks the graph's "next" node against live memory:
   if a node is stale (`!IsLive`), it reconciles — possibly via `SignatureReducer` (merging variants
   that differ only in non-final fields) or by injecting a **`SelectorNode`** that dispatches at
   runtime between genuinely different instructions at the same address. Memory writes flip nodes to
   non-live via memory breakpoints. This is the algorithmic core that lets a *graph* CPU handle SMC.
5. **Link** (`Linker/NodeLinker.cs`). After each executed node, the actually-taken successor is
   registered as an edge (`GetLinkedCfgNodeToExecute`, `CfgNodeFeeder.cs:41-56`), distinguishing
   `Normal` vs `CpuFault` successors. The graph thus records real control flow, including both arms of
   conditional branches as they are discovered.

### Dispatch / execution
`CfgCpu.ExecuteNext()` (`CfgCpu.cs:88-109`) resolves the next node and chooses:
- **Hot path**: if the node is the entry of a fully-discovered, live `CfgBlock`, run the whole block
  in a tight loop via `ExecuteBlock` (`:157-178`) — no per-instruction interrupt checks, exits early
  if a node went non-live (SMC) or faulted.
- **Cold path**: otherwise step a single node via `ExecuteOneNode` (`:117-149`) which checks execution
  breakpoints, runs `node.CompiledExecution(helper)`, handles `CpuException`, increments the cycle
  counter, and records last/next nodes.

After the step, `HandleExternalInterrupt` (`:200-227`) restores execution context after IRET if
needed, honors interrupt shadowing/IF, asks the `DualPic` for a pending vector, and on one available
calls `DoInterrupt` then opens a **new execution context**.

### Registers / flags / segmentation
- `State` (`CPU/State.cs`) holds registers and flags. The register file
  (`CPU/Registers/`) models EAX..EBP as 32-bit cells with overlapping indexers for
  AL/AH/AX/EAX, segment registers, etc. (`State.cs:42-86` shows the AX/AH/AL/EAX overlay pattern).
- ALU is split by width: `Alu8`/`Alu16`/`Alu32` (`CPU/Alu*.cs`), each computing flags. Flags live in
  `Flags.cs`.
- Real-mode segmentation is handled by the **MMU** (`Memory/Mmu/`, see §5): `TranslateAddress(seg,
  off)`. `Stack` (`CPU/Stack.cs`) and `InterruptVectorTable` (`CPU/InterruptVectorTable.cs`) are CPU
  helpers. The design supports 8086 and 386 real-mode variants via `RealModeMmuFactory.FromCpuModel`.

### Execution contexts (interrupts as graph context switches)
`ExecutionContextManager` (`CfgCpu/ExecutionContextManager.cs`) keeps a stack of contexts. Each
context owns a contiguous control-flow graph; an *external interrupt* opens a new context (so the
interrupt handler's graph is separate from interrupted code), and IRET restores the previous one
(`CfgCpu.cs:200-227`, doc `:54-59`). This keeps the CFG clean for code generation.

> Note: this CFG/JIT design is powerful but heavy. A from-scratch emulator that doesn't need C#
> regeneration can start with a plain decode-and-dispatch interpreter and add a CFG/JIT later. But
> the *separation* (parse → executable form → cache keyed by address → SMC invalidation) is worth
> copying even in a simple interpreter.

---

## 5. Memory model

`Memory` (`src/Spice86.Core/Emulator/Memory/Memory.cs`) is the **memory bus**. Key design points:

- **Per-byte device indirection**: `_memoryDevices` is an `IMemoryDevice[]` sized to the whole
  address space; each address points at the device that owns it (`:16`, `:39-46`). `RegisterMapping(base,
  size, device)` fills the range with a device pointer and resizes the array if needed
  (`:203-214`). RAM is the default device mapped over all of memory at construction; ROMs/MMIO
  (e.g. VGA ROM at `RegisterMapping(VgaRom.Segment<<4, ...)`, `Spice86DependencyInjection.cs:350`)
  override sub-ranges. This is a simple, uniform MMIO scheme: a read/write is a one-array-lookup
  dispatch to `device.Read/Write(address)`.
- **Indexers / typed access**: `Memory` derives from `Indexable` and exposes typed indexers (`UInt8`,
  `UInt16`, `UInt16BigEndian`, `UInt32`, `Int8/16/32`, `SegmentedAddress16/32`) built over an
  `IByteReaderWriter` (`:43-44`, `:157-200`). Guest code and overrides read/write through these
  (`UInt8[addr]`, etc.). The raw indexer `this[uint address]` (`:96-108`) is the choke point: it
  applies the **A20 gate** transform, fires **memory breakpoints** (`MonitorRead/WriteAccess`), and
  then `SneakilyRead/Write` does the device dispatch. `SneakilyRead/Write` (`:72-79`) bypasses
  breakpoints/A20 for tools that must peek without side effects.
- **Segmentation**: the `IMmu` (`Memory/Mmu/`) translates `(segment, offset)` to a linear address
  and validates access (`SegmentAccessKind`). `WriteUInt16/32Segmented` use `Mmu.TranslateAddress`
  (`:82-93`). Real-mode 8086 vs 386 behavior is selected at construction.
- **A20 gate** (`Memory/A20Gate.cs`) models the classic 20th-address-line wrap for 8086 compat.
- **Breakpoints**: `AddressReadWriteBreakpoints` holders are passed in (one for memory, one for I/O);
  `EmulatorBreakpointsManager` coordinates them with pause/state (`Spice86DependencyInjection.cs:163-204`).
  Memory write breakpoints are also how SMC detection works: a write to code flips the corresponding
  CFG node non-live.
- `ReadRam`/`WriteRam` (`:48-69`) provide bulk copy for dumps; `SearchValue` (`:132-155`) for tools.

A reimplementer's takeaway: the per-byte device-pointer array is dead simple and fast enough, and
routing *all* access through one indexer that does A20 + breakpoints + device dispatch is what makes
the debugger/RE tooling possible without polluting device code.

---

## 6. DOS emulation

The DOS kernel is its own subsystem under `Emulator/OperatingSystem/`, fronted by `Dos`
(`OperatingSystem/Dos.cs`), a facade exposing every DOS interrupt handler (`DosInt20Handler`,
`DosInt21Handler`, ... `DosInt2FHandler`) and the manager objects. It is constructed once in DI
(`Spice86DependencyInjection.cs:484-490`) and its handlers are installed into the IVT (`:637-660`).

### API dispatch organization
`DosInt21Handler` (`InterruptHandlers/Dos/DosInt21Handler.cs`, ~2360 lines) extends the base
`InterruptHandler` and registers one C# method per AH sub-function in a **dispatch table**
(`FillDispatchTable`, `:111-...`): `AddAction(0x09, PrintString)`, `AddAction(0x3D, OpenFile)`, etc.
At runtime `Run(index = AH)` looks the method up (`IndexBasedDispatcher`, see §7). This per-subfunction
method-per-handler organization is the dominant pattern across the whole codebase and is the single
most copy-worthy idea for the API surface: each service is an isolated, testable C# method keyed by a
number.

### Manager decomposition (the DOS kernel's internal structure)
- **`DosFileManager`** — file handles, SFT-like table, read/write/seek, find-first/next, mapped to
  host files via `DosPathResolver` (DOS path ↔ host path) and the drive abstraction.
- **`DosMemoryManager`** — MCB (Memory Control Block) chain allocation/free/resize; PSP creation. MCB
  structure in `Structures/DosMemoryControlBlock.cs`.
- **`DosProcessManager`** + **`DosProgramLoader`** — EXE/COM loading, PSP setup, command tail,
  environment block, EXEC (4Bh) child processes, terminate. `DosProgramLoader.LoadFile`
  (`OperatingSystem/DosProgramLoader.cs:29-...`) maps a host file to a DOS path, builds a
  `DosExecParameterBlock`, and drives the internal batch engine for startup. COM vs EXE handling lives
  in `LoadableFile/Dos/` (the loaders) and the process manager.
- **`DosDriveManager`** — drive letters mapped to host folders / FAT images / CD-ROM (`Storage.Fat`,
  `Storage.Cd`), `CurrentDirectoryStructure`.
- **`DosFcbManager`** — legacy CP/M-style FCB file ops (AH 0Fh-24h).
- **Batch engine** (`OperatingSystem/Batch/`, `DosBatchExecutionEngine.*.cs`) — an internal
  COMMAND.COM-like interpreter (argument parsing, redirection, control flow) used to launch the
  configured program and support batch/`CHOICE`.
- **Virtual devices** (`OperatingSystem/Devices/`) — `ConsoleDevice` (CON, with ANSI.SYS-style
  sequence handling in `AnsiSequenceHandler`), `AuxDevice` (AUX), `PrinterDevice` (PRN), `NullDevice`
  (NUL), plus block devices. These implement `IVirtualDevice` and are the DOS char/block device model.

### Key DOS structures (`OperatingSystem/Structures/`)
PSP (`DosProgramSegmentPrefix`), MCB (`DosMemoryControlBlock`), FCB (`DosFileControlBlock` +
extended), DTA (`DosDiskTransferArea`), SDA (`DosSwappableDataArea`), sysvars (`DosSysVars`), country
info, CDS (`CurrentDirectoryStructure`), DPB (`DosDeviceParameterBlock`), BPB, command tail,
environment block. These are thin wrappers over emulated memory at fixed addresses, written/read
through the typed indexers.

### EMS / XMS
`InterruptHandlers/Dos/Ems` (`ExpandedMemoryManager`, INT 67h) and `Dos/Xms`
(`ExtendedMemoryManager`) are optional, gated by config (`Spice86DependencyInjection.cs:375-388,
470-473`). XMS uses the A20 gate and `MemoryAsmWriter` to install its entry point.

---

## 7. BIOS & interrupts

### IVT and handler installation
The **Interrupt Vector Table** is just emulated memory at segment 0, wrapped by
`InterruptVectorTable` (`CPU/InterruptVectorTable.cs`). Handlers are installed by
`InterruptInstaller` (`InterruptHandlers/Common/RoutineInstall/InterruptInstaller.cs`):
`InstallInterruptHandler(handler)` (1) writes a tiny ASM stub into the BIOS area (segment F000) via
`MemoryAsmWriter`, (2) points `IVT[vector]` at that stub, and (3) registers a nicely-named
"function" in the `FunctionCatalogue` so it appears in dumps/codegen (`:33-40`, doc `:8-12`). This is
elegant: from the guest's view there is *real* code at the vector; the stub is a callback trampoline.

### The callback / dispatch bridge (guest asm ↔ C#)
The stub written by the default `InterruptHandler.WriteAssemblyInRam`
(`InterruptHandlers/InterruptHandler.cs:59-70`) is `RegisterAndWriteCallback(vector, Run)` followed
by `IRET`. The byte sequence is a special **callback opcode** carrying a callback index. When the CFG
CPU executes it, the `CallbackHandler` (`InterruptHandlers/Common/Callback/CallbackHandler.cs`)
dispatches index → the C# `ICallback` (`:50-60`). `CallbackHandler` extends `IndexBasedDispatcher`
and allocates callback numbers from 0x100 up (`:17-44`). So the flow is:
*guest `INT n` → IVT → F000 stub → callback opcode → `CallbackHandler.Run(index)` → C# handler `Run()`
→ stub's `IRET`.* When dumping memory, `ReplaceAllCallbacksInRamImage` (`:67-76`) rewrites callbacks
back to plain `INT n` so the dump is clean.

### `IndexBasedDispatcher` — the universal dispatch primitive
`InterruptHandlers/Common/IndexBasedDispatcher/IndexBasedDispatcher.cs` is a generic
`Dictionary<int, IRunnable>` dispatcher. Both `CallbackHandler` (index = callback number) and every
`InterruptHandler` (index = AH sub-function) derive from it. `InterruptHandler`
(`InterruptHandlers/InterruptHandler.cs`) adds `AddAction(index, Action)`, the default ASM-writer,
and helpers like `SetCarryFlag(value, setOnStack)` (`:99-104`) that also patch the FLAGS image on the
interrupt stack so `IRET` returns the right flags. `RunFromOverriden()` (`:122-127`) lets a C#
override call the handler directly with the interrupt-stack editing disabled.

### Implemented BIOS services (the API surface)
Installed in DI (`Spice86DependencyInjection.cs:590-608`):
- INT 10h — **VGA BIOS** (`InterruptHandlers/VGA/VgaBios.cs` + `VgaFunctionality`): modes, cursor,
  scrolling, char/pixel output, palette.
- INT 13h — disk/floppy (`Bios/SystemBiosInt13Handler` + `FloppyDiskController`).
- INT 11h — equipment list; INT 12h — memory size; INT 14h — serial; INT 15h — system services (A20,
  extended memory move, wait); INT 16h — **keyboard** (`Input/Keyboard/KeyboardInt16Handler` + BIOS
  keyboard buffer); INT 17h — printer; INT 1Ah — system clock/RTC; INT 70h — RTC IRQ8; INT 8 — timer
  tick (`Timer/TimerInt8Handler`); INT 9 — keyboard IRQ1 (`Input/Keyboard/BiosKeyboardInt9Handler`);
  INT 1Ch — user timer (dummy); INT 74h — PS/2 mouse IRQ12; default IRQ handlers for IRQs 3,4,5,7,10,11
  (`InstallDefaultInterruptHandlers`, `:833-841`).
- INT 33h — **mouse driver** (`Input/Mouse/MouseInt33Handler` + `MouseDriver`), installed as an
  assembly routine so it has a real entry address.
- The **BIOS Data Area** (`InterruptHandlers/Bios/Structures/BiosDataArea.cs`) is memory at 0040:0000
  shared by BIOS handlers and devices (equipment word, keyboard buffer ptrs, tick count, video mode).

---

## 8. Device / hardware model

### Registration & I/O dispatch
Devices that expose ports implement `IIOPortHandler` (`IOPorts/IIOPortHandler.cs`) and register
themselves with the **`IOPortDispatcher`** (`IOPorts/IOPortDispatcher.cs`) via
`AddIOPortHandler(port, handler)`. The dispatcher is a `Dictionary<int, IIOPortHandler>`; on
read/write it monitors I/O breakpoints, looks up the port, and forwards (`:50-143`). Unhandled ports
fall through to `DefaultIOPortHandler` (`IOPorts/DefaultIOPortHandler.cs`) which logs and returns
0xFF / throws if `--FailOnUnhandledPort`. Most devices subclass `DefaultIOPortHandler` to get the
default behavior for ports they don't claim.

### IRQ handling
The **`DualPic`** (`Devices/ExternalInput/DualPic.cs`, two cascaded 8259s) is the IRQ controller.
Devices raise IRQs on it; the CPU pulls the next vector via `DualPic.ComputeVectorNumber()` after each
node (`CfgCpu.cs:219`). Masking, EOI, and priority live in `DualPic`. When DOS init is off, all IRQs
are masked (`Spice86DependencyInjection.cs:231-236`).

### The device set (all in `Emulator/Devices/`)
- **Video** (`Video/`): `VideoState` (registers — CRTC/Sequencer/Graphics/Attribute/DAC modeled in
  `Video/Registers/`), `VgaIoPortHandler` (port 3C0-3DA etc.), `Renderer` + SIMD 256-color renderer
  (`VgaRenderer256ColorSimd`), `VgaTimingEngine` (schedules retrace/blink events), `VgaCard` (bridges
  renderer output to the GUI), `VgaRom`.
- **Timer** (`Timer/`): `PitTimer` (8253/8254, 3 channels) schedules ticks on the device scheduler and
  drives INT 8 and the PC speaker.
- **PIC**: `Devices/ExternalInput/DualPic`. **CMOS/RTC**: `Devices/Cmos/RealTimeClock`.
- **DMA** (`DirectMemoryAccess/`): `DmaBus` with channels; used by SoundBlaster and the floppy
  controller (`Spice86DependencyInjection.cs:492-496`).
- **Input** (`Input/`): `Intel8042Controller` (keyboard/mouse controller + A20), `Mouse`,
  `Joystick`, plus the BIOS keyboard buffer. Host input events arrive via an `InputEventHub` and are
  drained on the emulation thread (see §9, §11).
- **Sound** (`Sound/`): `PcSpeaker`, `Opl3Fm` (OPL3/AdLib), `SoundBlaster` (DSP + DMA + IRQ +
  `BlasterString` env var), `GravisUltraSound`, `Midi` (incl. MT-32 via `Midi/MT32`). All feed a
  `SoftwareMixer` which talks to the host audio backend.
- **CD-ROM** (`CdRom/`) backing MSCDEX (INT 2Fh via `InterruptHandlers/Mscdex`).

Each device is a plain class given exactly the collaborators it needs (state, dispatcher, PIC,
scheduler, clock, logger) — no global service locator. Devices schedule their own timing on the
`DeviceScheduler`, keeping timing deterministic and tied to emulated time.

---

## 9. Host / UI integration

- **UI framework**: Avalonia (cross-platform XAML). `App.axaml.cs`, `Views/`, `ViewModels/` in
  `src/Spice86/`. MVVM via CommunityToolkit.Mvvm; UI-thread marshaling through a `UIDispatcher`
  wrapper over `Dispatcher.UIThread`.
- **The emulator runs on its own thread.** `EmulatorSession.EmulatorThread`
  (`src/Spice86/ViewModels/EmulatorSession.cs:64-93`) starts a dedicated `Thread { Name="Emulator" }`
  that calls `ProgramExecutor.Run()`. The UI thread never blocks on emulation. Status/IsRunning are
  posted back via the dispatcher.
- **Video rendering**: the emulator's `Renderer` produces frames; `VgaCard` exposes them to the GUI
  (`IGuiVideoPresentation`). In **sync** render mode VGA timing events ride the emulation-loop
  scheduler; in **async** mode a dedicated `DeviceSchedulerThread` ("VGA Timing") pumps them
  (`Spice86DependencyInjection.cs:339-348, 546-548`). The `EmulatorDisplayViewModel` receives mode
  changes and presents the bitmap.
- **Input**: `InputEventHub` queues host keyboard/mouse events; the emulation loop drains them every
  100 emulated-time units via a self-rescheduling scheduler event
  (`EmulationLoop.cs:71-78`) so input is processed on the emulation thread, deterministically.
- **Audio**: `SoftwareMixer` (`Devices/Sound/`) mixes device channels and writes to the configured
  host `AudioEngine`; it honors pause via the `PauseHandler`.
- **Debug / RE servers** (the "headless" surfaces, all optional):
  - **GDB stub** (`Emulator/Gdb/GdbServer.cs`) — a real GDB remote server on its own thread for
    register/memory/breakpoint inspection and stepping; also exposes custom commands that drive the RE
    dumps.
  - **HTTP debug API** (`Emulator/Http/Spice86HttpApiServer.cs` + `Controllers/`) — REST endpoints for
    state and memory (`HttpApiMemoryController`, `HttpApiStatusController`), gated by `--HttpApiPort`.
  - **MCP server** (`Emulator/Mcp/`, `McpHttpHost`) — exposes emulator control/inspection as
    Model Context Protocol tools (`EmulatorMcpTools`) so an LLM agent can drive reverse engineering.
    `EmulatorMcpServices` aggregates the inspectable subsystems (`Spice86DependencyInjection.cs:475-477,
    610-619`). This is the modern, distinctive "LLM-assisted RE" surface.

---

## 10. The reverse-engineering tooling (Spice86's distinctive value)

This is what makes Spice86 more than an emulator. The strategy: **run the program, observe real
behavior, build a CFG, and emit equivalent C# you can refine function-by-function** — all without
external tools (Ghidra is now optional).

### Function tracking & call graph
`FunctionHandler` (`Emulator/Function/FunctionHandler.cs`) wraps every CALL/RET/INT/IRET. On each
call it consults the `FunctionCatalogue` (`GetOrCreateFunctionInformation`), records the caller, and
maintains a `FunctionCallStack` with mismatch detection and a depth guard (`:82-103`, `MaxCallStackDepth
= 1000`). This produces the dynamic call graph and per-function metadata used by codegen and dumps.

### C# function overrides (the override mechanism)
A user (or the generated project, or an LLM) provides an `IOverrideSupplier`
(`Emulator/Function/IOverrideSupplier.cs`) that returns a `Dictionary<SegmentedAddress,
FunctionInformation>`. Authors write overrides by subclassing **`CSharpOverrideHelper`**
(`Emulator/ReverseEngineer/CSharpOverrideHelper.cs`), which exposes the full machine — registers as
properties (`AX`, `BX`, flags, ...), `Memory`/`UInt8/16/32` indexers, `Stack`, `Alu8/16/32`, the
`Machine` — plus control-flow helpers `FarJump`, `FarRet`, `NearJump`, `InterruptRet`,
`JumpDispatcher`, and `DefineFunction(seg, off, overrideFunc)` to register an override
(`:381-427`, `:462-496`).

How it activates: when `--UseCodeOverride true`, `FunctionHandler.Call` checks
`currentFunction.HasOverride` and, if present, calls `currentFunction.CallOverride()` **instead of
executing the emulated asm** (`FunctionHandler.cs:84-88`). So overrides are interception *at the call
boundary*, swapping a chunk of guest asm for a C# method that mutates the same `State`/`Memory`. This
is the key cleanliness property: overrides live entirely outside the CPU core; the core only asks "is
there an override at this entry?"

### CFG → runnable C# project generation
On exit (when not running with overrides active), the explored CFG is turned into a C# project by
`Emulator/ReverseEngineer/CfgCodeGeneration/`: `CfgCSharpGenerator`/`CfgCSharpDumper`,
`GenerationPlanBuilder`, `MethodEmitter`/`CSharpAstEmitter`/`TransferEmitter`,
`GeneratedProjectScaffolder`. It writes (README §"Reverse engineering process", lines 314-349):
- `spice86dumpCfgGeneratedOverrides.cs` — a `CfgGeneratedOverrideSupplier` + `CfgGeneratedOverrides :
  CSharpOverrideHelper` mapping every discovered function via `DefineFunction`.
- `GeneratedProject/` — a self-contained runnable project whose `Program.cs` calls
  `Program.RunWithOverrides<...>` with `--ExpectedChecksum` so overrides can't run against the wrong
  binary. You then rewrite generated functions to discover intent (LLM-friendly).

### Memory dumps, execution flow, breakpoints, Ghidra
On exit (`EmulationStateDataWriter`, wired in `Spice86DependencyInjection.cs:457-461`) Spice86 dumps:
a memory image (callbacks erased, see §7), `spice86dumpExecutionFlow.json` (functions, labels,
executed instructions), `spice86dumpCfgBlocks.json` / partitions, a Ghidra-compatible symbols file,
and user breakpoints. The **Ghidra plugin** (external repo) consumes the memory dump + symbols +
execution flow for optional static analysis (README lines 39, 326). The CFG can be **reloaded** into
a fresh run (`--ReloadCfgGraph`, `CfgGraphReloader`, `Spice86DependencyInjection.cs:861-875`) so the
graph persists across sessions.

### Breakpoints / instrumentation layering
All instrumentation rides on the choke points already described: memory/I/O breakpoints in the
`Memory`/`IOPortDispatcher` indexers, execution breakpoints in `ExecuteOneNode`, and call tracking in
`FunctionHandler`. The RE tooling therefore **does not pollute** device or CPU logic — it observes
through interfaces (`IMemory`, `IFunctionHandlerProvider`, `EmulatorBreakpointsManager`) and the
callback/override boundaries. This separation is the single biggest architectural lesson.

---

## 11. Cross-cutting strategies

- **Threading model**: one emulation thread (everything: CPU + devices + scheduler) — see
  `EmulatorSession` (`src/Spice86/ViewModels/EmulatorSession.cs:64`) and `EmulationLoop.RunLoop`.
  Auxiliary threads only for: UI (Avalonia), background JIT compilation
  (`CfgNodeExecutionCompiler`, `max(1,CPUs-2)` threads, `:50-62`), async VGA timing
  (`DeviceSchedulerThread`), GDB server, HTTP/MCP servers. Cross-thread input goes through
  `InputEventHub` and is replayed on the emulation thread. This keeps the *guest-visible* state
  single-threaded and deterministic while offloading compilation/IO.
- **Determinism**: emulated time is a first-class clock; all device timing is scheduled against it,
  and `CyclesClock` enables fully deterministic, replayable runs (essential for RE reproducibility).
- **Configuration**: a single immutable `Configuration` (`Spice86.Core/CLI/`), parsed from the command
  line, threaded everywhere. Feature flags gate subsystems (`InitializeDOS`, `Xms`, `Ems`,
  `UseCodeOverride`, `FailOnUnhandledPort`, render mode, JIT mode, cycles, HTTP/MCP ports).
- **Design patterns**: heavy use of interfaces at boundaries (`IMemory`, `IMemoryDevice`,
  `IIOPortHandler`, `IInterruptHandler`, `IRunnable`, `IFunctionHandlerProvider`, `IEmulatedClock`,
  `ICyclesLimiter`, `IGuiVideoPresentation`); the **`IndexBasedDispatcher` table** pattern for all
  numeric dispatch (interrupts, callbacks); facade objects (`Machine`, `Dos`, `ProgramExecutor`);
  manual constructor DI; the **visitor/AST** pattern in the CPU; the **scheduler/event-queue**
  pattern for timing; the **strategy** pattern for JIT mode and clock type.
- **Testing**: substantial xUnit suite (`tests/Spice86.Tests/`) organized by subsystem — CPU
  (`CpuTests`, `CfgCpu`), BIOS, DOS, video, boot, function tracking, CFG code generation, HTTP,
  SIMD, reverse-engineer. The clean interfaces and single-thread determinism make subsystems
  individually testable (e.g. `ReplaceIOPortHandler` exists specifically for test harnesses,
  `IOPortDispatcher.cs:45-47`).

---

## 12. Lessons for a from-scratch emulator

What Spice86 gets right (copy these):

1. **One memory choke point.** Route every guest read/write through a single typed indexer that does
   address transform (A20) + breakpoints + device dispatch. Devices/MMIO are just an
   `IMemoryDevice[]` pointer-per-byte (or per-page) array. This single decision unlocks the debugger,
   SMC detection, and RE tooling for free.
2. **Numeric dispatch tables everywhere.** Model interrupts (by AH), callbacks (by index), and I/O
   (by port) as `Dictionary<int, handler>` / arrays. One method per service. It's trivial to read,
   test, and extend, and it maps 1:1 to the DOS/BIOS API surface.
3. **Interrupt handlers as installed asm stubs + C# callbacks.** Write a real trampoline into guest
   memory, point the IVT at it, and bridge to C# via a callback opcode. The guest sees real code;
   you keep logic in C#; dumps stay clean by erasing callbacks.
4. **Keep instrumentation out of the core.** Breakpoints, call tracking, and overrides observe
   through interfaces and boundaries (call entry, memory indexer, port dispatcher). The CPU and
   devices never know the RE tooling exists.
5. **The override boundary is the call site.** Intercepting whole functions at their entry address
   (FunctionHandler checking `HasOverride`) is a clean, incremental way to replace asm with C# — and
   to generate that C# from a recorded CFG.
6. **Deterministic time + a single event scheduler.** A master emulated clock plus one time-ordered
   event queue makes device timing simple, correct, and replayable. Schedule, don't poll.
7. **Single-threaded guest state.** Keep CPU+devices on one thread; push host input through a queue
   replayed on that thread; offload only compilation/UI/IO to other threads.
8. **Explicit (manual) DI.** A single wiring file is verbose but utterly transparent — every
   dependency edge is visible and order-controlled. No reflection, no container surprises.

What to be cautious about / avoid:

- **The CFG/JIT CPU is heavy.** It's brilliant for the RE-regeneration goal, but it is a lot of
  machinery (parser families, AST, expression compilation, self-modifying-code reconciliation,
  execution contexts, node liveness). If you don't need to *regenerate C#*, start with a
  decode-and-dispatch interpreter and only adopt the parse→executable→address-cached→SMC-invalidate
  *shape*, not the full graph. Add JIT later behind an interface (Spice86's `JitMode` shows how).
- **The DI constructor is ~700 lines.** Transparent but unwieldy; consider grouping subsystem
  factories while keeping the explicit, container-free spirit.
- **Per-byte device array** costs memory (one reference per address). Per-page mapping is a cheap
  improvement if needed.

Minimal component set + suggested build order:

1. `SegmentedAddress`, register/flags `State`, real-mode MMU (seg×16+off).
2. Memory bus: `IMemoryDevice`, RAM, single typed indexer with A20 + (stub) breakpoints.
3. CPU interpreter: fetch/decode/dispatch (one handler table), ALU by width, stack, exceptions.
4. IVT + interrupt-handler base + `IndexBasedDispatcher` + callback bridge + `InterruptInstaller`.
5. PIC (8259) + emulated clock + one `DeviceScheduler`; wire the main loop
   (process events → step CPU → check IRQ → throttle).
6. PIT (INT 8/1Ch), BIOS keyboard (INT 9/16h), BIOS video (INT 10h) + a renderer, BIOS data area.
7. DOS kernel: PSP, MCB memory manager, COM/EXE loader, INT 21h dispatch table, file manager over
   host FS via a path resolver, char devices (CON/AUX/PRN/NUL).
8. UI thread + render/input/audio bridges (run the emulator on its own thread).
9. RE layer (optional, last): function tracking, override boundary, memory/exec dumps, and — only if
   desired — a CFG and C# generator. Add a GDB/HTTP/MCP debug surface on top of the same interfaces.

---

### Key file index (jump list)

- Entry / wiring: `src/Spice86/Program.cs`, `src/Spice86/Spice86DependencyInjection.cs`
- Loop / timing: `Emulator/VM/EmulationLoop.cs`, `Emulator/VM/DeviceScheduler/DeviceScheduler.cs`,
  `Emulator/VM/Clock/`, `Emulator/ProgramExecutor.cs`
- CPU: `Emulator/CPU/CfgCpu/CfgCpu.cs`, `.../Parser/InstructionParser.cs`,
  `.../Feeder/CfgNodeFeeder.cs`, `.../Feeder/InstructionsFeeder.cs`,
  `.../InstructionExecutor/Expressions/CfgNodeExecutionCompiler.cs`,
  `.../ParsedInstruction/CfgInstruction.cs`, `Emulator/CPU/State.cs`
- Memory: `Emulator/Memory/Memory.cs`, `Emulator/Memory/IMemoryDevice.cs`, `Emulator/Memory/Mmu/`
- Interrupts/BIOS: `Emulator/InterruptHandlers/InterruptHandler.cs`,
  `.../Common/IndexBasedDispatcher/IndexBasedDispatcher.cs`,
  `.../Common/Callback/CallbackHandler.cs`, `.../Common/RoutineInstall/InterruptInstaller.cs`
- DOS: `Emulator/OperatingSystem/Dos.cs`, `.../DosProgramLoader.cs`,
  `Emulator/InterruptHandlers/Dos/DosInt21Handler.cs`, `Emulator/OperatingSystem/Structures/`
- I/O & devices: `Emulator/IOPorts/IOPortDispatcher.cs`, `Emulator/Devices/`
- RE tooling: `Emulator/ReverseEngineer/CSharpOverrideHelper.cs`, `Emulator/Function/FunctionHandler.cs`,
  `Emulator/Function/IOverrideSupplier.cs`, `Emulator/ReverseEngineer/CfgCodeGeneration/`
- Debug surfaces: `Emulator/Gdb/GdbServer.cs`, `Emulator/Http/`, `Emulator/Mcp/`
