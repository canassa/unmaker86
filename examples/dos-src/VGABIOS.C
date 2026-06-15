/* VGABIOS — the second VGA I/O-oracle program (plans/io-oracle.md Band V1 cont.).
 *
 * Where VGAINIT drove the device via DIRECT VRAM writes + the AX=1010 single-DAC
 * BIOS call, VGABIOS exercises the INT 10h SERVICE path specifically, so the
 * BIOS pixel + block-DAC routines AND the underlying device are both proven:
 *   - AH=00  set mode 13h
 *   - AH=0F  get current video mode (self-check it is 0x13)
 *   - AH=0C  WRITE PIXEL across a deterministic span of coordinates
 *   - AH=0D  READ PIXEL back (into the captured VRAM, the BIOS get-pixel path)
 *   - AH=10 AL=12  SET BLOCK OF DAC REGISTERS from an ES:DX buffer
 *
 * It then captures the SAME self-describing "VGA1" blob VGAINIT uses (so one
 * harness/format covers both): the full mode-13h VRAM (read back via AH=0D so the
 * BIOS get-pixel path is what fills the capture, not a direct read) + the full DAC
 * palette (read back via the raw ports) + the BDA mode byte.
 *
 * dosbox-x INT 10h citations: AH=0C/0D int10_put_pixel.cpp:200/293; AH=0F
 * int10.cpp:215; AH=10 AL=12 int10.cpp:268 -> int10_pal.cpp:254.
 *
 * Determinism: every captured byte is a pure function of the pixels and palette
 * this program writes — no host time, no retrace bits. Double-mint proven.
 */
#include <stdio.h>
#include <dos.h>
#include <conio.h>

#define W 320U
#define H 200U
#define VRAM_LEN (W * H)   /* 64000 */

/* NOTE: we do NOT buffer the whole 64000-byte VRAM in a static array — that plus
 * the palette arrays overflows the 64 KiB DGROUP. Instead VRAM is STREAMED to the
 * file one pixel at a time via the BIOS AH=0D read path. Only the two small
 * palette buffers are kept resident. */
static unsigned char dac_copy[256 * 3];
static unsigned char dac_block[256 * 3];

/* AH=0C write pixel: AL=color, CX=x, DX=y, BH=page. int10_put_pixel.cpp:200. */
static void put_pixel(unsigned int x, unsigned int y, unsigned char color)
{
    union REGS rg;
    rg.h.ah = 0x0C;
    rg.h.al = color;
    rg.h.bh = 0;
    rg.x.cx = x;
    rg.x.dx = y;
    int86(0x10, &rg, &rg);
}

/* AH=0D read pixel: CX=x, DX=y, BH=page -> AL=color. int10_put_pixel.cpp:293. */
static unsigned char get_pixel(unsigned int x, unsigned int y)
{
    union REGS rg;
    rg.h.ah = 0x0D;
    rg.h.bh = 0;
    rg.x.cx = x;
    rg.x.dx = y;
    int86(0x10, &rg, &rg);
    return rg.h.al;
}

int main(void)
{
    union REGS rg;
    struct SREGS sr;
    unsigned int x, y, i;
    unsigned char mode;
    FILE *f;

    /* 1. SET MODE 13h. */
    rg.h.ah = 0x00;
    rg.h.al = 0x13;
    int86(0x10, &rg, &rg);

    /* 2. AH=0F get current mode -> AL. Self-check below. */
    rg.h.ah = 0x0F;
    int86(0x10, &rg, &rg);
    mode = rg.h.al & 0x7F;

    /* 3. AH=0C write a deterministic pattern across EVERY pixel via the BIOS. The
     *    color is a pure function of (x,y), so the VRAM is fully deterministic. */
    for (y = 0; y < H; y++)
        for (x = 0; x < W; x++)
            put_pixel(x, y, (unsigned char)((x + y) & 0xFF));

    /* 4. AH=10 AL=12 set a BLOCK of all 256 DAC registers from a buffer. Build a
     *    deterministic 6-bit palette: entry i = (i&0x3F, (63-i)&0x3F, (i*2)&0x3F). */
    for (i = 0; i < 256; i++) {
        dac_block[i * 3 + 0] = (unsigned char)(i & 0x3F);
        dac_block[i * 3 + 1] = (unsigned char)((63 - (i & 0x3F)) & 0x3F);
        dac_block[i * 3 + 2] = (unsigned char)((i * 2) & 0x3F);
    }
    segread(&sr);
    rg.x.ax = 0x1012;          /* AH=10 AL=12 set block of DAC registers */
    rg.x.bx = 0;               /* start index 0 */
    rg.x.cx = 256;             /* count */
    rg.x.dx = (unsigned int)(unsigned long)dac_block; /* ES:DX = buffer (DS=ES in small model) */
    sr.es = sr.ds;
    int86x(0x10, &rg, &rg, &sr);

    /* 5. READ BACK the DAC via the raw ports (0x3C7 read-index 0, then 0x3C9 x3). */
    outp(0x3C7, 0);
    for (i = 0; i < 256; i++) {
        dac_copy[i * 3 + 0] = (unsigned char) inp(0x3C9);
        dac_copy[i * 3 + 1] = (unsigned char) inp(0x3C9);
        dac_copy[i * 3 + 2] = (unsigned char) inp(0x3C9);
    }

    /* 6. Write the self-describing "VGA1" blob (same layout as VGAINIT). VRAM is
     *    STREAMED via the BIOS AH=0D get-pixel path so the BIOS read path is what
     *    fills the capture (int10_put_pixel.cpp:293) without a 64 KiB buffer. */
    f = fopen("VGAOUT.BIN", "wb");
    if (f == NULL)
        return 1;
    fwrite("VGA1", 1, 4, f);
    fputc(mode, f);
    fputc(0, f);
    fputc((int)(VRAM_LEN & 0xFF), f);
    fputc((int)((VRAM_LEN >> 8) & 0xFF), f);
    for (y = 0; y < H; y++)
        for (x = 0; x < W; x++)
            fputc(get_pixel(x, y), f);
    fwrite(dac_copy, 1, sizeof(dac_copy), f);
    fclose(f);

    /* Self-checks: mode 13h, a known pixel round-trips, a known DAC entry. */
    if (mode != 0x13)
        return 2;
    if (get_pixel(7, 5) != (unsigned char)((7 + 5) & 0xFF))
        return 3;
    if (dac_copy[1 * 3 + 0] != 1)   /* entry 1 red = 1 */
        return 4;

    return 0;
}
