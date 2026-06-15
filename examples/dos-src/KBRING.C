/* KBRING — INT 16h BIOS keyboard services driven through a PROGRAM-SEEDED BDA
 * keyboard ring (I/O band K1, plans/io-oracle.md s2.2).
 *
 * The faithful, deterministic oracle for the INT 16h layer is NOT real key
 * injection (dosbox-x AUTOTYPE is timing-based / non-deterministic, rejected in
 * io-oracle.md s2.2). Instead THIS program writes a known sequence of
 * scancode:ascii words DIRECTLY into the BDA keyboard ring (0040:001E...,
 * advancing the tail at 0040:001C exactly as the IRQ1 handler would), then reads
 * them back through INT 16h and prints the (scancode,ascii) / flag / empty
 * results. Both dosbox-x and zdos run this identical guest code over the
 * identical seeded ring, so the goldens match by construction and are fully
 * deterministic (the program is the SOLE source of the keys; no host input).
 *
 * BDA ring layout (references/dosbox-x/src/ints/bios_keyboard.cpp + bda.zig):
 *   0040:0017  FLAGS1  shift-flag byte (AH=02 returns this)
 *   0040:001A  HEAD    offset (from 0040:0000) of the next word to dequeue
 *   0040:001C  TAIL    offset of the next free slot
 *   0040:001E  ring    16 words, region [0x1E, 0x3E)
 *   0040:0080  START   ring start offset (0x1E)
 *   0040:0082  END     ring end offset   (0x3E)
 * Empty iff head==tail. Dequeue advances head by 2, wrapping to START at END
 * (get_key, bios_keyboard.cpp:492-503).
 *
 * INT 16h services exercised (bios_keyboard.cpp:1319 INT16_Handler):
 *   AH=01 CHECK (peek)  ZF=1 if empty else ZF=0, AX=head word, NOT dequeued.
 *   AH=00 READ (block)  dequeue head, AH=scancode AL=ascii. SKIPS enhanced keys.
 *   AH=02 GET SHIFT     AL = FLAGS1 (0040:0017).
 *   AH=10 READ enhanced dequeue, KEEP enhanced scancodes (does not skip them);
 *                       a key whose low byte==0xf0 (and high!=0) -> low cleared.
 *   AH=11 CHECK enhanced peek; same 0xf0 low-clear transform; not dequeued.
 *
 * "Enhanced" per IsEnhancedKey (bios_keyboard.cpp:1269): scancode part > 0x84,
 * OR (low byte==0xf0 && high!=0). AH=00/01 silently drop these; AH=10/11 return
 * them. We seed an F11 (0x8500, scancode 0x85>0x84) to show the difference.
 *
 * Only oracle-able values are printed: the (scancode,ascii) pairs read back, the
 * peek/empty booleans, the shift-flag byte. No files are created.
 */
#include <stdio.h>
#include <dos.h>

#define BDA_SEG     0x0040
#define OFF_FLAGS1  0x0017
#define OFF_HEAD    0x001A
#define OFF_TAIL    0x001C
#define OFF_RING    0x001E
#define RING_START  0x001E
#define RING_END    0x003E   /* one past the last word slot */

/* Far accessors into the BDA segment. */
static void bda_pokew(unsigned off, unsigned val)
{
    unsigned far *p = (unsigned far *)MK_FP(BDA_SEG, off);
    *p = val;
}
static unsigned bda_peekw(unsigned off)
{
    unsigned far *p = (unsigned far *)MK_FP(BDA_SEG, off);
    return *p;
}
static void bda_pokeb(unsigned off, unsigned char val)
{
    unsigned char far *p = (unsigned char far *)MK_FP(BDA_SEG, off);
    *p = val;
}

/* Reset the ring to empty: head==tail==START, START/END pointers set. */
static void ring_reset(void)
{
    bda_pokew(OFF_HEAD, RING_START);
    bda_pokew(OFF_TAIL, RING_START);
    bda_pokew(0x0080, RING_START);
    bda_pokew(0x0082, RING_END);
}

/* Push a scancode:ascii word at the tail exactly like the IRQ1 handler:
 * write the word at TAIL, advance TAIL by 2 wrapping to START at END. */
static void ring_push(unsigned word)
{
    unsigned tail = bda_peekw(OFF_TAIL);
    bda_pokew(tail, word);
    tail += 2;
    if (tail >= RING_END) tail = RING_START;
    bda_pokew(OFF_TAIL, tail);
}

/* INT 16h with AH preset; returns AX, and stores the flags word via *flags. */
static unsigned int16(unsigned char ah, unsigned *flags)
{
    union REGS in, out;
    in.h.ah = ah;
    int86(0x16, &in, &out);
    if (flags) *flags = out.x.flags;
    return out.x.ax;
}

#define ZF(f) (((f) & 0x40) ? 1 : 0)

