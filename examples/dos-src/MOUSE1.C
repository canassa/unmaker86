/* MOUSE1 — INT 33h mouse driver DETERMINISTIC state round-trips (I/O band 4,
 * plans/io-oracle.md s4).
 *
 * The faithful, deterministic oracle for the mouse is NOT a live host pointer
 * (dosbox-x's real mouse position depends on host pointer events =
 * non-deterministic, rejected in io-oracle.md s4). Instead this program PLACES
 * the cursor at known coordinates with AX=0004 (Set Position) and reads it back
 * with AX=0003 (Get Position & Buttons), and sets/reads the other driver state
 * (range, sensitivity, show-count) through the documented calls. No host pointer
 * is ever involved, so both dosbox-x and zdos run identical guest code over
 * identical programmatic input -> the goldens match by construction and are fully
 * deterministic (proven by double-mint).
 *
 * Semantics matched to references/dosbox-x/src/ints/mouse.cpp:
 *   AX=0000 reset+status: AX=0xFFFF present, BX=MOUSE_BUTTONS=3 (mouse.cpp:159).
 *     Resets state to per-VIDEO-MODE defaults (read from BDA 0040:0049). Mode 13h:
 *     range x=0..639, y=0..199, gran_x=0xfffe (X rounded to even), gran_y=0xffff;
 *     cursor centered at ((max_x+1)/2,(max_y+1)/2)=(320,100); hidden; buttons=0
 *     (Mouse_AfterNewVideoMode:1422 + Mouse_Reset:1570).
 *   AX=0003 get: CX = mouse.x & gran_x (POS_X), DX = mouse.y & gran_y (POS_Y),
 *     BX = buttons (mouse.cpp:1642). NOTE the gran_x=0xfffe rounding in mode 13h:
 *     an ODD x is reported rounded DOWN to even.
 *   AX=0004 set: signed clamp to [min,max]; >=max -> max, <=min -> min
 *     (mouse.cpp:1659).
 *   AX=0007/0008 define range: min<->max swap, then reclamp live position
 *     (mouse.cpp:1732/1801).
 *   AX=0001/0002 show/hide: the `hidden` SHOW-COUNT (show decrements, hide
 *     increments; visible iff hidden==0; mouse.cpp:1627/1633). The count itself is
 *     not directly readable, so we prove its behavior via Set-then-show/hide and
 *     re-read position (position is unaffected by visibility -> stable round-trip).
 *   AX=001A/001B set/get sensitivity: values clamped 0..100, stored, read back
 *     (mouse.cpp:2008/2013).
 *   AX=0024 get version/type: BX=0x0805, CH=0x04 (PS/2), CL=0 (mouse.cpp:2074).
 *   AX=000B read motion counters: headless dosbox-x is NOT mouse-locked, so the
 *     counters read back 0/0 (Mouse_Read_Motion_Data, mouse.cpp:1610 -> locked is
 *     false). Deterministic constant; asserted as 0/0.
 *
 * Only oracle-able values are printed (the read-back position/buttons, range-clamp
 * results, sensitivity round-trip, version/type, motion counters). No host pointer,
 * no files. Mode 13h is set FIRST so the reset defaults match a 320x200 screen.
 */
#include <stdio.h>
#include <dos.h>

/* INT 33h with a full register frame. */
static void mouse(union REGS *r)
{
    int86(0x33, r, r);
}

/* Set mode 13h via INT 10h AX=0013 so the mouse reset defaults match 320x200. */
static void set_mode13(void)
{
    union REGS r;
    r.x.ax = 0x0013;
    int86(0x10, &r, &r);
}

/* Place the cursor at (x,y) via AX=0004. */
static void set_pos(int x, int y)
{
    union REGS r;
    r.x.ax = 0x0004;
    r.x.cx = (unsigned)x;
    r.x.dx = (unsigned)y;
    mouse(&r);
}

/* Read position+buttons via AX=0003; report the rounded POS the driver returns. */
static void get_pos(unsigned *bx, unsigned *cx, unsigned *dx)
{
    union REGS r;
    r.x.ax = 0x0003;
    mouse(&r);
    *bx = r.x.bx;
    *cx = r.x.cx;
    *dx = r.x.dx;
}

