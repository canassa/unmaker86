# DOSBox Staging — Architecture Reverse-Engineering Notes

A deep architectural study of DOSBox Staging (a modernized C++23 fork of DOSBox),
intended as a reference for building a brand-new DOS emulator from scratch. Focus is
on **structure, algorithms, strategy, and the DOS/BIOS API surface** — not per-opcode
minutiae.

Source checkout: `references/dosbox-staging/` (~723 C/C++ files). All paths below are
relative to that root unless absolute. Where I infer rather than confirm, I say so.

> **Staging vs classic DOSBox — top-level takeaways.** Staging keeps DOSBox's core
> emulation design intact (same CPU cores, same PIC event queue, same page-handler
> memory model, same emulated-DOS-kernel approach) but modernizes the *scaffolding*:
> C++23 with RAII/`std::function`/smart pointers, a real config-section object model,
> a **threaded audio mixer**, a **shader-based render pipeline**, modular directories
> (`audio/`, `midi/`, `capture/`, `network/`, `webserver/`), and it **removed the
> classic save-state system entirely** (see §10). The hot loops (CPU dispatch, memory
> read/write, PIC queue) are deliberately *unmodernized* C-style code for speed.

---

## 1. Source tree layout

`src/` is the whole emulator; there is **no top-level `include/`** (a change from
classic DOSBox) — headers live next to their `.cpp` and are included with
module-relative paths (`#include "cpu/cpu.h"`).

| Dir | Responsibility |
|---|---|
| `src/main.cpp` | `int main()`: CLI parsing, logging, config dir, SDL init, module init, hand-off to shell. |
| `src/dosbox.cpp` / `dosbox.h` | The "motherboard": global machine type, the **main emulation loop** (`normal_loop`), CPU-cycle auto-tuning, module init/destroy order, restart. |
| `src/cpu/` | x86 emulation. Multiple **cores** (`core_normal`, `core_simple`, `core_full`, `core_dyn_x86`, `core_dynrec`, `core_prefetch`), `paging.cpp` (TLB/page handlers), `callback.cpp` (guest↔host bridge), `flags`/`lazyflags`, `modrm`, `mmx`. |
| `src/fpu/` | x87 FPU emulation (separate from CPU cores). |
| `src/hardware/` | All emulated devices: `pic.cpp` (8259 + **event queue/scheduler**), `timer.cpp` (8254 PIT), `dma.cpp` (8237), `memory.cpp` (RAM + page handlers + A20), `cmos.cpp`, `port.cpp` (I/O dispatch), `pci_bus.cpp`, plus subdirs `video/` (VGA/SVGA/Voodoo/ReelMagic), `audio/` (SB, GUS, OPL, PC speaker, etc.), `input/` (keyboard, mouse, joystick), `serialport/`, `network/`. |
| `src/ints/` | BIOS + interrupt service routines: `bios.cpp` (POST/IVT/INT 11–1A/70), `bios_disk.cpp` (INT 13h), `bios_keyboard.cpp` (INT 9/16h), `int10*.cpp` (video BIOS INT 10h + VESA), `ems.cpp` (INT 67h), `xms.cpp`, `bios_pci.cpp`. |
| `src/dos/` | The **emulated DOS kernel**: `dos.cpp` (INT 20/21/25/26/27 dispatch), `dos_execute.cpp` (EXE/COM loader), `dos_memory.cpp` (MCB chain), `dos_files.cpp`/`dos_classes.cpp` (PSP/DTA/FCB), `drives.cpp` + `drive_*.cpp` (host-FS/FAT/ISO/overlay/virtual drives), `dos_mscdex.cpp`, `dos_devices.cpp`, `programs*.cpp` + `programs/` (built-in commands like MOUNT, IMGMOUNT). |
| `src/shell/` | `COMMAND.COM` reimplemented in C++ (`shell.cpp`, `shell_cmds.cpp`, `shell_misc.cpp`), batch files, autoexec. |
| `src/gui/` | Host boundary: `sdl_gui.cpp` (window/event/present), `mapper.cpp` (input mapping + hotkeys), `render/` (scaler + OpenGL/SDL renderers + shader pipeline), `titlebar`, `clipboard`. |
| `src/audio/` | `mixer.cpp` (the **threaded software mixer**), compressor, noise gate, envelope, disk-noise, OPL capture. |
| `src/midi/` | MIDI device backends (FluidSynth, MT-32, SoundCanvas, ALSA/coreaudio/win32). |
| `src/capture/` | Screenshot/video/audio capture (image/, video/). |
| `src/config/` | `setup.cpp`/`setup.h` (the `Property`/`Section` object model), `config.cpp` (the `Config` controller, file parsing). |
| `src/misc/` | Cross-cutting utilities: `messages` (i18n), `cross` (paths), `support`, `types.h` (`Bitu`/`Bits`), `video.h`, logging. |
| `src/utils/` | `checks.h` (`CHECK_NARROWING`), `math_utils`, `mem_host`/`mem_unaligned` (endian-safe host access), `bitops`, `rwqueue`, etc. |
| `src/debugger/` | Optional curses-based debugger (compile-time `C_DEBUGGER`). |
| `src/network/`, `src/webserver/` | Ethernet/IPX backends; an embedded web server (a Staging addition). |
| `src/libs/` | Vendored third-party code (loguru, simde, decoders, etc.) — follows its own style, not reformatted. |

---

## 2. Top-level lifecycle — how the machine is assembled

Entry point: `src/main.cpp:577 main()`. Order:

