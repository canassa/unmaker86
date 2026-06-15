/* VGAPAL — the VGA DAC palette / FADE I/O-oracle program (io-oracle.md Band V2).
 *
 * Where VGAINIT/VGABIOS stood up mode-13h VRAM + the basic DAC set/get paths,
 * VGAPAL stresses the DAC palette state machine the way Betrayal at Krondor's
 * fade-in/fade-out code does: it rewrites the ENTIRE 256-entry palette many times
 * with RGB values scaled toward 0 (a fade-to-black), mixing the INT 10h block path
 * (AH=10 AL=12) with raw OUT 0x3C8/0x3C9 port writes and a single-entry AL=10, and
 * it probes the 6-bit DAC boundary (writing a component > 63 to confirm the DAC
 * stores only the low 6 bits). Finally it reads the WHOLE palette back BOTH ways —
 * INT 10h AH=10 AL=17 (get block) and the raw 0x3C7/0x3C9 ports — and writes a
 * self-describing blob. dosbox-x is the golden; zdos reproduces it byte-identically.
 *
 * Why this is the right oracle for the fade band (io-oracle.md §1.5, §6 V2): the
 * FINAL palette after the fade sequence is a deterministic, guest-observable
 * artifact (a pure function of the values this program wrote — no host time, no
 * retrace bits). Capturing it through TWO independent read paths asserts that the
 * BIOS get-block path and the raw-port read path agree on the device's stored
 * 6-bit values, and the index-latch bytes assert the auto-advance bookkeeping.
 *
 * dosbox-x ground truth:
 *   - 6-bit masking on write: vga_dac.cpp:316-317 (`if (!vga_8bit_dac) val&=0x3f;`).
 *     vgaonly defaults to a 6-bit DAC, so any component > 63 is stored as val&0x3F.
 *   - write/read index auto-advance after a full RGB triple: vga_dac.cpp:367/388.
 *   - 0x3C8 write sets write_index (read_index=val-1); 0x3C7 sets read_index
 *     (write_index=val+1): vga_dac.cpp:275-288 / 253-265.
 *   - 0x3C8 read returns write_index (vga_dac.cpp:294); 0x3C7 read returns the DAC
 *     state nibble (0x3 if READ, 0x0 if WRITE) (vga_dac.cpp:271).
 *   - AH=10 AL=12 set block: int10_pal.cpp:254 (a pure 0x3C8 + 3*count 0x3C9 OUTs).
 *   - AH=10 AL=17 get block: int10_pal.cpp:306 (0x3C7 + 3*count 0x3C9 INs).
 *   - AH=10 AL=10 set single: int10_pal.cpp:219.
 *
 * Blob layout (little-endian, a "VGA2" palette-state record):
 *   0x00  4    magic "VGA2"
 *   0x04  1    bda_video_mode (0040:0049 & 0x7F)        -- expect 0x13
 *   0x05  1    pel_mask (read back at 0x3C6)            -- expect 0xFF
 *   0x06  1    dac_state_after_3c7 (read 0x3C7 after setting read index; bit0..1)
 *   0x07  1    write_index_latch (read 0x3C8 after a known 0x3C8 write)
 *   0x08  768  pal_bios   (final palette via INT 10h AH=10 AL=17 get-block)
 *   0x308 768  pal_ports  (final palette re-read via raw 0x3C7 + 0x3C9 ports)
 *   0x608 3    boundary   (the entry programmed with > 63 components, read raw)
 *   total = 8 + 768 + 768 + 3 = 1547 bytes
 */
#include <stdio.h>
#include <dos.h>
#include <conio.h>

#define NCOLOR  256U
#define PALSZ   (NCOLOR * 3U)    /* 768 */
#define STEPS   16U              /* fade granularity (BaK-style multi-step fade)  */

/* The base (full-brightness) palette and the working buffers. These live in the
 * DGROUP; three 768-byte arrays + the small blob fit comfortably under 64 KiB. */
static unsigned char pal_base[PALSZ];   /* full-brightness palette (fade source)  */
static unsigned char pal_work[PALSZ];   /* current faded palette written each step */
static unsigned char pal_bios[PALSZ];   /* final palette via AH=10 AL=17 get-block */
static unsigned char pal_ports[PALSZ];  /* final palette via raw 0x3C7/0x3C9 read  */

/* AH=10 AL=12 set block of DAC registers from ES:DX. int10_pal.cpp:254. */
static void set_block(unsigned char far *buf, unsigned int start, unsigned int count)
{
    union REGS rg;
    struct SREGS sr;
    segread(&sr);
    rg.x.ax = 0x1012;
    rg.x.bx = start;
    rg.x.cx = count;
    rg.x.dx = FP_OFF(buf);
    sr.es   = FP_SEG(buf);
    int86x(0x10, &rg, &rg, &sr);
}