int main(void)
{
    union REGS r;
    unsigned bx, cx, dx;

    /* ---- Set mode 13h, then reset/initialize the driver ----------------- */
    set_mode13();

    r.x.ax = 0x0000;
    mouse(&r);
    printf("reset present=%04X buttons=%u\n", r.x.ax, r.x.bx);

    /* After reset the cursor is centered for mode 13h: (320,100). Read it. */
    get_pos(&bx, &cx, &dx);
    printf("reset_pos buttons=%u x=%u y=%u\n", bx, cx, dx);

    /* ---- Set/Get position round-trips (within the default range) -------- */
    /* EVEN x values round-trip exactly (gran_x=0xfffe in mode 13h). */
    set_pos(100, 50);
    get_pos(&bx, &cx, &dx);
    printf("set1 x=%u y=%u\n", cx, dx);

    set_pos(200, 150);
    get_pos(&bx, &cx, &dx);
    printf("set2 x=%u y=%u\n", cx, dx);

    /* ODD x demonstrates the gran_x=0xfffe rounding: 101 -> 100, y unmasked. */
    set_pos(101, 75);
    get_pos(&bx, &cx, &dx);
    printf("set_odd x=%u y=%u\n", cx, dx);

    /* ---- Clamp against the DEFAULT mode-13h range (x<=639, y<=199) ------ */
    /* x beyond max clamps to 639 (rounded by gran -> 638); y beyond 199 -> 199. */
    set_pos(700, 300);
    get_pos(&bx, &cx, &dx);
    printf("clamp_hi x=%u y=%u\n", cx, dx);

    /* Negative-ish (large unsigned) below min clamps to 0. Use a value <= min. */
    set_pos(0, 0);
    get_pos(&bx, &cx, &dx);
    printf("clamp_lo x=%u y=%u\n", cx, dx);

    /* ---- Restrict the range, then Set OUTSIDE it to prove the clamp ----- */
    /* AX=0007 horizontal range [50,150]; AX=0008 vertical range [20,80]. */
    r.x.ax = 0x0007; r.x.cx = 50; r.x.dx = 150;
    mouse(&r);
    r.x.ax = 0x0008; r.x.cx = 20; r.x.dx = 80;
    mouse(&r);

    /* Set above the restricted max -> clamps to (150,80). */
    set_pos(500, 500);
    get_pos(&bx, &cx, &dx);
    printf("rng_hi x=%u y=%u\n", cx, dx);

    /* Set below the restricted min -> clamps to (50,20). */
    set_pos(10, 5);
    get_pos(&bx, &cx, &dx);
    printf("rng_lo x=%u y=%u\n", cx, dx);

    /* A value inside the restricted range round-trips (even x). */
    set_pos(100, 40);
    get_pos(&bx, &cx, &dx);
    printf("rng_in x=%u y=%u\n", cx, dx);

    /* AX=0007 with min>max swaps them: range [30,120] given cx=120,dx=30. */
    r.x.ax = 0x0007; r.x.cx = 120; r.x.dx = 30;
    mouse(&r);
    set_pos(200, 40);   /* x clamps to 120 */
    get_pos(&bx, &cx, &dx);
    printf("rng_swap x=%u y=%u\n", cx, dx);

    /* ---- Show / Hide: position is unaffected by visibility ------------- */
    set_pos(60, 30);
    r.x.ax = 0x0001; mouse(&r);   /* show */
    r.x.ax = 0x0001; mouse(&r);   /* show again (count floors at 0) */
    r.x.ax = 0x0002; mouse(&r);   /* hide */
    get_pos(&bx, &cx, &dx);
    printf("showhide x=%u y=%u\n", cx, dx);

    /* ---- Sensitivity set/get round-trip (clamped 0..100) -------------- */
    r.x.ax = 0x001A; r.x.bx = 60; r.x.cx = 70; r.x.dx = 80;
    mouse(&r);
    r.x.ax = 0x001B; mouse(&r);
    printf("sens x=%u y=%u d=%u\n", r.x.bx, r.x.cx, r.x.dx);

    /* Over-100 values clamp to 100. */
    r.x.ax = 0x001A; r.x.bx = 200; r.x.cx = 150; r.x.dx = 101;
    mouse(&r);
    r.x.ax = 0x001B; mouse(&r);
    printf("sens_clamp x=%u y=%u d=%u\n", r.x.bx, r.x.cx, r.x.dx);

    /* ---- Version / type ---------------------------------------------- */
    r.x.ax = 0x0024; mouse(&r);
    printf("ver bx=%04X ch=%02X cl=%02X\n", r.x.bx, (r.x.cx >> 8) & 0xFF, r.x.cx & 0xFF);

    /* ---- Read motion counters (headless: not locked -> 0/0) ----------- */
    r.x.ax = 0x000B; mouse(&r);
    printf("motion cx=%u dx=%u\n", r.x.cx, r.x.dx);

    /* ---- Software reset (AX=0021) re-centers; confirm round-trip ------ */
    r.x.ax = 0x0021; mouse(&r);
    printf("sreset present=%04X buttons=%u\n", r.x.ax, r.x.bx);
    get_pos(&bx, &cx, &dx);
    printf("sreset_pos buttons=%u x=%u y=%u\n", bx, cx, dx);

    return 0;
}