1. **CLI parse**: `CommandLine command_line(argc, argv)`; `control = std::make_unique<Config>(...)` — `control` is the global config controller (`config/config.h`).
2. **Output-only short-circuits**: `--help`, `--version`, `--printconf`, `--list-*`, `--editconf` etc. handled and exit (`maybe_handle_command_line_output_only_actions`, `main.cpp:383`).
3. **Config dir + register sections**: `init_config_dir()`, then `DOS_Locale_AddMessages()`, `RENDER_AddMessages()`, `GFX_AddConfigSection()`, then **`DOSBOX_InitModuleConfigsAndMessages()`** (`dosbox.cpp:1054`) — every module registers its `[section]` and help text *before* any config file is read.
4. **Write/parse config**: `maybe_write_primary_config()` then `control->ParseConfigFiles()`.
5. **SDL + modules + GUI**:
   ```
   GFX_InitSdl();            // main.cpp:681
   DOSBOX_InitModules();     // constructs every device
   GFX_InitAndStartGui();
   MAPPER_BindKeys(...);
   SHELL_InitAndRun();       // starts the emulated machine
   DOSBOX_DestroyModules();
   GFX_Destroy();
   ```

**Config/section system** (`config/setup.h`): a clean object model — the key
modernization over classic DOSBox's stringly-typed config.
- `Value` is a tagged union (`V_HEX/BOOL/INT/STRING/DOUBLE`).
- `Property` (abstract) + concrete `PropInt/PropBool/PropString/PropPath/PropHex/PropMultiVal`. Each has a `Changeable` policy: `Always / WhenIdle / OnlyAtStart / Deprecated`.
- `Section` is abstract; `SectionProp` holds an ordered `deque<Property*>`; `AutoExecSection` holds raw lines.
- Modules **register** properties (e.g. `add_dosbox_config_section`, `dosbox.cpp:781`) and attach an **update handler** (`section->AddUpdateHandler(notify_dosbox_setting_updated)`) so live setting changes re-init only what's needed. This is the wiring backbone: there is no central registry of devices — each module's `*_AddConfigSection` + `*_Init` pair self-registers.

**Two-phase init** (the assembly order is load-bearing):
- `DOSBOX_InitModuleConfigsAndMessages()` (`dosbox.cpp:1054`) — declare config + messages. Note ordering constraints called out in comments (MIDI section must come *after* FluidSynth/MT-32/SoundCanvas, `dosbox.cpp:1075`).
- `DOSBOX_InitModules()` (`dosbox.cpp:1117`) — actually construct devices, in dependency order: `DOSBOX_Init` (IO, PAGING, MEM, CALLBACK, PIC, PROGRAMS, TIMER, CMOS) → CPU → FPU → DMA → VGA → KEYBOARD → PCI → audio devices → MIXER/MIDI → **BIOS → INT10 → MOUSE → ... → DOS** → AUTOEXEC. CPU/memory/PIC/callback come first because everything else depends on them; DOS comes near the end because it depends on BIOS + devices.

**Shutdown**: `DOSBOX_DestroyModules()` (`dosbox.cpp:1171`) destroys in **reverse** order; each module exposes `*_Destroy()`. Most modules wrap state in a `std::unique_ptr<T>` reset to `{}` (RAII), e.g. PIC `pic = {}` (`pic.cpp:701`), DOS `dos_module = {}`. `DOSBOX_RequestShutdown()` sets an atomic flag the run loop polls.

---

## 3. Main emulation loop & timing model

This is the most important subsystem to get right and the easiest to get subtly wrong.

**The run loop.** `DOSBOX_RunMachine()` (`dosbox.cpp:422`) just calls the current
`LoopHandler` repeatedly until it returns non-zero or shutdown is requested. The
default handler is `normal_loop()` (`dosbox.cpp:113`). `LoopHandler` is swappable
(`DOSBOX_SetLoop`) — e.g. the BIOS boot path and debugger install their own loops.

`normal_loop` body (`dosbox.cpp:117`):
```
while (true) {
  if (PIC_RunQueue()) {                 // cycles remain this millisecond?
      ret = (*cpudecoder)();            // run the active CPU core
      if (ret < 0) return 1;            // stop request
      if (ret > 0) {                    // a callback fired
          if (ret >= CB_MAX) return 0;
          result = Callback_Handlers[ret]();   // run the C++ handler
          if (result) return result;
      }
  } else {                              // millisecond exhausted
      if (HostRate) GFX_MaybePresentFrame();
      if (!GFX_PollAndHandleEvents()) return 0;
      if (ticks.remain > 0) { TIMER_AddTick(); --ticks.remain; }
      else { increase_ticks(); return 0; }
  }
}
```

**Timing model = "1 tick == 1 ms", CPU measured in cycles per ms.**
- `CPU_CycleMax` = cycles allotted per emulated millisecond. The CPU core decrements `CPU_Cycles` per instruction (`while (CPU_Cycles-->0)`, `core_normal.cpp:135`).
- `PIC_RunQueue()` (`pic.cpp:530`) is the scheduler heartbeat: it folds `CPU_Cycles` back into `CPU_CycleLeft`, fires any due PIC events, computes how many cycles until the *next* scheduled event, sets `CPU_Cycles` to that bound, then runs pending IRQs (`PIC_runIRQs`). So the CPU runs in bursts that end exactly at the next timed event — a clean **event-driven scheduling** strategy rather than per-instruction polling.
- When cycles for the ms are exhausted, the loop syncs to wall clock: `increase_ticks()` (`dosbox.cpp:177`) compares `GetTicksUs()` against the last tick, computes how many real ms elapsed (`ticks.remain`, capped at 20), and for each it calls `TIMER_AddTick()` (`pic.cpp:607`) which resets `CPU_CycleLeft = CPU_CycleMax`, bumps `PIC_Ticks`, decrements every queued event's index by 1.0, and fires all registered tick handlers (devices polling once per ms). If no real time elapsed it `sleep_for(1ms)` to avoid busy-spin.

