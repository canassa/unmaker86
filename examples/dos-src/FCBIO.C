/* FCBIO — the legacy FCB (File Control Block) file API (INT 21h AH=0F-24).
 *
 * The FCB interface predates the handle-based calls (AH=3C-42): the program
 * builds a 37-byte File Control Block in its own memory, points DS:DX at it, and
 * the DOS calls read/write the FCB fields in place. Borland exposes no wrappers
 * for these, so we drive them directly with intdosx (DS:DX = &fcb).
 *
 * Covered (cite dosbox-x dos_files.cpp DOS_FCB*):
 *   AH=16 FCB Create              DOS_FCBCreate     (dos_files.cpp:1831)
 *   AH=15 Sequential Write        DOS_FCBWrite      (dos_files.cpp:1947)
 *   AH=10 FCB Close               DOS_FCBClose      (dos_files.cpp:1887)
 *   AH=0F FCB Open                DOS_FCBOpen       (dos_files.cpp:1849)
 *   AH=14 Sequential Read         DOS_FCBRead       (dos_files.cpp:1917)
 *   AH=24 Set Random Record       DOS_FCBSetRandomRecord (dos_files.cpp:2223)
 *   AH=21 Random Read             DOS_FCBRandomRead (dos_files.cpp:2012)
 *   AH=22 Random Write            DOS_FCBRandomWrite(dos_files.cpp:2044)
 *   AH=23 Get File Size           DOS_FCBGetFileSize(dos_files.cpp:2075)
 *   AH=11 FCB Find First          DOS_FCBFindFirst  (dos_files.cpp:1896)
 *   AH=12 FCB Find Next           DOS_FCBFindNext   (dos_files.cpp:1908)
 *   AH=13 FCB Delete (wildcards)  DOS_FCBDeleteFile (dos_files.cpp:2094)
 *   AH=17 FCB Rename              DOS_FCBRenameFile (dos_files.cpp:2156)
 *
 * FCB read/write move the record bytes through the CURRENT DTA (AH=1A set it):
 * AH=14/21 read a record FROM the file INTO the DTA; AH=15/22 write a record
 * FROM the DTA TO the file, both at offset recno*rec_size in the DTA.
 *
 * DETERMINISM: the FCB date/time words (offsets +0x14/+0x16) and the find-result
 * FCB's date/time (offsets +0x17/+0x19 of the DTA FCB) are derived by dosbox-x
 * from the HOST clock (DOS_FCBWrite: DOS_PackDate(dos.date...) + BIOS_TIMER) and
 * are NOT printed/asserted. Oracle-able: record CONTENT, byte/record COUNTS,
 * file SIZE (FCB filesize +0x10), the file-size-in-records the random field gets
 * from AH=23, found-file SIZE, and all AL return codes. Proven deterministic by a
 * double-mint diff. Every file the program creates is removed before exit.
 */
#include <stdio.h>
#include <string.h>
#include <dos.h>

/* The 37-byte unopened (normal) FCB, byte-accurate to dosbox-x sFCB
 * (include/dos_inc.h:746). We lay it out as a packed-ish struct; BC packs these
 * naturally because every field is byte/word/dword aligned in order. */
struct myfcb {
    unsigned char  drive;        /* +0x00  0=default, 1=A, ... */
    unsigned char  name[8];      /* +0x01  space-padded name   */
    unsigned char  ext[3];       /* +0x09  space-padded ext    */
    unsigned int   cur_block;    /* +0x0C  current block       */
    unsigned int   rec_size;     /* +0x0E  logical record size */
    unsigned long  filesize;     /* +0x10  file size in bytes  */
    unsigned int   date;         /* +0x14  (host-derived)      */
    unsigned int   time;         /* +0x16  (host-derived)      */
    unsigned char  reserved[8];  /* +0x18  sft/share/handle... */
    unsigned char  cur_rec;      /* +0x20  current record      */
    unsigned long  rndm;         /* +0x21  random record #     */
};

/* The DTA: FCB read/write transfer record bytes here. 128 = our chosen record
 * size, sized so file-size math is exact and oracle-able. */
#define RECSZ 32
static unsigned char dta[256];

