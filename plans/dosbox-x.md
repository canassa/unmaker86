# DOSBox-X Architecture — Reverse-Engineering Notes for a From-Scratch DOS Emulator

Source studied: `references/dosbox-x/` (a heavily extended fork of DOSBox SVN, ~2761 C/C++ files).
All paths below are relative to that directory unless absolute.

This document captures the **structure, algorithms, strategy, and the DOS/BIOS API surface** that a
reimplementer must get right. It deliberately ignores per-opcode and per-register minutiae.

> A note on sourcing: DOSBox-X ships an unusually good in-tree design document,
> `README.source-code-description` (1290 lines). Many strategy-level claims here are confirmed
> both by that doc and by the code. Where I only read the doc and not the implementing code, or
> where I am inferring, I say so explicitly.

---

## 1. Source tree layout

Top-level split: `include/` (public headers, shared globals), `src/` (implementation), plus
`libs/` (vendored third-party libraries). The interesting structure is under `src/`:

| Dir / file | Responsibility |
|---|---|
| `src/dosbox.cpp` | **The machine core.** Holds the main `Normal_Loop()`, the loop dispatcher, the global tick/cycle bookkeeping, `DOSBOX_RunMachine()`, `DOSBOX_RealInit()`, and `DOSBOX_SetupConfigSections()` which declares *all* config sections/settings. 5558 lines. |
| `src/gui/sdlmain.cpp` | **Entry point (`main()`, ~line 8371)** and the host/SDL boundary: window, GFX start/end, event pump (`GFX_Events`), and — critically — the giant subsystem `*_Init()` call sequence that *assembles the whole machine* (~line 9632). 10726 lines. |
| `src/gui/render.cpp`, `render_scalers.cpp` | RENDER layer: per-scanline framebuffer → scaler → host surface. `RENDER_DrawLine` is a function pointer swapped per mode. |
| `src/gui/sdl_mapper.cpp` | Input mapper: SDL key/mouse/joystick events → named "mapper events" → menu + emulated keyboard/mouse. |
| `src/gui/midi.cpp`, `src/output/*` | MIDI output framework; output backends (surface/opengl/d3d/metal/ttf). |
| `src/cpu/` | x86 CPU emulation. `cpu.cpp` (modes, descriptors, TSS, exceptions, interrupts, config). `paging.cpp` (TLB + page handlers). Multiple **cores** (see §4): `core_normal*`, `core_simple`, `core_prefetch*`, `core_full` (Bochs-derived), `core_dyn_x86` (32-bit JIT), `core_dynrec` (portable JIT). `callback.cpp` is the guest↔host bridge. `modrm.cpp`, `flags.cpp`/`lazyflags.h`, `mmx.cpp`. |
| `src/fpu/` | x87 FPU (host-long-double or x86-native implementations selected by header). |
| `src/hardware/` | All emulated devices: `memory.cpp` (RAM, A20, page-handler registry), `iohandler.cpp` (I/O port dispatch), `pic.cpp` (8259 + the **event scheduler + tick handlers**), `timer.cpp` (8253/8254 PIT), `dma.cpp`, `keyboard.cpp`, `cmos.cpp`, `vga*.cpp` (huge VGA/SVGA/PC-98 subsystem split by chip block), `mixer.cpp` (audio mixer), sound cards (`sblaster.cpp`, `adlib.cpp`/`opl.cpp`/`nukedopl.cpp`, `gus.cpp`, `mpu401.cpp`, `gameblaster.cpp`, `disney.cpp`), `floppy.cpp`, `ide.cpp`, `serialport/`, `parport/`, `joystick.cpp`, `voodoo*`, `pci_bus.cpp`. |
| `src/ints/` | BIOS + interrupt service routines implemented as host code: `bios.cpp` (ROM BIOS, POST, INT 1Ah/15h/etc., 13199 lines), `bios_disk.cpp` (INT 13h), `bios_keyboard.cpp` (INT 16h/INT 9), `int10*.cpp` (INT 10h video + VESA), `mouse.cpp` (INT 33h/INT 15h mouse), `xms.cpp`, `ems.cpp`. |
| `src/dos/` | **The emulated DOS kernel.** `dos.cpp` (INT 21h dispatch, 6020 lines), `dos_execute.cpp` (EXE/COM loader, PSP), `dos_files.cpp`/`dos_ioctl.cpp` (handle/FCB file API), `dos_memory.cpp` (MCB chain), `dos_classes.cpp` (`DOS_PSP`, `DOS_MCB`, `DOS_DTA` memory-struct wrappers), `dos_devices.cpp` (CON/NUL/etc. character devices), `drives.cpp` + `drive_local.cpp`/`drive_fat.cpp`/`drive_iso.cpp`/`drive_overlay.cpp`/`drive_virtual.cpp` (the `DOS_Drive` host-redirection backends), `dos_mscdex.cpp` (CD-ROM redirector), `cdrom*.cpp`. |
| `src/shell/` | The built-in `COMMAND.COM`: `shell.cpp` (init, CONFIG.SYS/AUTOEXEC.BAT), `shell_cmds.cpp` (internal commands DIR/CD/COPY/…), `shell_batch.cpp`, `shell_misc.cpp`. |
| `src/builtin/` | Built-in utilities (MEM.COM, XCOPY, EDIT, DEBUG, DOS4GW, CWSDPMI, …) stored as `unsigned char[]` blobs and surfaced on the virtual `Z:` drive. |
| `src/misc/` | Cross-cutting: `setup.cpp` (config/section/property engine), `programs.cpp` (host-code `.COM` "programs" framework), `savestates.cpp` (zip-based save/load), `support.cpp`, `cross.cpp`, `messages.cpp` (i18n), `regionalloctracking.cpp` (low-memory/BIOS region allocator). |
| `src/debug/` | Built-in debugger + disassembler. |
| `src/aviwriter/`, `src/gamelink/` | Video capture (OpenDML AVI); GameLink shared-memory video/IPC. |
| `src/libs/` | Vendored libs: `physfs`, `mt32`, `fluidsynth`, `decoders` (audio), `zmbv` (capture codec), `xBRZ`/scalers, `gui_tk`, `tinyfiledialogs`. |

Newcomer navigation rule of thumb: **`dosbox.cpp` = the motherboard/clock, `cpu/` = the CPU,
`hardware/` = chips on the bus, `ints/` = the ROM BIOS, `dos/` = the OS, `shell/` = the command
interpreter, `gui/`+`output/` = the host window.**

