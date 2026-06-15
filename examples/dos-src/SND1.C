/* SND1 — PC-speaker / PIT channel-2 register programming + DETERMINISTIC
 * read-back (I/O band 5, plans/io-oracle.md s3.1a). The v1 sound contract is
 * REGISTER-TRACE ONLY: NO sample/FM synthesis. The oracle is the deterministic,
 * guest-observable register state a tone-programming sequence leaves behind, NOT
 * any produced audio.
 *
 * A DOS game makes a PC-speaker beep by:
 *   1. programming PIT channel 2: OUT 0x43, <ch2 mode/access byte>, then the
 *      16-bit divisor as OUT 0x42 lo, OUT 0x42 hi (frequency = 1193182/divisor),
 *   2. enabling the speaker via port 0x61 bits 0 (timer-2 GATE) and 1 (speaker
 *      DATA): read-modify-write to set them, beep, then clear them to silence.
 *
 * The DETERMINISTIC, oracle-able artifacts this program asserts:
 *   (a) the PIT ch2 read-back STATUS byte (8254 read-back command, OUT 0x43 with
 *       bits 7-6 = 11, bit5=1 do-not-latch-count, bit4=0 latch-status, bit3=1
 *       select ch2 => 0xE8). The status byte encodes (timer.cpp status_latch:461)
 *         bit0   = BCD
 *         bits1-3= mode
 *         bits4-5= read/load access mode (from read_state = ctrl>>4 & 3)
 *         bit6   = NULL count (1 = a mode byte was written but no counter yet)
 *         bit7   = OUT pin level
 *       We assert ONLY the host-INDEPENDENT bits. bit7 (OUT) is EXCLUDED: in a
 *       counting mode it tracks the divided clock = emulated-time/PIC_FullIndex
 *       dependent (timer.cpp counter_output:301). So we mask:
 *         status & 0x7F  after a counter is loaded (mode+access+null=0),
 *         status & 0x40  to show NULL count is 1 BEFORE a counter is written and
 *                        0 AFTER (a pure-logic transition, not time).
 *   (b) port 0x61 GATE/DATA bits. read_p61 (keyboard.cpp:724) returns
 *         (port_61_data & 0x0F)           <- what we wrote, DETERMINISTIC
 *         | bit5 (0x20) = TIMER_GetOutput2()||gate-off  <- EXCLUDED: timer-2 OUT
 *                                          tracks emulated time when the gate is on
 *         | bit4 (0x10) = fmod(PIC_FullIndex(),0.030)>0.015 <- EXCLUDED: a pure
 *                                          wall-clock refresh toggle
 *         | (bits6-7 are 0 on MCH_VGA, the oracle's machine=vgaonly)
 *       So we assert ONLY inp(0x61) & 0x0F.
 *
 * The VOLATILE LIVE COUNT is deliberately NOT asserted. The 8254 counter
 * DECREMENTS as a function of elapsed time; dosbox-x derives the latched count
 * from PIC_FullIndex() (timer.cpp read_counter:331) which under cycles=max is
 * emulated-time tied to the host run, so the exact decremented value differs
 * run-to-run = NON-oracle-able (the same non-determinism-boundary discipline used
 * to EXCLUDE host-mtime in the DOS phase). Proven by double-mint: the masked
 * status/mode/access bits and the 0x61 gate bits are byte-identical across runs;
 * the raw live count is not, so it is excluded.
 *
 * Only oracle-able values are printed; no files are created.
 */
#include <stdio.h>
#include <conio.h>

/* I/O ports. */
#define PIT_CH2     0x42    /* channel-2 counter data */
#define PIT_CTRL    0x43    /* control word / read-back command */
#define PORT_61     0x61    /* KBC port B: bit0=timer2 gate, bit1=speaker data */

/* Control word: ch2 (bits7-6=10), access lo/hi (bits5-4=11), mode 3 square
 * wave (bits3-1=011), binary (bit0=0) => 1011 0110 = 0xB6. The canonical
 * PC-speaker tone-programming byte. */
#define CTRL_CH2_M3 0xB6
/* Read-back STATUS for ch2: bits7-6=11 read-back, bit5=1 (do NOT latch count),
 * bit4=0 (latch status), bit3=1 (select ch2) => 1110 1000 = 0xE8. */