/* Fill an FCB name/ext field from an 8.3 string (space-padded, uppercase). */
static void set_name(struct myfcb *f, const char *fn, const char *ex)
{
    int i;
    int done;
    f->drive = 0;                 /* default drive */
    /* Space-pad: copy until the source NUL, then fill the rest with spaces.
     * (Must NOT index past the NUL into adjacent storage.) */
    for (i = 0, done = 0; i < 8; i++) {
        if (!done && fn[i] == '\0') done = 1;
        f->name[i] = (unsigned char)(done ? ' ' : fn[i]);
    }
    for (i = 0, done = 0; i < 3; i++) {
        if (!done && ex[i] == '\0') done = 1;
        f->ext[i] = (unsigned char)(done ? ' ' : ex[i]);
    }
    f->cur_block = 0;
    f->rec_size  = 0;             /* DOS defaults to 128 on first I/O */
    f->cur_rec   = 0;
    f->rndm      = 0;
}

/* INT 21h with DS:DX -> fcb; returns AL. */
static unsigned char fcb_call(unsigned char ah, struct myfcb *f)
{
    union REGS r;
    struct SREGS s;
    segread(&s);
    r.h.ah = ah;
    r.x.dx = FP_OFF(f);
    s.ds   = FP_SEG(f);
    intdosx(&r, &r, &s);
    return r.h.al;
}

/* Set the DTA address (AH=1A). */
static void set_dta(void *p)
{
    union REGS r;
    struct SREGS s;
    segread(&s);
    r.h.ah = 0x1a;
    r.x.dx = FP_OFF(p);
    s.ds   = FP_SEG(p);
    intdosx(&r, &r, &s);
}