---

## 2. Top-level lifecycle — how the machine is assembled

### Entry point
`main(int argc, char* argv[])` in `src/gui/sdlmain.cpp:8371`. On Windows it is SDL's `SDLmain`
called from `WinMain`; on Linux/macOS it is the real `main` (confirmed by
`README.source-code-description:296-308`).

### Config/section system (the spine of init)
A single global pointer `control` (a `Config*`, `include/control.h`) owns the parsed configuration.
The config model (`include/setup.h`, `src/misc/setup.cpp`):

- A `Config` holds an ordered list of `Section`s.
- Two section kinds: `Section_prop` (named typed properties) and `Section_line` (raw text lines —
  used by the `[autoexec]` section).
- Each property is a typed `Property` subclass: `Prop_int`, `Prop_hex`, `Prop_bool`, `Prop_string`,
  `Prop_path`, `Prop_double`, `Prop_multival` (`include/setup.h:205-244`). Each property carries a
  `Changeable::Value` (when it may be changed: always / only-at-startup / etc.) and a default.
- **All** sections and settings are declared in one place: `DOSBOX_SetupConfigSections()`
  (`src/dosbox.cpp:1409`), a long procedural builder. The long arrays of allowed enum values near
  the top (e.g. `cputype_values`, `sbtypes`, `oplmodes`, `src/dosbox.cpp:1430-1468`) are the
  authoritative list of machine options.
- Code retrieves settings ad-hoc by name: `control->GetSection("dosbox")` then
  `sec->Get_bool("...")` (e.g. `src/gui/sdlmain.cpp:9605-9610`). The in-tree doc warns that almost
  no caller null-checks, so renaming/removing a setting crashes — settings are an implicit global ABI
  (`README.source-code-description:347-353`).

### Key design departure from upstream DOSBox
Upstream DOSBox attached an `init`+`destroy` function **to each section**, so init order was driven by
section order. **DOSBox-X removed that.** Instead, init happens through an **explicit ordered list of
`*_Init()` calls in `main()`**, plus two extension mechanisms (`README.source-code-description:336-345`):

1. `AddExitFunction(func, name, canchange)` — registers teardown callbacks run in **reverse**
   (FILO) order at exit (`include/setup.h:278-290`).
2. **VM event callbacks** — an enum `vm_event` (`include/setup.h:293-316`) with phases like
   `VM_EVENT_POWERON`, `VM_EVENT_RESET`, `VM_EVENT_BIOS_INIT`, `VM_EVENT_BIOS_BOOT`,
   `VM_EVENT_DOS_BOOT`, `VM_EVENT_DOS_INIT_KERNEL_READY`,
   `VM_EVENT_DOS_INIT_CONFIG_SYS_DONE`, `VM_EVENT_DOS_INIT_SHELL_READY`,
   `VM_EVENT_DOS_INIT_AT_PROMPT`, `VM_EVENT_DOS_EXIT_*`. Subsystems subscribe to these to do
   work at the right boot phase. This is the cleaner "lifecycle bus" you want to copy.
- Section change is still handled: each `Section` has `std::list<SectionFunction> onpropchange`
  callbacks (`include/setup.h:275`) invoked when settings change at runtime.

### The assembly sequence (the canonical init order)
The literal machine bring-up is the `*_Init()` block in `src/gui/sdlmain.cpp:9632-9777`. Order matters
and the comments document the dependencies. Abbreviated:

```
MAPPER_StartUp(); DOSBOX_InitTickLoop(); DOSBOX_RealInit();
RENDER_Init(); CAPTURE_Init(); IO_Init(); HARDWARE_Init();
CPU_PreInit();
Init_AddressLimitAndGateMask();   // address mask first, so RAM init knows max RAM
Init_MemoryAccessArray();         // device-response cache for memory access
Init_A20_Gate(); Init_PS2_Port_92h();
Init_RAM(); Init_DMA(); Init_PIC(); TIMER_Init(); PCIBUS_Init();
PAGING_Init();                    // paging is deeply integrated; before higher mem init
CMOS_Init(); ROMBIOS_Init();
CALLBACK_Init();                  // AFTER ROM BIOS (it allocates inside BIOS ROM region)
Init_VGABIOS(); VOODOO_Init(); GLIDE_Init();
PROGRAMS_Init();                  // registers the .COM-program callback (Z: programs)
PCSPEAKER_Init(); TANDYSOUND_Init(); MPU401_Init(); MIXER_Init(); MIDI_Init();
CPU_Init(); FPU_Init(); VGA_Init();
ISAPNP_Cfg_Init(); FDC_Primary_Init(); KEYBOARD_Init();
SBLASTER_Init(); JOYSTICK_Init(); PS1SOUND_Init(); DISNEY_Init(); GUS_Init();
IDE_Init(); IMFC_Init(); INNOVA_Init();
BIOS_Init(); INT10_Init(); SERIAL_Init(); DONGLE_Init(); PARALLEL_Init(); NE2K_Init();
// ---- "OS init now" ----
DOS_Init(); DRIVES_Init(); DOS_KeyboardLayout_Init();
MOUSE_Init();                     // inits INT 15h + INT 33h; needs DOS_GetMemory => after DOS_Init
XMS_Init(); EMS_Init(); AUTOEXEC_Init();
IPX_Init(); MSCDEX_Init(); CDROM_Image_Init();
Init_MemHandles(); MAPPER_Init(); AllocCallback2(); MSG_Init();
```

The dependency chain a reimplementer must respect: **address-mask → RAM → DMA/PIC/timer →
paging → CMOS → ROM BIOS → callbacks → devices → BIOS interrupt handlers → DOS kernel →
DOS-resident drivers (mouse/XMS/EMS) → shell/autoexec.**

### Shutdown
`exitfunctions` list run FILO (`include/setup.h:278-285`); subsystems that registered exit handlers
at init clean up in reverse. Save/load of state is independent (§10).

---

## 3. The main emulation loop & timing model (the most important section)

### Time unit: the 1 ms "tick"
DOSBox-X quantizes wall-clock and emulated time into **1 ms ticks**, anchored to `SDL_GetTicks()`
(`README.source-code-description:578-633`). Within each tick, the CPU executes a user-chosen number
of **cycles** (≈ instructions). `cycles=3000` ⇒ 3000 cycles per ms. Memory-access delays and I/O
delays can consume extra cycles to slow the guest.

