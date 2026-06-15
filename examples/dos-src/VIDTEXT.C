/* VIDTEXT — INT 10h text/cursor BIOS services on the default 80x25 text mode.
 *
 * Exercises the cursor + mode-query surface zdos fully implements (int10.zig
 * AH=0F get-mode, AH=02 set-cursor, AH=03 get-cursor+shape — all pure BDA
 * reads/writes, no host clock), so the round-trips are deterministic on both
 * dosbox-x and zdos and oracle-able by construction.
 *
 * Semantics matched to references/dosbox-x/src/ints/int10.cpp INT10_Handler:
 *   AH=0F get videomode (int10.cpp:213): AL = BIOSMEM_CURRENT_MODE,
 *     AH = (uint8)BIOSMEM_NB_COLS, BH = BIOSMEM_CURRENT_PAGE. The boot text mode
 *     is 03h / 80 cols / page 0. zdos handle AH=0F returns videoMode()/cols/page
 *     from the SAME BDA fields (and seeds them in bda.zig initDefaults).
 *   AH=02 set cursor pos (int10.cpp:130): writes BIOSMEM_CURSOR_POS[page] from
 *     DH=row, DL=col. zdos writes BDA_PHYS+OFF_CURSOR_POS+page*2 = DX.
 *   AH=03 get cursor pos+shape (int10.cpp:133): DL=col, DH=row from
 *     BIOSMEM_CURSOR_POS[page]; CX = BIOSMEM_CURSOR_TYPE (the shape word). For the
 *     boot text mode FinishSetMode sets the shape via INT10_SetCursorShape(6,7)
 *     => CURSOR_TYPE = last|(first<<8) = 0x0607 (int10_modes.cpp:988 +
 *     int10_char.cpp:1216). zdos returns DX from the BDA cursor word and CX=0x0607
 *     (int10.zig AH=03), matching that boot shape.
 *
 * AH=0E teletype is NOW MODELED (zdos models the B8000 text page + the INT 10h
 * text services). dosbox-x's AH=0E (INT10_TeletypeOutput) writes the glyph to text
 * VRAM and ADVANCES the cursor; zdos does the same (writeCharCell + cursor advance,
 * int10.zig). So this program now ASSERTS the teletype result: it sets a known
 * cursor, teletypes "Hi!", reads the three cells back via AH=08 (read char+attr at
 * cursor) and prints them, and prints the advanced cursor column — all of which are
 * deterministic guest-observable BDA + text-cell values, oracle-able on both.
 *
 * Only oracle-able values are printed (the mode triple, the cursor round-trips,
 * the shape word, the teletyped chars + advanced cursor). No files are created.
 */
#include <stdio.h>
#include <dos.h>

/* AH=0F get video mode -> mode(AL), cols(AH), page(BH). */
static void get_mode(unsigned *mode, unsigned *cols, unsigned *page)
{
    union REGS r;
    r.h.ah = 0x0F;
    int86(0x10, &r, &r);
    *mode = r.h.al;
    *cols = r.h.ah;
    *page = r.h.bh;
}

/* AH=02 set cursor (page 0) to row, col. */
static void set_cursor(unsigned char row, unsigned char col)
{
    union REGS r;
    r.h.ah = 0x02;
    r.h.bh = 0x00;          /* page 0 */
    r.h.dh = row;
    r.h.dl = col;
    int86(0x10, &r, &r);
}

/* AH=03 get cursor (page 0) -> row, col, shape(CX). */
static void get_cursor(unsigned *row, unsigned *col, unsigned *shape)
{
    union REGS r;
    r.h.ah = 0x03;
    r.h.bh = 0x00;          /* page 0 */
    int86(0x10, &r, &r);
    *row = r.h.dh;
    *col = r.h.dl;
    *shape = r.x.cx;
}

/* AH=0E teletype one char (page 0). Writes the glyph to the B800 text page and
 * advances the cursor (zdos now models this). */
static void teletype(unsigned char ch)
{
    union REGS r;
    r.h.ah = 0x0E;
    r.h.al = ch;
    r.h.bh = 0x00;          /* page 0 */
    r.h.bl = 0x07;          /* attribute (graphics modes only) */
    int86(0x10, &r, &r);
}

/* AH=08 read the character at cursor (page 0) -> the char byte (AL). */
static unsigned char read_char_at(unsigned char row, unsigned char col)
{
    union REGS r;
    set_cursor(row, col);
    r.h.ah = 0x08;
    r.h.bh = 0x00;          /* page 0 */
    int86(0x10, &r, &r);
    return r.h.al;
}

int main(void)
{
    unsigned mode, cols, page, row, col, shape;

    /* AH=0F: the boot text mode triple. */
    get_mode(&mode, &cols, &page);
    printf("mode=%02X cols=%u page=%u\n", mode, cols, page);

    /* AH=02 set cursor to a known (row,col), AH=03 read it back. */
    set_cursor(5, 10);
    get_cursor(&row, &col, &shape);
    printf("cur1 row=%u col=%u shape=%04X match=%d\n",
           row, col, shape, (row == 5 && col == 10) ? 1 : 0);

    /* A second known position proves it stores what we set (not a fixed echo). */
    set_cursor(20, 40);
    get_cursor(&row, &col, &shape);
    printf("cur2 row=%u col=%u shape=%04X match=%d\n",
           row, col, shape, (row == 20 && col == 40) ? 1 : 0);

    /* Teletype "Hi!" from a known cursor (2,0): the glyphs land in the B800 text
     * page and the cursor advances by 3. Read the three cells back via AH=08 and
     * print them, plus the advanced cursor — all deterministic, oracle-able. */
    set_cursor(2, 0);
    teletype('H');
    teletype('i');
    teletype('!');
    get_cursor(&row, &col, &shape);
    {
        unsigned char c0 = read_char_at(2, 0);
        unsigned char c1 = read_char_at(2, 1);
        unsigned char c2 = read_char_at(2, 2);
        printf("after_tty row=%u col=%u cells=%c%c%c\n", row, col, c0, c1, c2);
    }

    return 0;
}
