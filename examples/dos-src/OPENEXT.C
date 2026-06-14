/* OPENEXT — extended open/create + access-mode enforcement.
 *
 * Band 12. Exercises the combined open-or-create call and the AH=3D access
 * mode:
 *
 *   INT 21h AH=6C  Extended Open/Create (dos.cpp:3002 -> DOS_OpenFileExtended,
 *                  dos_files.cpp:1138). Filename at DS:SI (NOT DS:DX),
 *                  BX = access/sharing flags, CX = create attributes,
 *                  DX = action (low nibble = if-exists 0/1/2 = fail/open/replace,
 *                  high nibble = if-not-exists 0x00/0x10 = fail/create).
 *                  On success: CF clear, AX = handle, CX = action taken
 *                  (1 = opened, 2 = created, 3 = truncated/replaced).
 *                  On failure: CF set, AX = error code.
 *
 *   INT 21h AH=3D  access mode (_dos_open mode byte): 0 = read-only,
 *                  1 = write-only, 2 = read-write. dosbox-x enforces the access
 *                  mode at the FILE-object level: LocalFile::Write returns
 *                  DOSERR_ACCESS_DENIED (5) when the file was opened OPEN_READ
 *                  (drive_local.cpp:2819-2824). (The DTA-layer check in
 *                  DOS_ReadFile/DOS_WriteFile is commented out, dos_files.cpp:
 *                  824/858 — the live check is the per-file one.) So: open a file
 *                  O_RDONLY, attempt a write -> the WRITE fails with access
 *                  denied; the open itself succeeds.
 *
 * Only oracle-able values are printed: action codes, error codes, file sizes,
 * byte counts. NO timestamps (those are host-mtime derived; not oracle-able).
 *
 * Every file this program creates is removed before it exits so the committed
 * corpus stays byte-identical (corpus-hygiene hard rule).
 */
#include <stdio.h>
#include <dos.h>
#include <io.h>
#include <fcntl.h>

#define XFILE "OPENEXT.DAT"

/* Action low-nibble (if-exists) values. */
#define ACT_FAIL_EXIST   0x00
#define ACT_OPEN_EXIST   0x01
#define ACT_REPLACE      0x02
/* Action high-nibble (if-not-exists) values. */
#define ACT_FAIL_NEW     0x00
#define ACT_CREATE_NEW   0x10

/* AH=6C extended open/create. Returns 0 on success (and stores the handle in
 * *handle and the action taken in *taken); on failure returns the DOS error
 * code (CF set). Filename goes in DS:SI. */
static unsigned ext_open(char *name, unsigned access, unsigned attr,
                         unsigned action, unsigned *handle, unsigned *taken)
{
    union REGS r;
    struct SREGS s;

    segread(&s);                 /* DS/ES = our data segment (small model) */
    r.h.ah = 0x6C;
    r.x.bx = access;
    r.x.cx = attr;
    r.x.dx = action;
    r.x.si = (unsigned)name;     /* DS:SI -> filename */
    intdosx(&r, &r, &s);
    if (r.x.cflag) return r.x.ax; /* error code */
    *handle = r.x.ax;
    *taken  = r.x.cx;
    return 0;
}

int main(void)
{
    unsigned ret, handle, taken, nbytes;

    /* --- 6C open-existing on a NONEXISTENT file: action = open-only
     *     (if-not-exists = fail) -> must fail with file-not-found (2). --- */
    remove(XFILE);   /* make sure it's absent */
    ret = ext_open(XFILE, 0 /*O_RDONLY*/, 0,
                   ACT_OPEN_EXIST | ACT_FAIL_NEW, &handle, &taken);
    printf("open-missing ret=%u\n", ret);

    /* --- 6C create-if-missing (if-not-exists = create) -> CX = 2 (created). --- */
    ret = ext_open(XFILE, 2 /*O_RDWR*/, _A_NORMAL,
                   ACT_OPEN_EXIST | ACT_CREATE_NEW, &handle, &taken);
    if (ret) { printf("FAIL: create ret=%u\n", ret); return 1; }
    printf("create taken=%u\n", taken);
    /* seed it with some bytes so a later truncate is observable by size */
    _dos_write(handle, "hello-extended", 14, &nbytes);
    printf("wrote=%u\n", nbytes);
    _dos_close(handle);

    /* --- 6C on the now-existing file, if-exists = open -> CX = 1 (opened). --- */
    ret = ext_open(XFILE, 2, _A_NORMAL,
                   ACT_OPEN_EXIST | ACT_CREATE_NEW, &handle, &taken);
    if (ret) { printf("FAIL: reopen ret=%u\n", ret); return 2; }
    printf("reopen taken=%u\n", taken);
    /* size via lseek to END (AH=42 AL=02) */
    printf("size.before=%lu\n", filelength(handle));
    _dos_close(handle);

    /* --- 6C with if-exists = replace (truncate) -> CX = 3 (replaced),
     *     and the file is now size 0. --- */
    ret = ext_open(XFILE, 2, _A_NORMAL,
                   ACT_REPLACE | ACT_CREATE_NEW, &handle, &taken);
    if (ret) { printf("FAIL: truncate ret=%u\n", ret); return 3; }
    printf("truncate taken=%u\n", taken);
    printf("size.after=%lu\n", filelength(handle));
    _dos_close(handle);

    /* --- 6C with if-exists = fail on the EXISTING file -> error 80 (exists). --- */
    ret = ext_open(XFILE, 0, _A_NORMAL,
                   ACT_FAIL_EXIST | ACT_CREATE_NEW, &handle, &taken);
    printf("fail-if-exists ret=%u\n", ret);

    /* --- 6C invalid action (action == 0 always fails) -> error 1. --- */
    ret = ext_open(XFILE, 0, _A_NORMAL, 0x0000, &handle, &taken);
    printf("action-zero ret=%u\n", ret);

    /* --- AH=3D access mode: open O_RDONLY then attempt a WRITE. The OPEN
     *     succeeds; the WRITE is rejected with access-denied (5). --- */
    ret = _dos_open(XFILE, 0 /*O_RDONLY*/, (int *)&handle);
    if (ret) { printf("FAIL: rdonly-open ret=%u\n", ret); return 4; }
    printf("rdonly-open ok\n");
    ret = _dos_write(handle, "x", 1, &nbytes);
    if (ret) {
        printf("rdonly-write denied ret=%u wrote=%u\n", ret, nbytes);
    } else {
        printf("rdonly-write ALLOWED wrote=%u\n", nbytes);
    }
    _dos_close(handle);

    /* a read on the same read-only handle is fine: reopen and read back. */
    ret = _dos_open(XFILE, 0, (int *)&handle);
    if (ret) { printf("FAIL: rdonly-reopen ret=%u\n", ret); return 5; }
    {
        char buf[8];
        ret = _dos_read(handle, buf, 4, &nbytes);
        printf("rdonly-read ret=%u got=%u\n", ret, nbytes);
    }
    _dos_close(handle);

    /* --- corpus hygiene: remove what we created. --- */
    remove(XFILE);
    return 0;
}