### The loop dispatcher
`DOSBOX_RunMachine()` (`src/dosbox.cpp:738`) just spins `do { ret=(*loop)(); } while(!ret);` where
`loop` is a swappable `LoopHandler*` (default `Normal_Loop`, `src/dosbox.cpp:318,728`). The indirection
lets the debugger or boot code substitute a different loop. Note `DOSBOX_RunMachine()` is **reentrant**
— callbacks that fault recurse back into it (see §4 and §7).

### `Normal_Loop()` (`src/dosbox.cpp:432`)
The per-call structure:

```
loop {
  if (PIC_RunQueue()) {              // budget remains in this tick?
      CPU_Check_NMI();
      ret = (*cpudecoder)();         // run the CPU core until cycles exhausted or a callback hit
      if (ret < 0) return 1;         // core requested loop exit
      if (ret > 0) {                 // ret = callback index (guest hit 0xFE 0x38 instr)
          blah = (*CallBack_Handlers[ret])();   // run host C++ handler (INT 21h etc.)
          if (blah > 0) return blah;
      }
  } else {                           // tick budget exhausted
      GFX_Events();                  // pump host window/input events
      if (!paused && ticksRemain > 0) { TIMER_AddTick(); ticksRemain--; }
      else { increaseticks(); return 0; }  // advance wall clock / sleep / autocycle
  }
}
```

So **one `Normal_Loop` call processes as many CPU bursts as fit in the available tick budget**, then
either advances an emulated 1 ms tick (`TIMER_AddTick`) or returns to do timekeeping/sleep.

### The scheduler: PIC event queue + cycle budgeting (`src/hardware/pic.cpp`)
This is the crux. The PIC module is simultaneously the **8259 interrupt controller** and the
**discrete-event scheduler**:

- `CPU_Cycles` = cycles allowed in the *current burst*; `CPU_CycleLeft` = cycles left in the *current
  tick*; `CPU_CycleMax` = cycles per tick (the "speed").
- Events are scheduled with `PIC_AddEvent(handler, delay_ms, value)` (`src/hardware/pic.cpp:664`),
  storing the event in a sorted singly-linked queue keyed by fractional tick `index`. One-shot;
  periodic devices re-arm themselves inside their handler (`README.source-code-description:599-615`).
- `PIC_RunQueue()` (`src/hardware/pic.cpp:732`) is called before every CPU burst. It:
  1. rolls finished-burst cycles back into `CPU_CycleLeft`,
  2. fires `PIC_runIRQs()` if an IRQ is pending,
  3. drains all queue entries whose scheduled time ≤ current tick position
     (`pic_queue.next_entry->index*CPU_CycleMax <= index_nd`),
  4. **sizes the next CPU burst so it stops exactly when the next event is due**:
     `CPU_Cycles = min(cycles_until_next_event, CPU_CycleLeft)` (`src/hardware/pic.cpp:781-790`).
  5. returns `false` when the tick's cycle budget is exhausted → loop advances the tick.
- Per-tick handlers (audio render, etc.) register with `TIMER_AddTickHandler()`
  (`src/hardware/pic.cpp:841`) and are run by `TIMER_AddTick()` at tick completion.

**Net scheduling strategy:** run the CPU in variable-length bursts; an event scheduled "soon" simply
*shortens the next burst* so the device callback fires on time. There is no separate device thread —
device timing is cooperative, driven entirely by cutting CPU bursts short. Query helpers
`PIC_TickIndex()` (0.0–1.0 within tick), `PIC_TickIndexND()` (in cycles), and `PIC_FullIndex()`
(absolute emulated ms) let any code read precise emulated time (`include/pic.h`).

### Wall-clock pacing & auto-cycles (`increaseticks()`, `src/dosbox.cpp:566`)
When the budget is spent, `increaseticks()` compares emulated ticks done against real ms elapsed and
either **sleeps** (`wrap_delay`) when ahead, or grants more `ticksRemain` when behind. If
`cycles=auto/max` (`CPU_CycleAutoAdjust`), it runs a feedback controller targeting ~90% host CPU usage,
recomputing `CPU_CycleMax` every ~250 ms with damping, anti-lock clamps, and randomized sleep
patterns to avoid pathological 1 ms-sleep resonance (`src/dosbox.cpp:585-717`). Fast-forward
("turbo") sets `ticksLocked` and skips pacing.

### Frame & audio cadence
- **Audio** is rendered exactly 1 ms per emulated ms, tied to emulation time (not the SDL audio clock),
  using integer fractional math so capture A/V never drifts
  (`README.source-code-description:764-799`, `src/hardware/mixer.cpp`). Devices push audio via
  `MIXER_AddChannel` callbacks; significant state changes call `FillUp()` first to render up to that
  instant, *then* apply the change.
- **Video** is driven by PIC events, not the loop: `VGA_DrawSingleLine` is scheduled at the horizontal
  rate to rasterize one scanline at a time; `VGA_VerticalTimer`/`VGA_VertInterrupt` handle vsync and
  the EGA/PC-98 vertical-retrace IRQ (`README.source-code-description:1037-1069`). If those events
  ever stop being re-armed, the screen freezes. This per-scanline approach is what makes raster/copper
  palette effects render correctly.

---

## 4. CPU emulation strategy

### Multiple interchangeable cores selected by `core=` (`src/cpu/cpu.cpp`)
A function pointer `cpudecoder` (the same one `Normal_Loop` calls) points at the active core's `*_Run`
function. Cores present:

- **normal** — the reference interpreter. Variants for 386 (`core_normal.cpp`), 286
  (`core_normal_286.cpp`), 8086 (`core_normal_8086.cpp`).
- **simple** (`core_simple.cpp`) — faster interpreter; **cannot run with paging enabled** or when
  executing outside normal system RAM (`README.source-code-description:165-167`).
- **prefetch** (`core_prefetch*.cpp`) — models the prefetch queue; needed for self-modifying code,
  anti-debug, and copy protection.
- **full** (`core_full.cpp`) — Bochs-derived, most accurate/slowest.
- **dynamic / dyn_x86** (`core_dyn_x86.cpp`) — a **JIT for 32-bit x86 hosts** that translates guest
  blocks to host code; fastest but weaker on paging and inaccurate on cycle counts
  (`README.source-code-description:183-187`).
- **dynrec** (`core_dynrec.cpp`, `core_dynrec/risc_*.h`) — portable recompiler with per-architecture
  back-ends (x86, x64, ARMv4/v7/v8, MIPS).