**The PIC event queue** (`pic.cpp:183`–`575`) is the core scheduler:
- A fixed pool of 512 `PICEntry{ index, value, handler, next }` nodes, kept as a sorted singly-linked list (`AddEntry`, `pic.cpp:426`). `index` is fractional milliseconds-from-now.
- `PIC_AddEvent(handler, delay, val)` schedules; `PIC_RemoveEvents` cancels. Every device that needs future work (PIT reload, DMA completion, sound buffer fill, VGA retrace) schedules itself here. **There is one timeline, driven by CPU cycle progress** — not real threads.

**CPU cycle budgeting / auto-adjust.** If `CPU_CycleAutoAdjust` is on, `increase_ticks`
(`dosbox.cpp:177`–396) measures the ratio of scheduled vs. actually-done ticks and
rescales `CPU_CycleMax` toward 100% host utilization, with many tuning heuristics
(clamped at `CpuCyclesMax = 2'000'000`, floor `auto_cpu_cycles_min = 200`). The code
itself flags these as "full of magic constants with zero explanation" — a candidate
for redesign in a from-scratch emulator. Fixed-cycles mode just leaves `CPU_CycleMax`
constant.

**Frame/audio cadence.** Video and audio are *not* on the CPU timeline:
- Audio runs on a dedicated **mixer thread** (§9) driven by the host's SDL audio callback; emulated sound devices push samples into per-channel buffers via PIC tick/event handlers.
- Video presentation: in `HostRate` presentation mode the loop calls `GFX_MaybePresentFrame()` from inside the millisecond-poll branch ("cooperative multitasking … called 2–5 times per tick", `dosbox.cpp:142`). VGA rendering itself is scheduled per-scanline/per-frame via PIC events. This avoids moving the whole emulator off the main thread.

**Interrupt timing nuance worth copying.** When an IRQ is raised by an I/O write
(rather than a scheduled event), the PIC zeroes `CPU_Cycles` so the CPU stops ASAP, but
`PIC_ActivateIRQ` (`pic.cpp:323`) injects a 2-cycle delay so the guest executes a couple
instructions before the IRQ is picked up — real hardware does this and several demos
depend on it.

---

## 4. CPU emulation strategy

**Cores** (selected at `cpu.cpp:3548`+ from `core=` setting; dispatch via the global
function pointer `CPU_Decoder* cpudecoder`, `cpu.h:96`):
- `normal` — interpreter, accurate, the reference. `CPU_Core_Normal_Run` (`core_normal.cpp:133`).
- `simple` — trimmed interpreter for speed.
- `full` — most complete/slow interpreter (separate decode pipeline in `core_full/`).
- `prefetch` (a.k.a `386_prefetch`) — interpreter that models the prefetch queue; requires the normal core (`cpu.cpp:3607`).
- `dynamic` — `core_dyn_x86` (x86/x64 host JIT, `risc_x64.h`) — classic DOSBox dynamic core.
- `dynrec` — `core_dynrec` recompiler with multiple RISC backends (`risc_x64.h`, `risc_armv8le.h`) — the portable JIT used on ARM etc.
- `auto` — starts on `normal`, then `CpuAutoDetermineMode` switches to a dynamic core once protected mode is entered (`cpu.cpp:2188`).

Each core also has a **`*_Trap_Run` variant** (e.g. `CPU_Core_Normal_Trap_Run`,
`core_normal.cpp:186`) used for single-stepping: runs exactly one instruction then raises
a debug exception, then restores `cpudecoder`.

**Fetch / decode / dispatch (interpreter).** The normal core is a giant computed
`switch` (`core_normal.cpp:153`):
- A static `core` struct holds decode state: `cseip` (linear CS:EIP), segment bases, prefix flags, EA table pointer.
- `LOADIP`/`SAVEIP` macros translate between `reg_eip` and the cached linear `cseip`.
- `Fetchb/w/d` read opcode bytes through the paged memory system and advance `cseip`.
- The dispatch index is `cpu.code.big*0x200 + opcode_byte`, selecting 16- vs 32-bit decode tables. Prefixes (`66`/`67`/`F2`/`F3`/segment) are handled by mutating `core.prefixes`/EA table and `goto restart_opcode`.
- The opcode bodies are **`#include`d** from generated header tables (`core_normal/prefix_none.h`, `prefix_0f.h`, `prefix_66.h`, `prefix_66_0f.h`, `core_normal.cpp:154`). Instruction semantics live in `instructions.h`. This table-via-include pattern is how DOSBox keeps one set of opcode logic shareable across the 16/32-bit and operand-size variants.
- Effective-address computation is a dispatch through `EATable[(prefix&1)*256]` of `GetEAHandler` function pointers (`core_normal.cpp:82`).

**Flags** are computed **lazily** (`lazyflags.h`, `FillFlags()` at loop exit,
`core_normal.cpp:178`): the core stores the operation + operands and only materializes
EFLAGS when actually read — a major interpreter speed trick worth replicating.

**Modes.** `CPUBlock cpu` (`cpu.h:541`) holds `cpl`, `cr0`, `pmode`, the `gdt`/`idt`
descriptor tables, stack/code `big` flags, the `hlt` save area, and pending exception
`{which,error}`. Real mode, protected mode, and v86 are all handled by the same cores
branching on `cpu.pmode` and selector/descriptor logic (`Descriptor`, `DescriptorTable`,
`GDTDescriptorTable`, `TSS_16/TSS_32`, `cpu.h:271`–539). Architecture level is
`ArchitectureType` (8086…Pentium-MMX, `cpu.h:29`) gating CPUID/feature behavior.