int main(void)
{
    struct myfcb f;
    unsigned char al;
    int i, rec;

    set_dta(dta);

    /* ---- AH=16 Create + AH=15 sequential write of 3 records ---- */
    set_name(&f, "FCBDATA", "DAT");
    al = fcb_call(0x16, &f);
    printf("create al=%u\n", al);                  /* 0 = ok */
    f.rec_size = RECSZ;                             /* set record size after open */

    for (rec = 0; rec < 3; rec++) {
        memset(dta, 0, RECSZ);
        sprintf((char *)dta, "record-%d-payload", rec);
        al = fcb_call(0x15, &f);                    /* AH=15 seq write rec */
        printf("seqwrite rec %d al=%u\n", rec, al); /* 0 = ok */
    }
    printf("filesize after writes: %lu\n", f.filesize);

    al = fcb_call(0x10, &f);                        /* AH=10 close */
    printf("close al=%u\n", al);

    /* ---- AH=0F Open + AH=14 sequential read back ---- */
    set_name(&f, "FCBDATA", "DAT");
    al = fcb_call(0x0f, &f);                        /* AH=0F open */
    printf("open al=%u\n", al);
    printf("open filesize: %lu\n", f.filesize);     /* FileOpen seeds size */
    f.rec_size = RECSZ;

    for (rec = 0; rec < 3; rec++) {
        memset(dta, 0, RECSZ);
        al = fcb_call(0x14, &f);                    /* AH=14 seq read rec */
        printf("seqread rec %d al=%u [%s]\n", rec, al, (char *)dta);
    }
    /* A read past EOF returns AL=1 (no data). */
    al = fcb_call(0x14, &f);
    printf("seqread past-eof al=%u\n", al);

    /* ---- AH=24 Set Random Record + AH=21 Random Read ---- */
    /* Point at record 1 sequentially, then AH=24 converts cur_block/cur_rec into
     * the random-record field. */
    f.cur_block = 0; f.cur_rec = 1;
    fcb_call(0x24, &f);                             /* AH=24 set random record */
    printf("random field after set(rec1): %lu\n", f.rndm);
    memset(dta, 0, RECSZ);
    al = fcb_call(0x21, &f);                        /* AH=21 random read */
    printf("randread al=%u [%s]\n", al, (char *)dta);

    /* ---- AH=22 Random Write at record 1 (overwrite) ---- */
    f.rndm = 1;                                     /* target record 1 */
    memset(dta, 0, RECSZ);
    strcpy((char *)dta, "REWRITTEN-REC-1");
    al = fcb_call(0x22, &f);                        /* AH=22 random write */
    printf("randwrite al=%u\n", al);

    /* Read it back via random read to confirm the overwrite landed. */
    f.rndm = 1;
    memset(dta, 0, RECSZ);
    al = fcb_call(0x21, &f);
    printf("randread after rewrite al=%u [%s]\n", al, (char *)dta);

    al = fcb_call(0x10, &f);                        /* close */
    printf("close2 al=%u\n", al);

    /* ---- AH=23 Get File Size (in records) ---- */
    set_name(&f, "FCBDATA", "DAT");
    f.rec_size = RECSZ;
    al = fcb_call(0x23, &f);                        /* AH=23 get file size */
    printf("getsize al=%u records=%lu\n", al, f.rndm);

    /* ---- AH=11/12 Find First / Find Next with a wildcard ---- */
    /* Create a couple more matching files first (via FCB create, empty). */
    set_name(&f, "FCBONE", "DAT");  fcb_call(0x16, &f); fcb_call(0x10, &f);
    set_name(&f, "FCBTWO", "DAT");  fcb_call(0x16, &f); fcb_call(0x10, &f);

    /* Find all FCB*.DAT. The found-FCB lands in the DTA at offset 0; we read its
     * 8.3 name (DTA+1..+11) and its size (DTA+0x10..0x13). NOT the date/time. */
    set_name(&f, "FCB?????", "DAT");               /* '?' wildcards */
    {
        int count = 0;
        al = fcb_call(0x11, &f);                    /* AH=11 find first */
        while (al == 0) {
            char nm[13];
            unsigned long sz;
            int j, k = 0;
            for (j = 0; j < 8; j++) if (dta[1 + j] != ' ') nm[k++] = dta[1 + j];
            nm[k++] = '.';
            for (j = 0; j < 3; j++) if (dta[9 + j] != ' ') nm[k++] = dta[9 + j];
            nm[k] = '\0';
            /* The find-result FCB stores SIZE at +0x1D (DOS_FCB::SetResult,
             * dos_classes.cpp:699), NOT the unopened-FCB filesize field at +0x10
             * (that one stays 0 in a find result). Date/time at +0x17/+0x19 are
             * host-derived and deliberately NOT read. */
            sz = *(unsigned long *)(dta + 0x1d);
            printf("found: %s size=%lu\n", nm, sz);
            count++;
            al = fcb_call(0x12, &f);               /* AH=12 find next */
        }
        printf("find count=%d\n", count);
    }

    /* ---- AH=17 Rename (FCB): the rename FCB packs OLD at +0, NEW at +0x10 ---- */
    /* Build a combined buffer: a normal FCB whose first 16 bytes are the old
     * name's drive+name+ext region and bytes +0x10.. hold the new name. dosbox-x
     * reads NEW from FCB base + 0x10 (DOS_FCBRenameFile SetPtPhys+0x10). */
    {
        unsigned char ren[64];
        memset(ren, 0, sizeof(ren));
        /* OLD at +0x00 */
        ren[0] = 0;                                 /* default drive */
        memcpy(ren + 1, "FCBONE  ", 8);
        memcpy(ren + 9, "DAT", 3);
        /* NEW at +0x10 (drive byte + name + ext) */
        ren[0x10] = 0;
        memcpy(ren + 0x11, "FCBREN  ", 8);
        memcpy(ren + 0x19, "DAT", 3);
        {
            union REGS r; struct SREGS s;
            segread(&s);
            r.h.ah = 0x17;
            r.x.dx = FP_OFF(ren);
            s.ds   = FP_SEG(ren);
            intdosx(&r, &r, &s);
            printf("rename al=%u\n", r.h.al);       /* 0 = ok */
        }
    }

    /* ---- AH=13 Delete with a wildcard (removes all FCB*.DAT incl. renamed) ---- */
    set_name(&f, "FCB?????", "DAT");
    al = fcb_call(0x13, &f);                        /* AH=13 delete (wildcard) */
    printf("delete-wild al=%u\n", al);

    /* Verify they are gone: a find-first now finds nothing. */
    set_name(&f, "FCB?????", "DAT");
    al = fcb_call(0x11, &f);
    printf("find-after-delete al=%u\n", al);        /* 0xFF = none */

    printf("done\n");
    return 0;
}