Selection logic lives in `src/cpu/cpu.cpp` (~line 428): it maps the `core=` string and host build flags
to a `cpudecoder`. There's a parallel `cputype=` axis (`CPU_ArchitectureType`: 8086…Pentium III) that
gates instruction availability and selects the matching normal/prefetch core
(`src/cpu/cpu.cpp:282-372`). The debugger and trap-flag single-stepping swap in wrapper decoders (e.g.
`CPU_Core_Normal_Trap_Run`, `src/cpu/core_normal.cpp:225`).

### Interpreter dispatch architecture (the shape to copy)
`CPU_Core_Normal_Run()` (`src/cpu/core_normal.cpp:160`):

```
while (CPU_Cycles-- > 0) {
    LOADIP;                               // cseip = SegBase(cs) + reg_eip
    core.opcode_index = cpu.code.big * 0x200;   // 16/32-bit operand-size base
    core.prefixes = cpu.code.big;
    core.ea_table = &EATable[cpu.code.big*256];  // ModRM effective-address handlers
restart_opcode:
    switch (core.opcode_index + Fetchb()) {
        #include "core_normal/prefix_none.h"     // case labels for one-byte opcodes
        #include "core_normal/prefix_0f.h"       // 0x0F two-byte
        #include "core_normal/prefix_66.h"       // operand-size-override variants
        #include "core_normal/prefix_66_0f.h"
        default: illegal_opcode: CPU_Exception(6,0); continue;   // #UD
    }
    SAVEIP;
}
```

Structural points worth replicating:

- **One giant computed `switch`** whose case bodies are pulled in from header files. The opcode space
  is namespaced by adding constant offsets: `OPCODE_NONE=0x000`, `OPCODE_0F=0x100`, `OPCODE_SIZE=0x200`
  (`src/cpu/core_normal.cpp:68-70`). Operand-size override and `0F` prefix change the offset and
  `goto restart_opcode`, so prefixes are handled by re-dispatching with a different base — no separate
  decode pass.
- **Prefixes** (segment override, address-size, REP) update `core.prefixes`/segment bases and
  `goto restart_opcode` (`src/cpu/core_normal.cpp:78-93`).
- **Fetch** is just `mem_readb_inline(cseip)` with `cseip += n` (`src/cpu/core_normal.cpp:122-146`) —
  i.e. instruction fetch goes through the same TLB-backed memory path as data (the prefetch core adds
  a queue on top).
- **ModRM / effective address** resolved through a table of handlers selected by address size
  (`core.ea_table`, built in `modrm.cpp` / `core_normal/table_ea*.h`).
- **Flags are lazy** (`lazyflags.h`, `flags.cpp`): arithmetic stores operands + an op tag and only
  materializes EFLAGS when actually read (`FillFlags()` at loop exit / before flag-dependent ops). Big
  perf win; a reimplementer should at least design for it.
- **Cycle accounting** is coarse: the `while (CPU_Cycles-- > 0)` loop charges ~1 cycle/instruction in
  the normal core. Accurate per-instruction cycle tables are *not* a goal here; the dynamic cores
  don't even pretend.

### Modes, paging, exceptions, interrupts (`src/cpu/cpu.cpp`, `src/cpu/paging.cpp`)
- **Real / protected / V86** all handled in `cpu.cpp`: segment descriptor loading, CPL, GDT/LDT,
  TSS and hardware task switching, IOPL/I/O permission bitmap, and the protected-mode push/pop/stack
  machinery.
- **Interrupts**: `CPU_Interrupt(num, type, oldeip)` is the single entry that builds the correct stack
  frame for real-mode (IP/CS/FLAGS) vs protected-mode gates (with optional error code and privilege
  switch). NMI via `CPU_NMI_Interrupt()` (`src/cpu/cpu.cpp:594`).
- **Exceptions**: `CPU_Exception(which, error)` (`src/cpu/cpu.cpp:1139`) tracks nesting to synthesize
  double-fault / triple-fault (triple-fault optionally resets the machine), then calls `CPU_Interrupt`
  with the exception vector. `CPU_PrepareException` is the lower-level builder.
- **Paging** (`src/cpu/paging.cpp`, `include/paging.h`): a software TLB (see §5). On a guest page
  fault the core **throws a C++ exception** `GuestPageFaultException`; `Normal_Loop` catches it
  (`src/dosbox.cpp:526`), clears the TLB, sets `cr2`, and calls `CPU_Exception(EXCEPTION_PF,…)`.
  `GuestGenFaultException` similarly maps to #GP. Using C++ exceptions to unwind a partially-executed
  faulting instruction is a deliberate (if heavy) strategy — see §11 for the caveat.

---

## 5. Memory model

### Physical layout
A single host allocation `MemBase` (`src/hardware/memory.cpp:261`) backs guest RAM as a flat
byte array; guest physical address `p` maps to `MemBase + p` for normal RAM (with A20/alias masking,
`src/hardware/memory.cpp:312-322`). The classic PC map applies: conventional 0–640 KB, video/ROM
640 KB–1 MB (UMB region, VGA at A000/B000/B800, ROM BIOS at F000), extended memory above 1 MB, the
S3 linear framebuffer parked high (≈0xE0000000), and ACPI region (`ACPIPageHandler`,
`src/hardware/memory.cpp:108`).

### Page-handler dispatch (the routing mechanism)
Memory is divided into 4 KB pages. Every access is routed by a **software TLB** plus a **`PageHandler`
class hierarchy**:

- `class PageHandler` (`include/paging.h:83`) is the device interface: virtual `readb/readw/readd`,
  `writeb/writew/writed`, `GetHostReadPt(phys_page)` / `GetHostWritePt`, `readb_checked`/`writeb_checked`
  (for non-faulting probes), and a `flags` field (`PFLAG_READABLE`, `PFLAG_WRITEABLE`, `PFLAG_HASROM`,
  `PFLAG_HASCODE16/32`, `PFLAG_NOCODE`, `PFLAG_INIT`, `include/paging.h:64-71`). The base class
  decomposes word/dword access into byte access so a handler can implement only `readb`/`writeb`; perf-
  or semantics-sensitive handlers override the wider widths.
- Concrete handlers: `RAMPageHandler`, `ROMPageHandler`, `ROMAliasPageHandler`, `UnmappedPageHandler`,
  `IllegalPageHandler` (`src/hardware/memory.cpp:264-368`), plus device handlers (VGA memory,
  S3 LFB+MMIO, etc.).