**Paging** (`paging.h`): optional, enabled with CR0.PG. A software **TLB** of host
pointers (`PagingBlock::tlb.read/write[TLB_SIZE]`, `paging.h:160`) maps linear pages
directly to host RAM for the fast path; misses fall through to `PageHandler`s. Page
faults are raised via the exception mechanism.

**Exceptions/interrupts** (`cpu.h:168`–189): unified `CPU_Interrupt(num, type, oldeip)`
with type flags `CPU_INT_SOFTWARE / EXCEPTION / HAS_ERROR / NOIOPLCHECK`. Helpers
`CPU_HW_Interrupt` (hardware IRQ), `CPU_SW_Interrupt` (INT n), `CPU_Exception`. The PIC
calls `CPU_HW_Interrupt(vector_base + irq)` (`pic.cpp:377,383`). In real mode this just
pushes flags/CS/IP and vectors through the IVT; in protected mode it walks the IDT
gate/TSS logic.

**Cycle accounting.** Each instruction implicitly costs 1 cycle (the
`CPU_Cycles-->0` loop counter); some operations and I/O add extra delay
(`modify_cycles`, `CPU_IODelayRemoved`) so I/O-heavy code doesn't get penalized by the
auto-cycle estimator.

---

## 5. Memory model

**Host backing store.** Guest physical RAM is one big host allocation reachable via
`HostPt MemBase` (`memory.cpp:51`); `MemoryBlock.pages` is a `std::vector<page_t>` of
4 KB pages plus parallel vectors `phandlers` (per-page `PageHandler*`) and `mhandles`
(allocation linkage for EMS/XMS) (`memory.cpp:28`). Max RAM is bounded by
`PciMemoryBase` (`memory.cpp:22`).

**Page handlers = MMIO dispatch.** Every 4 KB physical page has a `PageHandler*`
(`paging.h:46`). The base class has virtual `readb/w/d/q`, `writeb/w/d/q`, plus
`GetHostReadPt/GetHostWritePt` (return a raw host pointer when the page is plain RAM, for
the fast path). Concrete handlers:
- `RAMPageHandler` (`memory.cpp:85`) — returns the host page pointer; reads/writes are direct.
- `ROMPageHandler` (`memory.cpp:102`) — readable, writes logged & ignored.
- `IllegalPageHandler` (`memory.cpp:53`) — open-bus reads (`0xFF`), logged.
- Device handlers (VGA framebuffer, LFB, etc.) override read/write to trap MMIO. `MEM_SetPageHandler(phys_page, pages, handler)` / `MEM_SetLFB(...)` install them (`paging.h:91`).

**Two access tiers** (`memory.h`):
- `phys_read*/phys_write*` — direct `MemBase+addr` access, no paging, no handlers (fast, used internally where the target is known-RAM).
- `mem_read*/mem_write*` (templated on `MemOpMode` for breakpoints, `memory.h:111`) — go through the TLB/page-handler system; recognize paging and MMIO.
- `real_read*/real_write*` and `RealToPhysical/RealMake/PhysicalMake` (`memory.h:190`+) convert real-mode `seg:off` to linear and call the paged accessors. IVT helpers `RealGetVec/RealSetVec` live here too.

**Address-space layout** (real-mode/conventional, the classic PC map this emulator
reproduces):
- `0x00000–0x9FFFF` conventional RAM (640 KB), with the IVT at `0`, BIOS data area at `0x400`.
- `0xA0000–0xBFFFF` video memory window (handled by VGA page handlers).
- `0xC0000–0xEFFFF` option ROMs / **UMBs** (Upper Memory Blocks when `umb=on`).
- `0xF0000–0xFFFFF` system BIOS; **the callback segment `CB_SEG=0xF000`** holds the guest↔host trampolines (§7).
- **HMA** at `0x100000–0x10FFEF` (the A20 wrap region); `LINK_START` for paging begins "right after the HMA" (`paging.h:41`).
- **XMS** extended memory starts at page `XMS_START=0x110` (`paging.h:21`), managed by `xms.cpp`.
- **EMS** (`ems.cpp`) provides a 64 KB page frame (default in UMB area) with `MEM_AllocatePages`-backed banks mapped/unmapped on demand.

**Conventional/UMB/HMA/XMS/EMS layering** is therefore implemented as: a flat physical
RAM array + page-allocation API (`MEM_AllocatePages`/`MEM_ReleasePages`, handle-based,
`memory.h:57`) + remapping of page handlers (EMS frame, HMA, A20).

**A20.** `MEM_A20_Enable/Enabled` (`memory.h:48`); the gate is controlled by the
keyboard controller and the fast-A20 PS/2 port `0x92` (`port.h:141`). Disabling A20
makes addresses ≥1 MB wrap, exactly as on hardware (needed for HMA tricks).

---

## 6. DOS emulation

**It is an emulated DOS kernel, not real MS-DOS.** There is no real `IO.SYS`/`MSDOS.SYS`
loaded; INT 20/21/25/26/27/29 vectors point at C++ handlers via callbacks. The kernel is
constructed in the `DOS` class ctor (`dos.cpp:1777`):
```
callback[1].Install(DOS_21Handler, CB_INT21, "DOS Int 21");
callback[1].Set_RealVec(0x21);
DOS_SetupFiles();    DOS_SetupDevices();  DOS_SetupTables();
DOS_SetupMemory();   DOS_SetupPrograms(); DOS_SetupMisc();
```
A guest `INT 21h` runs a tiny stub in the callback segment (`sti; callback; iret; retf`,
`dos.cpp:1791`) whose `callback` opcode re-enters C++ `DOS_21Handler`.