/* AH=10 AL=17 get block of DAC registers into ES:DX. int10_pal.cpp:306. */
static void get_block(unsigned char far *buf, unsigned int start, unsigned int count)
{
    union REGS rg;
    struct SREGS sr;
    segread(&sr);
    rg.x.ax = 0x1017;
    rg.x.bx = start;
    rg.x.cx = count;
    rg.x.dx = FP_OFF(buf);
    sr.es   = FP_SEG(buf);
    int86x(0x10, &rg, &rg, &sr);
}

/* AH=10 AL=10 set a single DAC register: BL=idx, DH=r, CH=g, CL=b. int10_pal.cpp:219. */
static void set_single(unsigned char idx, unsigned char r, unsigned char g, unsigned char b)
{
    union REGS rg;
    rg.x.ax = 0x1010;
    rg.h.bl = idx;
    rg.h.dh = r;
    rg.h.ch = g;
    rg.h.cl = b;
    int86(0x10, &rg, &rg);
}

int main(void)
{
    union REGS rg;
    unsigned int i;
    unsigned char mode, pel_mask, dac_state, wlatch;
    unsigned char r, g, b;
    FILE *f;

    /* 1. SET MODE 13h. */
    rg.h.ah = 0x00;
    rg.h.al = 0x13;
    int86(0x10, &rg, &rg);

    /* 2. Build a deterministic full-brightness 6-bit palette and program ALL 256
     *    entries in one shot via INT 10h AH=10 AL=12 (the block path BaK uses). */
    for (i = 0; i < NCOLOR; i++) {
        pal_base[i * 3 + 0] = (unsigned char)(i & 0x3F);          /* red   */
        pal_base[i * 3 + 1] = (unsigned char)((63 - (i & 0x3F))); /* green */
        pal_base[i * 3 + 2] = (unsigned char)((i >> 2) & 0x3F);   /* blue  */
    }
    set_block((unsigned char far *) pal_base, 0, NCOLOR);

    /* 3. MULTI-STEP FADE-TO-BLACK: for step = STEPS-1 .. 0, write the whole palette
     *    scaled by (step / STEPS) via AH=10 AL=12 — exactly the BaK fade pattern
     *    (the entire DAC is rewritten every frame with values scaled toward 0).
     *    The LAST step (step == 0) lands the palette at all-zero; to leave a
     *    non-trivial, non-degenerate final palette to assert, we run the fade DOWN
     *    to step 1 (a dim-but-nonzero palette), which is the deterministic artifact
     *    the oracle captures. Each component: value = base * step / STEPS. */
    {
        unsigned int step;
        for (step = STEPS - 1; step >= 1; step--) {
            for (i = 0; i < PALSZ; i++) {
                /* integer-scale toward 0 (truncating), 6-bit domain. The product
                 * fits in unsigned int (max 63*15 = 945). */
                pal_work[i] = (unsigned char)(((unsigned int)pal_base[i] * step) / STEPS);
            }
            set_block((unsigned char far *) pal_work, 0, NCOLOR);
        }
    }

    /* 4. RAW PORT PATH: bypass the BIOS and write three entries directly via
     *    OUT 0x3C8 (start index) then OUT 0x3C9 x3 per entry (R,G,B). This drives
     *    the SAME device state machine the BIOS uses (vga_dac.cpp:275/302), proving
     *    the raw-port write path. Entries 10,11,12 get distinct known triples. */
    outp(0x3C8, 10);
    outp(0x3C9, 1);  outp(0x3C9, 2);  outp(0x3C9, 3);   /* entry 10 = (1,2,3)    */
    outp(0x3C9, 4);  outp(0x3C9, 5);  outp(0x3C9, 6);   /* entry 11 = (4,5,6) (auto-advance) */
    outp(0x3C9, 7);  outp(0x3C9, 8);  outp(0x3C9, 9);   /* entry 12 = (7,8,9)    */

    /* 5. Single-entry BIOS path AL=10: set entry 13 = (20,21,22). */
    set_single(13, 20, 21, 22);

    /* 6. 6-BIT BOUNDARY PROBE: write entry 200 with components > 63 via the raw
     *    port path. dosbox-x masks to 6 bits on write (vga_dac.cpp:316-317), so a
     *    write of 0xFF stores 0x3F, 0x80 stores 0x00, 0xC1 stores 0x01. We assert
     *    the stored values are exactly the low 6 bits. */
    outp(0x3C8, 200);
    outp(0x3C9, 0xFF);  /* -> 0x3F */
    outp(0x3C9, 0x80);  /* -> 0x00 */
    outp(0x3C9, 0xC1);  /* -> 0x01 */

    /* 7. Probe the index-latch / state read-backs (vga_dac.cpp:271/294). Set the
     *    read index to a known value via 0x3C7, then read 0x3C7 (DAC state nibble:
     *    0x3 because state==READ) and 0x3C8 (write_index, which 0x3C7 set to
     *    idx+1). We pick idx=50 so write_index latches to 51. */
    outp(0x3C7, 50);
    dac_state = (unsigned char) inp(0x3C7);   /* expect 0x03 (state==READ)        */
    wlatch    = (unsigned char) inp(0x3C8);   /* expect 51 (write_index = 50+1)   */

    /* 8. Read the pixel mask (0x3C6) — power-on 0xFF, untouched here. */
    pel_mask = (unsigned char) inp(0x3C6);

    /* 9. READ BACK the FINAL full 256-entry palette via INT 10h AH=10 AL=17. */
    get_block((unsigned char far *) pal_bios, 0, NCOLOR);

    /* 10. READ BACK the FINAL full palette AGAIN via the RAW ports (0x3C7 index 0,
     *     then 0x3C9 x3 per entry, auto-advancing). Both reads must agree, proving
     *     the BIOS get-block path and the raw-port path return identical state. */
    outp(0x3C7, 0);
    for (i = 0; i < NCOLOR; i++) {
        pal_ports[i * 3 + 0] = (unsigned char) inp(0x3C9);
        pal_ports[i * 3 + 1] = (unsigned char) inp(0x3C9);
        pal_ports[i * 3 + 2] = (unsigned char) inp(0x3C9);
    }

    /* 11. BDA video-mode byte (0040:0049). */
    mode = *((unsigned char far *) MK_FP(0x0040, 0x0049)) & 0x7F;

    /* 12. Write the self-describing "VGA2" blob. */
    f = fopen("VGAOUT.BIN", "wb");
    if (f == NULL)
        return 1;
    fwrite("VGA2", 1, 4, f);                  /* magic                            */
    fputc(mode, f);                           /* bda_video_mode                   */
    fputc(pel_mask, f);                       /* 0x3C6 pixel mask                 */
    fputc(dac_state, f);                      /* 0x3C7 DAC state nibble           */
    fputc(wlatch, f);                         /* 0x3C8 write-index latch          */
    fwrite(pal_bios, 1, PALSZ, f);            /* final palette via AL=17 get-block*/
    fwrite(pal_ports, 1, PALSZ, f);           /* final palette via raw ports      */
    fputc(pal_ports[200 * 3 + 0], f);         /* boundary entry 200 red  (-> 0x3F)*/
    fputc(pal_ports[200 * 3 + 1], f);         /* boundary entry 200 green (-> 0x00)*/
    fputc(pal_ports[200 * 3 + 2], f);         /* boundary entry 200 blue  (-> 0x01)*/
    fclose(f);

    /* Self-checks (exit non-zero so a broken mint is caught immediately). */
    if (mode != 0x13)
        return 2;
    /* Final palette must equal base*1/STEPS (the last fade step). */
    r = (unsigned char)(((unsigned int)pal_base[0] * 1U) / STEPS);
    if (pal_bios[0] != r)
        return 3;
    /* Both read paths must agree byte-for-byte. */
    for (i = 0; i < PALSZ; i++)
        if (pal_bios[i] != pal_ports[i])
            return 4;
    /* Raw-port written entries survive (they were set AFTER the fade). */
    if (pal_ports[10 * 3 + 0] != 1 || pal_ports[10 * 3 + 2] != 3)
        return 5;
    if (pal_ports[12 * 3 + 1] != 8)
        return 6;
    /* Single-entry BIOS path. */
    if (pal_ports[13 * 3 + 0] != 20 || pal_ports[13 * 3 + 2] != 22)
        return 7;
    /* 6-bit boundary masking. */
    if (pal_ports[200 * 3 + 0] != 0x3F) return 8;
    if (pal_ports[200 * 3 + 1] != 0x00) return 9;
    if (pal_ports[200 * 3 + 2] != 0x01) return 10;
    /* Index-latch / state read-backs. */
    if ((dac_state & 0x03) != 0x03) return 11;
    if (wlatch != 51) return 12;
    if (pel_mask != 0xFF) return 13;

    return 0;
}