- **The TLB** (`include/paging.h:354-417`): `paging.tlb.read[]` / `write[]` are `HostPt` arrays indexed
  by linear page (`addr >> 12`). A non-null entry is a host base pointer for the **fast path**; a null
  entry means "slow path — use the handler" via parallel `readhandler[]`/`writehandler[]` arrays.
- The hot read/write inlines (`include/paging.h:441-470`):

```c
static INLINE uint8_t mem_readb_inline(LinearPt address) {
    HostPt tlb_addr = get_tlb_read(address);          // paging.tlb.read[address>>12]
    if (tlb_addr) return host_readb(tlb_addr + address);          // fast: direct host load
    else return get_tlb_readhandler(address)->readb(address);     // slow: virtual dispatch
}
```

So a normal RAM access is a single array lookup + pointer load; MMIO/VGA/unmapped pages fall through
to a virtual call. `PAGING_LinkPage` (`include/paging.h:198`) installs TLB entries when the guest maps
a page; on guest page-table changes the core clears the TLB. `MEM_SetPageHandler` /
`MEM_GetPageHandler` register handlers for physical ranges (`src/hardware/memory.cpp`). DOSBox-X also
adds a "memory callout" system so high regions (the S3 LFB) attach their handler lazily on first access
(`README.source-code-description:1136-1147`).

### The conventional/UMB/HMA/XMS/EMS/A20 layering
- **Conventional + UMB + MCB chain**: managed by the DOS kernel via the MCB linked list (§6), not by
  the hardware layer.
- **HMA / A20**: A20 gate emulated in `src/hardware/memory.cpp` (`MEM_A20_Enable`, address aliasing
  through `mem_alias_pagemask_active`); HMA is the 64 KB just above 1 MB exposed when A20 is on.
- **XMS** (`src/ints/xms.cpp`) — extended-memory manager (INT 2Fh/driver entry), hands out handles to
  extended memory and the UMB/HMA services.
- **EMS** (`src/ints/ems.cpp`) — expanded memory (INT 67h), implements the page-frame
  bank-switching by remapping pages through the page-handler system.
- `Init_MemHandles()` builds a per-page handle table used by XMS/EMS to associate guest handles with
  pages (`src/gui/sdlmain.cpp:9768-9773`).

---

## 6. DOS emulation — an emulated kernel, not real MS-DOS

**DOSBox-X emulates the DOS kernel in host C++; it does not boot a real MS-DOS by default** (it *can*
boot a real DOS from a disk image via the `BOOT` command, which tears down the emulated kernel — see
the `VM_EVENT_DOS_EXIT_*` events). The built-in kernel lives in `src/dos/`.

### How INT 21h is dispatched (the API surface)
- During `DOS_Init()` (`src/dos/dos.cpp:5144`, body around 4584) the kernel installs **callbacks** into
  the interrupt vector table: `callback[1].Install(DOS_21Handler, CB_INT21, "DOS Int 21");
  callback[1].Set_RealVec(0x21);` (`src/dos/dos.cpp:4587-4588`). Same for INT 20h, 25h/26h (absolute
  disk), 27h (TSR), 28h (idle), 29h (fast console out), 2Fh (multiplex), 30/31h (CP/M).
- The vector points at a tiny stub in the BIOS ROM region containing the magic callback instruction
  `0xFE 0x38 <id>`; when the CPU core executes it, the core returns the callback id to `Normal_Loop`,
  which calls `DOS21_Handler()` (the host C++ function) — see §7 for the bridge.
- `DOS21_Handler` (`src/dos/dos.cpp`, big `switch (reg_ah)` starting ~line 1088) is the **DOS API
  surface**, one case per function: 0x00 terminate, 0x01–0x0C console I/O, 0x0D–0x24 FCB file ops &
  drive/DTA, 0x25/0x35 set/get vector, 0x26 create PSP, 0x2A–0x2D date/time, 0x30 version, 0x31 TSR,
  0x3C–0x3E create/open/close (handles), 0x3F/0x40 read/write, 0x41 unlink, 0x42 lseek, 0x43 attrib,
  0x44 IOCTL, 0x47 getcwd, 0x48–0x4A allocate/free/resize memory (MCB), 0x4B EXEC, 0x4C exit,
  0x4E/0x4F find first/next, 0x56 rename, 0x57 file times, 0x5xxx network/share, 0x71xx LFN, etc.
  Handlers read/write guest registers and guest memory directly, then set the carry/zero/interrupt flags
  on return via `CALLBACK_SCF()/SZF()/SIF()` (`README.source-code-description:643-651`).

### Filesystem: redirection to the host through `DOS_Drive`
- Abstract base `class DOS_Drive` (`include/dos_system.h:299`) is a pure-virtual VFS interface:
  `FileOpen`, `FileCreate`, `FileUnlink`, `MakeDir/RemoveDir/TestDir`, `FindFirst/FindNext`,
  `GetFileAttr/SetFileAttr`, `Rename`, `AllocationInfo`, `FileStat`, `GetMediaByte`, plus absolute-
  sector `Read/Write_AbsoluteSector_INT25` for INT 25h/26h.
- Backends (`src/dos/drive_*.cpp`): `localDrive` (maps a guest drive to a host directory — the common
  case), `Overlay_Drive` (copy-on-write over a localDrive), `fatDrive` (FAT12/16/32 inside a disk
  image), `isoDrive` (ISO-9660 CD image), `Virtual_Drive` (the `Z:` drive holding built-in programs &
  files), `physfsDrive`. `Drives[DOS_DRIVES]` (`include/dos_inc.h:217`) is the A–Z drive table;
  `DriveManager` (`src/dos/drives.h:37`) handles mounting and disk-swap cycling.
- Open files are `DOS_File` objects; the per-process handle table lives in the PSP/SDA. There is also
  a directory cache (`DOS_Drive_Cache`, `drive_cache.cpp`) to make host directory enumeration behave
  like FAT (8.3 short-name generation, ordering).
- Two file-access models coexist, both required by real software: **handle-based** (0x3C–0x42, modern)
  and **FCB-based** (0x0F–0x24, CP/M legacy, `DOS_DTA` wrapper at `include/dos_inc.h:671`).
- MSCDEX (`dos_mscdex.cpp`) layers the CD-ROM redirector (INT 2Fh AH=15h) on top of `isoDrive`.