**INT 21h dispatch** (`DOS_21Handler`, `dos.cpp:448`): on entry it saves guest registers
to the stack (for most functions), then a big `switch (reg_ah)` over the AH function
number (cases enumerated `dos.cpp:469`–onwards). API surface a reimplementer must cover:
- **Character I/O**: `01–0C` (STDIN/STDOUT/AUX/PRN, buffered input).
- **FCB file API** (legacy): `0F–17, 21–29` (open/close/find/seq+random read/write, parse).
- **Drive/dir**: `0D–0E, 19, 1B–1C, 36, 39–3B, 47, 3D`… (set/get drive, allocation info, mkdir/rmdir/chdir, get cwd, free space).
- **Handle-based file API** (the modern one): `3C–46` (create/open/close/read/write/lseek/ioctl/dup/get-set-attr/rename/delete), `4E–4F` (find first/next), `57` (get/set file date).
- **Memory**: `48/49/4A` (allocate/free/resize MCB blocks), `58` (alloc strategy/UMB link).
- **Process**: `00, 4B (EXEC), 4C (exit), 4D (return code), 31 (TSR), 26 (create PSP), 50/51/62 (get/set PSP)`.
- **Misc/system**: `25/35` (set/get IVT vector), `2A–2D` (date/time), `30` (version), `33` (ctrl-break), `34` (InDOS flag), `44` (IOCTL), `59` (extended error), `5x` networking/SHARE, `63/65/66` (DBCS/country/code page), `67` (handle count). INT 2Fh multiplex is dispatched via `DOS_AddMultiplexHandler` (e.g. `WINDOWS_Int2F_Handler`, `dos.cpp:1843`).

**Key DOS data structures** (`dos.h`, `dos_classes.cpp`):
- **PSP** (`DOS_PSP`): per-process control block at the program's base segment; holds parent PSP, JFT (job file table), saved INT 22/23/24 vectors, command tail (`CommandTail`, `dos.h:26`), environment segment.
- **MCB chain** (`DOS_MCB`, `dos_memory.cpp`): singly-linked list of memory arena headers (`'M'`/`'Z'` signatures) describing conventional + UMB allocations; `DOS_SetupMemory` builds the first MCB. The `mcb_fault_strategy` setting (`repair/report/allow/deny`, `dosbox.cpp:871`) governs how corrupted chains are handled — a nice robustness feature.
- **DTA / FCB**: Disk Transfer Area for find-first/next results; FCBs for legacy file API.
- **SDA** (Swappable Data Area), **device chain** (`DOS_SetupDevices`, devices like `CON`, `NUL` in `dos_devices.cpp` / `dev_con.h`).

**Filesystem = host redirection via a drive abstraction.** `DOS_Drive` is a pure-virtual
interface (`dos_system.h:106`):
`FileOpen/FileCreate/FileUnlink/MakeDir/RemoveDir/TestDir/FindFirst/FindNext/GetFileAttr/Rename/AllocationInfo/FileExists/GetMediaByte/IsReadOnly/IsRemote/IsRemovable/UnMount`.
Implementations (`drives.h`): `localDrive` (maps DOS 8.3 names to host files, with a
`drive_cache` for case-insensitive lookup), `fatDrive` (FAT image), `isoDrive`,
`Overlay_Drive` (copy-on-write over a base dir), `Virtual_Drive` (in-memory built-in
files like `Z:`). The global `Drives[DOS_DRIVES]` array + `DriveManager` (`drives.h:36`)
handle mounting and disk-swapping. File handles returned to the guest are indices into
the PSP's JFT pointing at `DOS_File` objects.

**Program loader** (`dos_execute.cpp`): `DOS_Execute` handles `.COM` (load flat at PSP+0x100)
and `.EXE` (`EXE_Header` MZ signature, `dos_execute.cpp:27`): reads header, allocates an
MCB block, loads the image, applies the **relocation table**, builds the PSP, sets
CS:IP/SS:SP, and either `LOADNGO` (load and run) or load-only. `DOS_Terminate`
(`dos_execute.cpp:114`) restores parent PSP, INT 22/23/24 vectors, frees process memory.

---

## 7. BIOS & interrupts — the guest↔host callback mechanism

**This is the single most important architectural idea to copy.** DOSBox doesn't run a
real BIOS or DOS image; instead it installs tiny machine-code **trampolines** in guest
memory whose only job is to bounce execution back into C++.

**The callback mechanism** (`cpu/callback.h`, `cpu/callback.cpp`):
- A reserved guest region: segment `CB_SEG = 0xF000`, offset `CB_SOFFSET = 0x1000`, each callback slot `CB_SIZE = 32` bytes (`callback.h:43`). `CALLBACK_RealPointer(n)` gives its `seg:off`.
- `Callback_Handlers[]` is a C++ array of `Bitu(*)()` function pointers (`callback.h:11`).
- `CALLBACK_Setup` writes a few bytes into the slot: a special **callback opcode** (a magic/illegal opcode the CPU cores recognize) encoding the handler number, followed by a return sequence chosen by `type` (`CB_IRET`, `CB_RETF`, `CB_IRET_STI`, `CB_INT21`, `CB_IRQ0`, etc., `callback.h:13`). The builder is `callback_setup_extra` (`callback.cpp:152`) which emits raw opcode bytes (`add_instruction_1`).
- When the CPU core executes that opcode it returns the handler index `ret` from `(*cpudecoder)()`; `normal_loop` then calls `Callback_Handlers[ret]()` (`dosbox.cpp:131`). The C++ handler reads/writes guest registers (`reg_ax`, `SegValue(ds)`, …) and memory, sets carry/zero/IF via `CALLBACK_SCF/SZF/SIF` (which patch the flags image on the guest stack, `callback.cpp:116`), then the trampoline's tail `IRET`/`RETF` resumes the guest.