#define RB_STATUS_CH2 0xE8

/* A clean divisor: 1193182/1000Hz ~= 1193 = 0x04A9. Any fixed value works; the
 * frequency is a pure function of it. */
#define DIVISOR     0x04A9

int main(void)
{
    unsigned char p61_before, p61_on, p61_off;
    unsigned char st_newmode, st_loaded;

    /* ---- Phase 0: snapshot port 0x61 gate/data bits at startup ---------- */
    /* The BIOS leaves the speaker silenced (bits 0,1 = 0). We assert only the
     * low nibble (the deterministic written bits). */
    p61_before = (unsigned char)(inp(PORT_61) & 0x0F);
    printf("p61_before=%02X\n", p61_before);

    /* ---- Phase 1: write the CONTROL word ONLY, read back STATUS --------- */
    /* After a control word but BEFORE a counter is loaded, the 8254 sets the
     * NULL-count status bit (bit6=1): "a mode byte was written, no counter yet"
     * (timer.cpp:891 new_mode=true; status_latch:481). This is a pure-logic
     * transition (no time), so we assert it. */
    outp(PIT_CTRL, CTRL_CH2_M3);
    outp(PIT_CTRL, RB_STATUS_CH2);
    st_newmode = (unsigned char)inp(PIT_CH2);
    /* mode(bits1-3)=3 -> 0x06; access(bits4-5)=lohi=3 -> 0x30; null(bit6)=1 ->
     * 0x40; bcd(bit0)=0. OUT(bit7) excluded by masking. Expect (st&0x7F)=0x76. */
    printf("status_newmode=%02X null=%d\n",
           (unsigned)(st_newmode & 0x7F), (st_newmode & 0x40) ? 1 : 0);

    /* ---- Phase 2: write the 16-bit DIVISOR (lo then hi) ----------------- */
    outp(PIT_CH2, DIVISOR & 0xFF);          /* LSB */
    outp(PIT_CH2, (DIVISOR >> 8) & 0xFF);   /* MSB */

    /* Read back STATUS again: now a counter IS loaded, so NULL count clears to
     * 0 (timer.cpp write_latch:681 new_mode=false). mode/access unchanged. */
    outp(PIT_CTRL, RB_STATUS_CH2);
    st_loaded = (unsigned char)inp(PIT_CH2);
    /* Expect (st&0x7F)=0x36 (mode3|lohi, null=0); OUT bit7 excluded. */
    printf("status_loaded=%02X null=%d\n",
           (unsigned)(st_loaded & 0x7F), (st_loaded & 0x40) ? 1 : 0);

    /* ---- Phase 3: ENABLE the speaker (port 0x61 bits 0,1) --------------- */
    /* Read-modify-write: set the timer-2 gate (bit0) and speaker data (bit1). */
    {
        unsigned char v = (unsigned char)inp(PORT_61);
        outp(PORT_61, (unsigned char)(v | 0x03));
    }
    p61_on = (unsigned char)(inp(PORT_61) & 0x0F);
    /* Expect the low nibble to now have bits 0,1 set: 0x03 (the upper preserved
     * bits 2,3 stay whatever the BIOS left -> assert low TWO bits explicitly). */
    printf("p61_on=%02X gate=%d data=%d\n",
           p61_on, (p61_on & 0x01) ? 1 : 0, (p61_on & 0x02) ? 1 : 0);

    /* ---- Phase 4: DISABLE the speaker (clear bits 0,1) ------------------ */
    {
        unsigned char v = (unsigned char)inp(PORT_61);
        outp(PORT_61, (unsigned char)(v & ~0x03));
    }
    p61_off = (unsigned char)(inp(PORT_61) & 0x0F);
    printf("p61_off=%02X gate=%d data=%d\n",
           p61_off, (p61_off & 0x01) ? 1 : 0, (p61_off & 0x02) ? 1 : 0);

    /* ---- Phase 5: derived frequency (pure function of the divisor) ------ */
    /* Not a device read-back, but a deterministic check that the divisor we
     * programmed maps to the intended tone. 1193182/0x04A9 = 1000 (integer). */
    printf("divisor=%04X freq=%lu\n",
           (unsigned)DIVISOR, (unsigned long)(1193182UL / (unsigned long)DIVISOR));

    return 0;
}