### DOS data structures as guest-memory "views"
PSP, MCB, DTA, SDA are modeled as thin C++ wrappers over guest memory (`MemStruct` subclasses in
`dos_classes.cpp`): `DOS_PSP`, `DOS_MCB`, `DOS_DTA`, `DOS_InfoBlock`. They read/write fields at fixed
offsets in the emulated RAM so guest programs see byte-accurate structures.

- **MCB chain**: `dos_memory.cpp` maintains the classic singly-linked Memory Control Block chain
  ('M'/'Z' signatures, owner PSP, size in paragraphs) for INT 21h AH=48/49/4A. `DOS_SetupMemory()`
  builds the first MCB (`src/dos/dos.cpp:4730`).
- **PSP / environment**: `dos_execute.cpp` builds the 256-byte PSP (`SetupPSP`,
  `src/dos/dos_execute.cpp:266`), copies/relocates the environment segment, sets parent PSP for the
  process tree (`DOS_NewPSP`/`DOS_ChildPSP`, lines 240/251).

### Program loader (`DOS_Execute`, `src/dos/dos_execute.cpp:296`)
- Reads the file header. If `MZ`/`ZM` signature → **EXE**: read `EXE_Header` (`struct EXE_Header`,
  line 59) for header size, min/max alloc paragraphs, relocation table, initial CS:IP/SS:SP; allocate
  memory; load the image; **apply the relocation table** (add load segment to each fixup). If not an MZ
  → **COM**: load flat at offset 0x100 in a 64 KB-ish allocation. DOSBox-X also transparently handles
  several **EXEPACK** variants (`exepack*.h`) and the internal `DOSEXEC_DEVICEDRIVER` overlay form.
- Allocates MCB+PSP+environment, sets up the PSP (handles inherited from parent), sets registers, and
  enters guest code. `flags` distinguishes load-and-run vs load-overlay vs load-only.

### Devices & shell
Character devices (CON, NUL, AUX, PRN, CLOCK$) are `DOS_Device` objects (`dos_devices.cpp`,
`dev_con.h`). The shell (`src/shell/`) is a host-implemented `COMMAND.COM`: it processes CONFIG.SYS /
AUTOEXEC.BAT, implements internal commands in `shell_cmds.cpp`, and uses `DOS_Execute` for external
programs.

---

## 7. BIOS & interrupts — the callback bridge

### ROM BIOS and the IVT
`ROMBIOS_Init()` lays out the F000-segment ROM and reset vector. `phys_writeb(0xffff0, 0xEA …)` writes
the `FARJMP` at the reset vector (`src/dosbox.cpp:8440-8443`). BIOS default handler stubs sit at fixed
F000 offsets (`BIOS_DEFAULT_IRQ0_LOCATION`, `…IRQ1…`, `…HANDLER…`, `src/dosbox.cpp:228-240`). The IVT
(0000:0000) is populated with far pointers to these stubs via `RealSetVec`.

### The guest↔host callback mechanism (`src/cpu/callback.cpp`) — the single most important trick
DOS and BIOS services are **native C++ functions invoked through an illegal instruction**:

- The instruction `0xFE 0x38 <uint16_t id>` is GRP4 with an invalid extension — illegal on real x86,
  used here as a "call host code" trap (`README.source-code-description:635-668`,
  `src/cpu/callback.cpp:38-44`).
- `CALLBACK_Allocate()` reserves a slot in `CallBack_Handlers[CB_MAX]` (`src/cpu/callback.cpp:43`);
  `obj.Install(handler_fn, type, "name")` records the handler and `CALLBACK_SetupExtra(id, type, addr)`
  **writes the actual machine-code stub** into the BIOS ROM region. The `type` selects the wrapper code
  emitted around the callback instruction: `CB_IRET`, `CB_RETF`, `CB_IRET_STI`, `CB_INT21`,
  `CB_IRQ0` (timer, sends EOI), `CB_IRQ1` (keyboard), etc. (`src/cpu/callback.cpp:297-466`). E.g.
  `CB_IRET` emits `0xFE 0x38 <id>` followed by `0xCF` (IRET).
- `Set_RealVec(intnum)` points the IVT entry at the stub. So when the guest does `INT 21h`, the CPU
  vectors to F000:stub, executes the callback instruction, the **core returns the id to `Normal_Loop`**,
  which calls `CallBack_Handlers[id]()` = `DOS21_Handler`. The handler manipulates guest regs/memory,
  the stub's trailing IRET returns to the guest.
- Handlers usually return `CBRET_NONE`. They set result flags in the *guest's stacked FLAGS* via
  `CALLBACK_SCF/SZF/SIF`.

### Concrete interrupt handlers (all host C++ behind callbacks)
- **INT 10h video** — `src/ints/int10*.cpp`: mode set (`int10_modes.cpp`), TTY/char output
  (`int10_char.cpp`), palette (`int10_pal.cpp`), put-pixel, VESA (`int10_vesa.cpp`).
- **INT 13h disk** — `src/ints/bios_disk.cpp` (+ `bios_memdisk.cpp`, `bios_vhd.cpp`, `qcow2_disk.cpp`)
  operating on `imageDisk` objects.
- **INT 16h keyboard / INT 9** — `src/ints/bios_keyboard.cpp` with a BIOS keystroke ring buffer.
- **INT 33h mouse + INT 15h** — `src/ints/mouse.cpp`.
- **INT 1Ah/15h/etc.** — `src/ints/bios.cpp` (the big BIOS file): time-of-day, equipment, extended
  memory size, PnP, APM.
- IRQ handlers go through `CB_IRQ*` stubs that also issue the PIC EOI.

### Recursion / fault subtlety (must understand before copying)
Because a callback runs host code that may touch guest memory/I/O, it can trigger a page fault or I/O
fault **inside** the handler. DOSBox-X resolves this by pushing an exception frame and **recursing into
another `DOSBOX_RunMachine` loop** that runs until the fault is resolved
(`README.source-code-description:680-708`; the `dosbox_allow_nonrecursive_page_fault` toggling around
the decoder and callback calls in `src/dosbox.cpp:473-491`). This works for DOS / Win 3.x but is
acknowledged as fragile for Win9x-style nested fault/task handling.

---

## 8. Device / hardware model

### I/O port dispatch (`src/hardware/iohandler.cpp`)
- Three flat handler tables indexed by port number, one per access width:
  `io_readhandlers[3][IO_MAX]`, `io_writehandlers[3][IO_MAX]` (byte/word/dword)
  (`src/hardware/iohandler.cpp:49`). `IO_ReadB/W/D` and `IO_WriteB/W/D` (line 493+) index the table and
  call the handler; unregistered ports go to slow-path/default/blocked stubs.