int main(void)
{
    unsigned ax, fl;

    /* ---- Phase 1: NORMAL keys via AH=01 peek + AH=00 read ---------------- */
    /* Seed three normal scan:ascii words: 'a','b', and Enter. */
    ring_reset();
    ring_push(0x1E61);   /* scancode 0x1E, ascii 'a' (0x61) */
    ring_push(0x3062);   /* scancode 0x30, ascii 'b' (0x62) */
    ring_push(0x1C0D);   /* scancode 0x1C, ascii CR  (0x0D) */

    /* AH=01 peek: non-empty, head word, NOT dequeued. */
    ax = int16(0x01, &fl);
    printf("peek1 empty=%d scan=%02X ascii=%02X\n", ZF(fl), (ax >> 8) & 0xFF, ax & 0xFF);
    /* A second peek must observe the SAME word (peek does not consume). */
    ax = int16(0x01, &fl);
    printf("peek2 empty=%d scan=%02X ascii=%02X\n", ZF(fl), (ax >> 8) & 0xFF, ax & 0xFF);

    /* AH=00 read: drain all three in order. */
    ax = int16(0x00, &fl);
    printf("read1 scan=%02X ascii=%02X\n", (ax >> 8) & 0xFF, ax & 0xFF);
    ax = int16(0x00, &fl);
    printf("read2 scan=%02X ascii=%02X\n", (ax >> 8) & 0xFF, ax & 0xFF);
    ax = int16(0x00, &fl);
    printf("read3 scan=%02X ascii=%02X\n", (ax >> 8) & 0xFF, ax & 0xFF);

    /* Ring is now empty: AH=01 must report ZF=1 (empty). */
    ax = int16(0x01, &fl);
    printf("peek_empty empty=%d ax=%04X\n", ZF(fl), ax);

    /* ---- Phase 2: ring WRAP across END --------------------------------- */
    /* Drive the tail near END so a push wraps to START, proving the dequeue
     * wrap matches (get_key thead=head+2; if thead>=end thead=start). */
    ring_reset();
    bda_pokew(OFF_HEAD, 0x3A);   /* head/tail near the top: slots 0x3A,0x3C,then wrap */
    bda_pokew(OFF_TAIL, 0x3A);
    ring_push(0x4837);   /* slot 0x3A: scancode 0x48, ascii '7' (0x37) */
    ring_push(0x5038);   /* slot 0x3C: scancode 0x50, ascii '8' (0x38) */
    ring_push(0x4D39);   /* wraps to slot 0x1E (START): scancode 0x4D, ascii '9' */
    ax = int16(0x00, &fl);
    printf("wrap1 scan=%02X ascii=%02X\n", (ax >> 8) & 0xFF, ax & 0xFF);
    ax = int16(0x00, &fl);
    printf("wrap2 scan=%02X ascii=%02X\n", (ax >> 8) & 0xFF, ax & 0xFF);
    ax = int16(0x00, &fl);   /* this dequeue reads the wrapped slot at START */
    printf("wrap3 scan=%02X ascii=%02X head=%04X\n", (ax >> 8) & 0xFF, ax & 0xFF, bda_peekw(OFF_HEAD));

    /* ---- Phase 3: AH=02 shift flags ------------------------------------ */
    /* Seed FLAGS1 to a known state (Caps Lock 0x40 | Left Shift 0x02 = 0x42)
     * and read it back through AH=02. */
    bda_pokeb(OFF_FLAGS1, 0x42);
    ax = int16(0x02, &fl);
    printf("shift al=%02X\n", ax & 0xFF);
    bda_pokeb(OFF_FLAGS1, 0x00);   /* good citizenship: clear it back */

    /* ---- Phase 4: AH=10/11 enhanced vs AH=00/01 normal ------------------ */
    /* Seed an ENHANCED key F11 (0x8500, scancode 0x85 > 0x84) followed by a
     * normal key. AH=00 must SKIP the enhanced one and return the normal key;
     * AH=10 must RETURN the enhanced one verbatim. */
    ring_reset();
    ring_push(0x8500);   /* F11 (enhanced: scancode 0x85 > 0x84) */
    ring_push(0x1E61);   /* normal 'a' */
    /* AH=00 skips the enhanced F11, returns the normal 'a'. */
    ax = int16(0x00, &fl);
    printf("enh_read00 scan=%02X ascii=%02X\n", (ax >> 8) & 0xFF, ax & 0xFF);

    /* Re-seed and read the SAME pair via AH=10 (enhanced): F11 is returned. */
    ring_reset();
    ring_push(0x8500);   /* F11 */
    ring_push(0x1E61);   /* 'a' */
    ax = int16(0x10, &fl);
    printf("enh_read10a scan=%02X ascii=%02X\n", (ax >> 8) & 0xFF, ax & 0xFF);
    ax = int16(0x10, &fl);
    printf("enh_read10b scan=%02X ascii=%02X\n", (ax >> 8) & 0xFF, ax & 0xFF);

    /* AH=11 peek enhanced: F11 visible (ZF=0), not dequeued; AH=01 peek on the
     * SAME ring SKIPS the enhanced key (it discards it, then sees 'a'). */
    ring_reset();
    ring_push(0x8500);   /* F11 */
    ring_push(0x1E61);   /* 'a' */
    ax = int16(0x11, &fl);
    printf("enh_peek11 empty=%d scan=%02X ascii=%02X\n", ZF(fl), (ax >> 8) & 0xFF, ax & 0xFF);
    ax = int16(0x01, &fl);   /* discards F11, returns 'a' */
    printf("enh_peek01 empty=%d scan=%02X ascii=%02X\n", ZF(fl), (ax >> 8) & 0xFF, ax & 0xFF);

    /* The low-byte==0xf0 enhanced transform (AH=10/11 clear the low part):
     * seed 0x84F0 (high=0x84 nonzero, low=0xf0 -> enhanced); AH=11 peek and
     * AH=10 read must return 0x8400 (low cleared). */
    ring_reset();
    ring_push(0x84F0);
    ax = int16(0x11, &fl);
    printf("f0_peek11 empty=%d ax=%04X\n", ZF(fl), ax);
    ax = int16(0x10, &fl);
    printf("f0_read10 ax=%04X\n", ax);

    return 0;
}