**The reverse direction** — C++ asking the guest to run an interrupt:
`CALLBACK_RunRealInt(intnum)` (`callback.cpp:106`) saves CS:IP, points them at an INT
trampoline, calls `DOSBOX_RunMachine()` (re-entrant!), then restores. This is how the C++
`COMMAND.COM` issues `INT 21h`/`INT 10h`/`INT 16h` (`shell_cmds.cpp:111` etc.) — it
literally drives its own emulated CPU. `CALLBACK_Idle()` (`callback.cpp:55`) similarly
spins the CPU to let IRQs fire while a C++ handler "waits". This re-entrancy (C++ →
RunMachine → callback opcode → C++) is the backbone of the whole design.

**BIOS setup** (`ints/bios.cpp`, the `BIOS` class ctor ~`bios.cpp:1244`):
- Installs IVT entries 08h–1Ah, 70h via callbacks: `INT11` equipment, `INT12` memory size, `INT14` serial, `INT15` system services, `INT17` printer, `INT1A` time, `INT1C` user timer tick, `INT70` RTC, `INT08` IRQ0 timer.
- Writes the BIOS Data Area (machine signature at a fixed address, equipment word, etc., `bios.cpp` `phys_writeb(0xffff*, ...)`), the reset far-jump at `0xFFFF0`, and default IRQ handlers (`call_irq_default`) for IRQ 3/4/5/7/10/11.
- Sub-modules: `INT 13h` disk (`bios_disk.cpp`), `INT 09h/16h` keyboard (`bios_keyboard.cpp`), `INT 10h` video BIOS + VESA (`ints/int10*.cpp`, dispatched by AH in `int10.cpp`), `INT 67h` EMS (`ems.cpp`), XMS driver entry (`xms.cpp`).