- A device claims ports with `IO_RegisterReadHandler(port, fn, mask, range)` /
  `IO_RegisterWriteHandler(...)` (`src/hardware/iohandler.cpp:306-321`), where `mask` is which widths
  (`IO_MB|IO_MW|IO_MD`) and `range` is how many consecutive ports. `IO_CalloutObject` provides a
  scanning fallback for sparse/aliased decodes. Width mismatches are auto-split (a dword write to a
  byte-only port becomes 4 byte writes, `src/hardware/iohandler.cpp:93-98`).
- DOSBox-X also charges I/O-access cycles to model bus delay (the `CPU_IODelayRemoved` accounting feeds
  the auto-cycle controller, §3).

### IRQs (`src/hardware/pic.cpp`) — the 8259 + scheduler hybrid
- Master+slave 8259 modeled with IRR/IMR/ISR registers (`master`/`slave` structs). A device raises an
  interrupt with `PIC_ActivateIRQ(irq)` (`src/hardware/pic.cpp:403`) / lowers with `PIC_DeActivateIRQ`.
- `PIC_runIRQs()` (`src/hardware/pic.cpp:541`) picks the highest-priority unmasked pending IRQ honoring
  cascade and in-service priority, then calls `CPU_Interrupt` with the mapped vector. A configurable
  IRQ delay (`PIC_IRQCheckDelayed`) models interrupt latency. `PIC_IRQCheck` is a fast "any pending?"
  flag checked each `PIC_RunQueue` (`src/hardware/pic.cpp:757-758`).

### DMA (`src/hardware/dma.cpp`)
8237 controller with channels and a callback registration API; sound cards (SB/GUS) register a DMA
channel and pull/push bytes through it during their mixer render.

### PIT / timer (`src/hardware/timer.cpp`)
8253/8254 channels; channel 0 drives IRQ0 (INT 8 → INT 1Ch) by re-arming a `PIC_AddEvent`; channel 2
drives the PC speaker. Frequencies are translated into PIC event delays.

### Devices register during the §2 init sequence
Each `*_Init()` (e.g. `KEYBOARD_Init`, `SBLASTER_Init`, `VGA_Init`) reads its config section, then
hooks: **I/O ports** (`IO_Register*Handler`), an **IRQ line** (for raising via `PIC_ActivateIRQ`), a
**DMA channel** (`dma.cpp`), and — for sound — a **mixer channel** (`MIXER_AddChannel`). Memory-mapped
devices additionally install a `PageHandler` via `MEM_SetPageHandler`. That four-way hookup (ports /
IRQ / DMA / memory) is the device contract a reimplementer must provide.

### VGA — the largest subsystem (`src/hardware/vga*.cpp`)
- One global VGA state struct mirrors the register file; an `M_*` mode enum
  (`include/vga.h`, listed in `README.source-code-description:975-996`) is **derived from register
  contents, not from the INT 10h mode number** — important for correctness with games that poke
  registers directly (e.g. Mode X, the Win95 boot-logo trick).
- Video RAM is stored as `uint32_t` per 4-byte plane group so EGA/VGA planar write modes, latches, and
  raster ops are efficient (`README.source-code-description:1189-1262`). `VGA_SetupHandlers()` picks
  the memory `PageHandler` per mode; `VGA_SetupDrawing()` picks the per-scanline render function and
  computes active area + refresh rate.
- Rendering is **per-scanline, driven by PIC events** (§3), enabling scanline-precise palette effects.
- A separate PC-98 path (GDC-based) coexists, selected by `machine=`.

---

## 9. Host integration (the SDL boundary)

- **Window/events**: `src/gui/sdlmain.cpp`. `GFX_Events()` (line 5893) pumps SDL events between CPU
  bursts (called from the `else` branch of `Normal_Loop`). Input flows SDL event → `sdl_mapper.cpp`
  (named mapper events) → emulated keyboard controller / INT 9 / mouse.
- **Video out**: emulated VGA renders one scanline into an internal buffer → `RENDER` layer
  (`src/gui/render.cpp`) optionally applies a scaler (`render_scalers.cpp`, normal2x/hq2x/xBRZ/etc.) →
  one of the `src/output/*` backends (surface, OpenGL, Direct3D9/11, Metal, TTF) blits to the host
  window. `RENDER_DrawLine` is a swappable function pointer; a scanline cache short-circuits unchanged
  lines (`src/gui/render.cpp:239-314`).
