/* VGAINIT — the first VGA I/O-oracle program (plans/io-oracle.md Band V1).
 *
 * Proves the mode-13h foundation end to end: SET MODE 13h, DIRECT VRAM writes
 * (a deterministic test pattern through a far pointer to 0xA000), DAC palette
 * programming via INT 10h AX=1010 (set single DAC register), then READS BACK the
 * guest-observable device state — the VRAM bytes (A000:0000), the 6-bit DAC
 * palette (via the raw read ports 0x3C7 + 0x3C9), and the BDA video-mode byte
 * (0040:0049) — and writes it all as a single self-describing binary blob
 * (VGAOUT.BIN) via ordinary DOS file I/O. dosbox-x's blob is the golden; zdos
 * must reproduce it byte-identically offline.
 *
 * This is the §1.3 validated probe, productionized to a full mode-13h round-trip.
 *
 * Blob layout (little-endian, plans/io-oracle.md §1.1 "VGA state record"):
 *   0x00  4    magic "VGA1"
 *   0x04  1    bda_video_mode (0040:0049 & 0x7F)
 *   0x05  1    reserved (0)
 *   0x06  2    vram_len (0xFA00 = 64000)
 *   0x08  N    vram bytes (read back from A000:0000, length vram_len)
 *   ...   768  dac_palette (256 entries x R,G,B, each 0..63)
 *
 * Capture method: we read DAC via the RAW PORTS (0x3C7 read-index, then three
 * 0x3C9 data reads per entry — vga_dac.cpp:255/371) rather than INT 10h AX=1015,
 * so the blob asserts the DEVICE's port state machine directly (the most faithful
 * cross-emulator surface). The BIOS SET path (AX=1010, int10_pal.cpp:219) and the
 * raw-port GET path are thus BOTH exercised in one program.
 *
 * Determinism: every captured byte is a pure function of what this program wrote
 * (the i&0xFF VRAM pattern + the computed palette) — no host time, no retrace
 * bits (we never read 0x3DA). Proven by a double-mint byte-identical diff.
 */
#include <stdio.h>
#include <dos.h>
#include <conio.h>

#define VRAM_LEN 64000U          /* 320 * 200, mode 13h */

/* NOTE: we do NOT buffer the whole 64000-byte VRAM in a static array. That array
 * plus the C runtime's data would crowd the top of the 64 KiB DGROUP, and its
 * tail bytes then alias other guest data in an emulator-layout-dependent way
 * (observed as garbage in the last ~190 bytes of one emulator's capture). Instead
 * VRAM is STREAMED to the file directly from the A000 window — the capture is then
 * a pure function of VGA device state, exactly the oracle contract. Only the small
 * DAC buffer is kept resident. */
static unsigned char dac_copy[256 * 3];

/* Set DAC register `idx` to (r,g,b) via INT 10h AX=1010: BL=idx, DH=r, CH=g, CL=b
 * (int10.cpp:265 -> int10_pal.cpp:219). */
static void set_dac(unsigned char idx, unsigned char r, unsigned char g, unsigned char b)
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
    unsigned char far *vram;
    unsigned int i;
    unsigned char mode;
    FILE *f;

    /* 1. SET MODE 13h (INT 10h AH=00, AL=0x13). Clears VRAM + sets the BDA. */
    rg.h.ah = 0x00;
    rg.h.al = 0x13;
    int86(0x10, &rg, &rg);

    /* 2. DIRECT VRAM writes: a deterministic pattern vram[i] = i & 0xFF. */
    vram = (unsigned char far *) MK_FP(0xA000, 0);
    for (i = 0; i < VRAM_LEN; i++)
        vram[i] = (unsigned char)(i & 0xFF);

    /* 3. Program a known 256-entry palette via INT 10h AX=1010. Each entry is a
     *    computed 6-bit triple so the read-back is fully deterministic. */
    for (i = 0; i < 256; i++)
        set_dac((unsigned char)i,
                (unsigned char)(i & 0x3F),
                (unsigned char)((i >> 1) & 0x3F),
                (unsigned char)((i >> 2) & 0x3F));

    /* 4. READ BACK the DAC via the raw ports: 0x3C7 = read index 0 (auto-advances
     *    after each full RGB triple), then 3 reads of 0x3C9 per entry. */
    outp(0x3C7, 0);
    for (i = 0; i < 256; i++) {
        dac_copy[i * 3 + 0] = (unsigned char) inp(0x3C9);
        dac_copy[i * 3 + 1] = (unsigned char) inp(0x3C9);
        dac_copy[i * 3 + 2] = (unsigned char) inp(0x3C9);
    }

    /* 5. READ BACK the BDA video-mode byte (0040:0049). */
    mode = *((unsigned char far *) MK_FP(0x0040, 0x0049)) & 0x7F;

    /* 6. Write the self-describing blob to VGAOUT.BIN (binary, "wb"). VRAM is
     *    STREAMED directly from the A000 window (no 64 KiB guest buffer). */
    f = fopen("VGAOUT.BIN", "wb");
    if (f == NULL)
        return 1;

    fwrite("VGA1", 1, 4, f);                 /* magic */
    fputc(mode, f);                          /* bda_video_mode */
    fputc(0, f);                             /* reserved */
    fputc((int)(VRAM_LEN & 0xFF), f);        /* vram_len lo */
    fputc((int)((VRAM_LEN >> 8) & 0xFF), f); /* vram_len hi */
    for (i = 0; i < VRAM_LEN; i++)
        fputc(vram[i], f);                   /* vram bytes (streamed) */
    fwrite(dac_copy, 1, sizeof(dac_copy), f);/* dac palette */
    fclose(f);

    /* Self-check: mode must be 0x13 and the VRAM round-trip must hold. Exit
     * non-zero on failure so a broken mint is caught immediately. */
    if (mode != 0x13)
        return 2;
    if (vram[100] != (100 & 0xFF))
        return 3;

    return 0;
}