So the IVT is real guest memory; vectors point either at callback trampolines (for
emulated services) or at real guest handlers (which TSRs/games can hook normally —
hooking works because it's a genuine IVT).

---

## 8. Device / hardware model

**Registration is decentralized and RAII-based.** There is no device bus object; each
device is a module with `*_AddConfigSection` + `*_Init`/`*_Destroy`, typically wrapping
its state in a `std::unique_ptr` and holding `IO_*HandleObject` members that auto-unhook
on destruction.

**I/O port dispatch** (`hardware/port.h`, `port.cpp`):
- Ports are 16-bit (`io_port_t`). Handlers are `std::function`s:
  `io_read_f = io_val_t(io_port_t, io_width_t)`, width = byte/word/dword (`port.h:40`).
- `IO_RegisterReadHandler(port, handler, max_width, range)` / `...WriteHandler` install over a port range. RAII wrappers `IO_ReadHandleObject`/`IO_WriteHandleObject` (`port.h:71`) are what devices actually hold; their dtor frees the handler. The CPU's `IN`/`OUT` instructions funnel through `IO_ReadB/W/D` / `IO_WriteB/W/D`, which look up the per-port handler tables and split/combine wider accesses as needed.
- Example: the 8259 PIC installs read/write handlers on `0x20/0x21/0xA0/0xA1` (`pic.cpp:672`).

**IRQ hooking.** Devices call `PIC_ActivateIRQ(irq)` / `PIC_DeActivateIRQ(irq)` and
`PIC_SetIRQMask` (`pic.cpp:323,349,414`). The two cascaded 8259s (`PIC_Controller pics[2]`,
`pic.cpp:122`) maintain IRR/ISR/IMR and EOI logic; the secondary cascades into primary
IRQ2. Devices may schedule the IRQ via the PIC event queue for correct timing.

**DMA hooking.** `DmaChannel` (`hardware/dma.h:33`) models an 8237 channel; a device
calls `DMA_GetChannel(n)` and `channel->RegisterCallback(cb)`, then transfers move data
with `Read(words, dest)` / `Write(words, src)` (`dma.h:60–66`). Sound Blaster etc. use
this for digitized audio.

**Tick hooking.** Devices needing once-per-ms work call `TIMER_AddTickHandler(handler)`
(`pic.cpp:600`); one-shot/future work uses `PIC_AddEvent`.

**Major devices** (`hardware/`):
- **PIT (8254)** `timer.cpp` — 3 counters; counter 0 drives IRQ0, counter 2 the PC speaker; reload values scheduled as PIC events.
- **VGA/SVGA** `hardware/video/vga*.cpp` — the biggest device: CRTC/sequencer/graphics/attribute registers, multiple draw modes, per-scanline rendering scheduled via PIC, framebuffer exposed to the renderer through `RENDER_DrawLine` callbacks. SVGA flavors (S3/ET3000/ET4000/Paradise) + VESA. Voodoo and ReelMagic are separate video subdevices.
- **Keyboard/mouse** `hardware/input/` — 8042 controller on `0x60/0x64`, mouse via PS/2 + INT 33h, A20 gate control.
- **Audio** `hardware/audio/` — Sound Blaster (DSP + DMA + IRQ + OPL), Gravis UltraSound, OPL2/3 FM, PC speaker, Tandy/PCjr, Innovation SSI-2001, IMFC. Each registers a **mixer channel** (§9).
- **Serial/parallel** `hardware/serialport/`, CMOS/RTC `cmos.cpp`, PCI bus `pci_bus.cpp`, NE2000/IPX networking `hardware/network/`.

---

## 9. Host integration (SDL boundary)

The project rule is "restrict SDL to rendering, window management, OpenGL, input, and
OS-level audio/MIDI" (`.claude/rules/code-style.md`). The host boundary is `src/gui/`
and `src/audio/`.

**Rendering pipeline** (`src/gui/render/`, `render.h`):
- Emulated video device produces scanlines: VGA calls the `ScalerLineHandler RENDER_DrawLine` (`render.h:239`) for each line into an intermediate buffer. `RENDER_StartUpdate()`/`RENDER_EndUpdate()` (`render.h:264`) bracket a frame; `RENDER_SetSize` configures dimensions + fps; `RENDER_SetPalette` for indexed modes.
- A **scaler layer** (`render/scaler/`) handles pixel/scan doubling and aspect correction (`AspectRatioCorrectionMode`, `IntegerScalingMode`, `ViewportMode`, `render.h:22–55`).
- Two backends behind `render_backend.h`: `opengl_renderer.cpp` (with a real **shader pipeline** — `shader.cpp`, `shader_manager.cpp`, `shader_pipeline.cpp`, `shader_pragma_parser.cpp`, plus auto-shader switching and CRT color profiles) and `sdl_renderer.cpp` (software/SDL fallback). The shader system is a notable Staging modernization over classic DOSBox's fixed scalers.
- **Presentation timing** (`sdl_gui.cpp:239`+): `PresentationMode::{DosRate, HostRate, VsyncDriven}`. `GFX_GetPresentationMode()` + `GFX_MaybePresentFrame()` decouple "when a DOS frame is finished" from "when the host monitor refreshes", enabling proper vsync without tearing while keeping the emulator single-main-threaded.

**Input** (`gui/mapper.cpp`): `MAPPER_AddHandler`/`MAPPER_BindKeys` map host SDL
scancodes/joystick events to emulated keyboard/joystick and to emulator hotkeys (e.g.
F12 speedlock, `dosbox.cpp:683`). A graphical mapper UI is available.

**Audio mixer** (`src/audio/mixer.cpp`, `mixer.h`) — the clearest threading boundary:
- Each sound device registers a channel via `MIXER_AddChannel(handler, ...)` (`mixer.cpp:717`); `MIXER_Handler = std::function<void(int frames)>` (`mixer.h:35`). Devices push samples (with resampling, per-channel filters, crossfeed, reverb/chorus sends, envelope, noise gate — see `ChannelFeature`, `mixer.h:98`).
- A **dedicated mixer thread** (`mixer.thread`, `mixer.cpp:160`, named `dosbox:mixer`, started `mixer.cpp:2950`) plus the SDL audio callback (`mixer_callback`, `mixer.cpp:2576`; device opened via `SDL_OpenAudioDevice`, `mixer.cpp:2790`). The mixer thread mixes channels into a ring buffer; the SDL callback drains it. Some channels that run on the main thread use lock-free queues to hand audio across the boundary (`mixer.cpp:272` comment). Capture taps the mix on a PIC tick handler (`capture_callback`, `mixer.cpp:2539`).

**Window/quit** (`sdl_gui.cpp`): `GFX_InitSdl`, `GFX_InitAndStartGui`, `GFX_PollAndHandleEvents` (called once per emulated ms from the loop), `GFX_RequestExit`, `GFX_Quit`/`GFX_Destroy`.

---

## 10. Cross-cutting strategies

**Threading model.** Emulation core is **single-threaded** on the main thread (CPU,
PIC, all devices, video). Threads are used only at well-defined leaf subsystems:
audio mixer (`audio/mixer.cpp`), CD-ROM I/O (`dos/cdrom.cpp`), image/screenshot saver
(`capture/image/image_saver.cpp`), some MIDI backends (`midi/soundcanvas.cpp`,
`midi/mt32.cpp`, FluidSynth), and network servers (`hardware/network/ipxserver.cpp`).
Cross-thread data uses atomics (`std::atomic<bool> is_shutdown_requested`,
`dosbox.cpp:420`; `atomic_pic_index`, `pic.cpp:127`) and lock-free queues
(`utils/rwqueue`). **Lesson: keep the deterministic emulation timeline on one thread;
push only real-time host I/O (audio) onto threads.**

**Save/load state.** **Removed.** Grepping the whole `src/` finds no general
`SaveState`/serialize framework across modules (only incidental matches in vendored libs
and one driver). Classic DOSBox's `POD_Save`-style save-state is **not present in
Staging** — a deliberate simplification. A from-scratch emulator can defer this, but if
desired it's far easier to design in from day one than to retrofit.

**Configuration** is the strongest modern subsystem: typed `Property` objects, per-setting
`Changeable` policy, per-section update handlers for live re-init, deprecation with
alternates, auto-generated default config + inline help/i18n (`MSG_Add`). Worth copying
wholesale.

**Performance strategies worth replicating:** lazy flag evaluation (`lazyflags.h`);
software TLB of host pointers for the memory fast path (`paging.h`); event-driven CPU
bursts bounded by the next scheduled event (no per-instruction device polling,
`pic.cpp:530`); direct host-pointer access for plain-RAM pages bypassing virtual
dispatch (`GetHostReadPt`); endian-safe but cheap host memory helpers
(`utils/mem_host.h`, `mem_unaligned.h`); optional JIT cores for heavy protected-mode
workloads.

**Modern C++ practices adopted** (per `.claude/rules/code-style.md`, visible throughout):
C++23, RAII + `unique_ptr` for every module's lifetime, `std::function` for handler
registration (I/O ports, mixer, DMA, sections), `enum class` (`MachineType`, `SvgaType`,
`io_width_t`, `MixerState`), `std::optional`, `constexpr`/`static_assert`,
`std::filesystem`, no iostreams, no C string functions, `CHECK_NARROWING()` in new files.
The hot interpreter loop and PIC queue intentionally remain old-style C for speed.

---

## 11. Lessons for a from-scratch emulator

**What Staging gets right (copy these):**
- **Emulated DOS kernel + callback trampolines.** Don't boot real DOS. Reserve a guest segment, write trampoline opcodes whose execution returns a handler id to your host loop, and implement INT 21h/BIOS as host functions that read/write guest regs+memory. Make it **re-entrant** (host can call "run interrupt" which spins the CPU). This single idea (`cpu/callback.*`) is the architecture.
- **One scheduler timeline = a sorted event queue keyed in fractional ms**, with the CPU running in cycle-bursts bounded by the next event (`pic.cpp`). Far simpler and more accurate than ad-hoc per-device counters.
- **"1 ms tick" wall-clock sync** with per-ms tick handlers for coarse device work, events for fine work.
- **Page-handler memory model**: flat host RAM array + per-page handler objects + a host-pointer TLB fast path. Lets MMIO, ROM, EMS remapping, and A20 all be expressed uniformly.
- **`std::function` handler registration with RAII auto-unhook** for I/O ports, IRQs, DMA, mixer channels, and tick handlers — devices stay self-contained.
- **Drive abstraction** (`DOS_Drive` pure-virtual) so host-FS redirection, FAT images, ISO, and overlays share one interface.
- **Typed config-section object model** with change policies + live update handlers.
- **Lazy flags**, and (later) **optional JIT cores** selected by a function pointer (`cpudecoder`).
- **Threaded audio mixer** behind a clean channel API; keep everything else single-threaded.
- **Decouple DOS-frame production from host presentation** (presentation modes) for clean vsync.

**What to avoid / improve:**
- The **auto-cycles heuristic** (`increase_ticks`, `dosbox.cpp:177`) is a pile of unexplained magic constants — design a cleaner pacing model (or just expose fixed cycles / MIPS).
- Heavy **macro + `#include`d-opcode-table** decoding (`core_normal/*.h`) is fast but hard to read/maintain; a generated dispatch table or a cleaner decoder is preferable in a fresh codebase (Zig's comptime can replace the macro tables).
- **Mutable global state everywhere** (`cpu`, `paging`, `pics[]`, `memory`, `reg_*`). Works, but encapsulating the machine in a context struct improves testability and future multi-instance/save-state support.
- **No save-state** — decide up front; retrofitting is painful.
- Real-mode-centric `seg:off` helpers leak throughout; keep a clean linear-address core with thin real-mode adapters.

**Minimal component set + suggested build order:**
1. **Types + host memory helpers** (endian-safe read/write, `Bitu`-equivalent).
2. **Memory**: flat RAM + page handlers + `mem_read/write` + real↔phys helpers + A20. (No paging yet.)
3. **CPU interpreter (real mode only)**: fetch/decode/dispatch, lazy flags, `CPU_Interrupt` via IVT. Drive it with a trivial loop.
4. **Callback mechanism**: trampoline opcode + host handler table + `RunMachine`/`RunRealInt`. This unblocks everything.
5. **Scheduler**: PIC event queue + 8259 + 8254 PIT + the 1ms-tick main loop + IRQ0/IRQ1 wiring.
6. **BIOS**: IVT setup, BDA, INT 10h (text/VGA), INT 16h (keyboard), INT 1Ah, INT 12h/11h.
7. **DOS kernel**: PSP, MCB chain, DTA, handle/JFT file API, INT 21h dispatch, `DOS_Drive` + a host-directory drive, EXE/COM loader.
8. **Shell** (`COMMAND.COM`-equivalent) driving the CPU via `RunRealInt`, + autoexec/mount.
9. **Host I/O**: framebuffer→window (start with a plain blit; add scalers/shaders later), keyboard/mouse input, threaded audio mixer + PC speaker, then Sound Blaster/OPL.
10. **Protected mode + paging + a JIT core**, XMS/EMS, SVGA/VESA, and the long tail of devices — only once real-mode games run.

---

### Citation index (primary files)
- Lifecycle/loop/timing: `src/main.cpp`, `src/dosbox.cpp` (`normal_loop` :113, `increase_ticks` :177, init/destroy :1117/:1171).
- Scheduler/PIC: `src/hardware/pic.cpp` (`PIC_RunQueue` :530, event queue :183–575, `TIMER_AddTick` :607).
- CPU: `src/cpu/cpu.h`, `src/cpu/core_normal.cpp` (dispatch :133), `src/cpu/paging.h`, core selection `src/cpu/cpu.cpp:3548`.
- Memory: `src/hardware/memory.h`, `src/hardware/memory.cpp` (page handlers :53–116).
- Callbacks: `src/cpu/callback.h`, `src/cpu/callback.cpp` (`CALLBACK_RunRealInt` :106, `CALLBACK_Idle` :55).
- DOS: `src/dos/dos.cpp` (`DOS_21Handler` :448, `DOS` ctor :1777), `src/dos/dos.h`, `src/dos/dos_system.h` (`DOS_Drive` :106), `src/dos/drives.h`, `src/dos/dos_execute.cpp`.
- BIOS/ints: `src/ints/bios.cpp`, `src/ints/int10.cpp`, `src/ints/ems.cpp`, `src/ints/xms.cpp`.
- Devices/IO: `src/hardware/port.h`, `src/hardware/dma.h`, `src/hardware/timer.cpp`.
- Host: `src/gui/render/render.h`, `src/gui/sdl_gui.cpp`, `src/audio/mixer.h`, `src/audio/mixer.cpp`.
- Config: `src/config/setup.h`, `src/config/config.cpp`.