- **Audio out**: `src/hardware/mixer.cpp`. Devices register `MixerChannel`s via `MIXER_AddChannel`
  (`src/hardware/mixer.cpp:141`); each ms all channels render into a shared `mixer.work[]` int32 stereo
  buffer (upsampling from each source's native rate, with optional slew-rate/lowpass DAC modeling),
  clip to 16-bit, and push to a ring buffer that SDL's audio callback drains. Mixing is tied to
  emulated time so capture never drifts (§3).
- **MIDI**: `src/gui/midi.cpp` routes to platform synths or the bundled MT-32/FluidSynth.

The boundary is reasonably clean: emulation produces **scanline pixel buffers** and **1 ms PCM
frames**; the host layer is responsible only for presenting them and for translating input events.

---

## 10. Cross-cutting strategies

- **Threading**: essentially **single-threaded**. The CPU, all devices, and timing run cooperatively
  in the one emulation loop driven by the PIC event queue. The only concurrency is the host SDL audio
  callback draining the mixer ring buffer, and optional background capture encoding. This is a major
  simplification a reimplementer can keep.
- **Save/load state** (`src/misc/savestates.cpp`): a singleton `SaveState` with a registry —
  components call `registerComponent(name, comp)` (line 363); save/load serializes each registered
  component's POD blob into a **zip file** (minizip). It's a flat snapshot of RAM + device state; not
  versioned cleanly across builds. Adequate but not a model of elegance.
- **Configuration**: the typed section/property engine (§2) doubles as the documentation source —
  `dosbox-x.reference.full.conf` is generated from it.
- **Performance strategies worth copying**:
  - TLB fast path: array lookup + direct host pointer for the common RAM case; virtual dispatch only
    for MMIO/unmapped (§5).
  - Lazy flags (§4).
  - Burst-to-next-event scheduling instead of per-instruction device polling (§3).
  - Scanline render cache; mixer `FillUp()` to avoid per-sample work.
  - Multiple CPU cores so users trade accuracy for speed; JIT for hot workloads.
- **Performance strategies that are incidental complexity**: the auto-cycle PID-ish controller
  (`increaseticks`) is fiddly and only needed because real DOS software has no notion of "too fast."

---

## 11. Lessons for a from-scratch emulator

### What DOSBox-X gets right (copy these)
1. **Emulate the DOS/BIOS kernel in host code, do not boot real MS-DOS.** It removes a whole class of
   bugs and makes host-filesystem redirection natural. (Keep the *option* to boot a real image later.)
2. **The callback trap (`0xFE 0x38 id`) as the guest↔host bridge.** Clean, uniform, and lets every
   BIOS/DOS service be an ordinary native function. This is the central idea of the whole design.
3. **The TLB + `PageHandler` memory model.** A linear-page-indexed pointer array (fast path) with a
   virtual-dispatch handler fallback (MMIO) is simple and fast. Use it for both data *and* instruction
   fetch.
4. **PIC event queue that shortens CPU bursts to hit deadlines.** Single-threaded discrete-event
   scheduling with 1 ms ticks is easy to reason about and accurate enough. Devices schedule themselves;
   no device threads.
5. **`DOS_Drive` VFS abstraction.** One pure-virtual interface, multiple backends (host dir, FAT image,
   ISO, overlay). Map a guest drive letter to a host directory for the 90% case.
6. **Register typed config centrally; drive a lifecycle event bus** (`vm_event`) rather than coupling
   init to section order.
7. **Lazy flags + a giant computed-goto/switch interpreter** is a perfectly good starting CPU; add a
   JIT only if/when needed.
8. **Devices model is uniform**: ports + IRQ + DMA + (optional) memory handler + (optional) mixer
   channel. Define that contract once.

### Incidental complexity to avoid / defer
- **Six CPU cores.** Start with *one* well-tested interpreter (a 386-class normal core). Prefetch,
  simple, full, and two JITs are optional accuracy/speed knobs.
- **Resolving in-callback faults by recursing the whole machine loop.** Elegant for DOS, but the doc
  itself flags it as fragile for Win9x. If you don't target Win9x, you can use a simpler fault model.
- **PC-98**, Voodoo/Glide, dozens of sound cards and SVGA chipsets, IPX/NE2000, IDE/CHD, ACPI/PnP, the
  whole menu/mapper UI framework, AVI/GameLink capture — all optional. None are needed for "run DOS
  games."
- **The auto-cycle controller** — start with fixed cycles; add adaptive pacing later.
- **C++-exception-based page-fault unwinding** is heavy; a checked-access return-value style (the
  `*_checked` handler variants already exist) may be cleaner in a new codebase.

### Minimal component set and build order
A pragmatic order to build a new DOS emulator, each layer testable before the next:

1. **CPU core (real mode first)** — fetch/decode/execute interpreter with lazy flags. Test against
   known instruction traces. Add protected mode + paging later (only needed for DOS extenders/Win).
2. **Flat memory + TLB/page-handler routing** — RAM, ROM region, A20. (CPU needs memory to fetch.)
3. **The callback trap mechanism** — so host code can service interrupts.
4. **PIC event scheduler + 1 ms tick loop** (`PIC_AddEvent`, burst sizing) + **PIT (IRQ0)**.
5. **ROM BIOS + IVT + core BIOS interrupts**: INT 10h (at least teletype + a text mode), INT 16h
   (keyboard, with INT 9), INT 1Ah (time). Enough to print and read keys.
6. **DOS kernel**: INT 21h dispatch, PSP, MCB chain, the `DOS_Drive` VFS with a single host-directory
   backend, handle-based file I/O (0x3C–0x42), and `DOS_Execute` for COM then EXE (with relocation).
7. **The shell / AUTOEXEC** (or just exec a program from the command line) — now you can run real
   `.COM`/`.EXE`.
8. **Host I/O**: minimal video presentation (text mode → framebuffer → window) and keyboard input via
   one SDL-like backend; a basic per-ms audio mixer.
9. **VGA graphics modes** (CGA/EGA/VGA 13h first; planar/Mode X and SVGA later), then **Sound Blaster +
   Adlib**. These two unlock the bulk of the DOS games library.
10. Everything else (FCBs, EMS/XMS, mouse, more cards, more chipsets) as needed by target software.

The key insight: layers 1–7 give a runnable text-mode DOS; layers 8–9 give graphical games; the rest is
breadth. DOSBox-X's value as a reference is highest for the **callback bridge (§7), the memory/TLB model
(§5), the PIC scheduler (§3), the INT 21h surface (§6), and the device hookup contract (§8)** — those
are the load-bearing designs; the sprawling device/chipset catalog is breadth you add incrementally.

---

### Key file index (quick reference)
- Entry / assembly: `src/gui/sdlmain.cpp:8371` (main), `:9632` (init sequence)
- Machine loop / timing: `src/dosbox.cpp:432` (`Normal_Loop`), `:566` (`increaseticks`), `:738` (`DOSBOX_RunMachine`)
- Scheduler / IRQ: `src/hardware/pic.cpp:664` (`PIC_AddEvent`), `:732` (`PIC_RunQueue`), `:541` (`PIC_runIRQs`)
- CPU dispatch: `src/cpu/core_normal.cpp:160` (`CPU_Core_Normal_Run`); selection `src/cpu/cpu.cpp:~428`
- Exceptions/interrupts: `src/cpu/cpu.cpp:1139` (`CPU_Exception`), `:594` (NMI)
- Memory / TLB: `include/paging.h:83` (`PageHandler`), `:441` (`mem_readb_inline`); `src/hardware/memory.cpp:261` (`MemBase`)
- Callback bridge: `src/cpu/callback.cpp:297` (`CALLBACK_SetupExtra`); doc `README.source-code-description:635`
- I/O ports: `src/hardware/iohandler.cpp:306` (register), `:493` (`IO_WriteB`)
- DOS API: `src/dos/dos.cpp:~1088` (`DOS21_Handler` switch), `:4584` (callback install)
- DOS VFS: `include/dos_system.h:299` (`DOS_Drive`); backends `src/dos/drive_*.cpp`
- Program loader: `src/dos/dos_execute.cpp:296` (`DOS_Execute`), `:59` (`EXE_Header`)
- Config engine: `include/setup.h`, `src/misc/setup.cpp`, `src/dosbox.cpp:1409` (section declarations)
- Lifecycle events: `include/setup.h:293` (`vm_event`)
- In-tree design doc (read it): `README.source-code-description`
