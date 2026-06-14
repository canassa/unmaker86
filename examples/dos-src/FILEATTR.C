/* FILEATTR — file ATTRIBUTES + exclusive create (INT 21h AH=43 / AH=5B).
 *
 * Band 11. Exercises:
 *   _dos_getfileattr  -> INT 21h AH=43 AL=00 (get attributes -> CX)
 *   _dos_setfileattr  -> INT 21h AH=43 AL=01 (set attributes  <- CX)
 *   _dos_creatnew     -> INT 21h AH=5B       (exclusive / create-new; EEXIST
 *                                             if the name already exists)
 *
 * On a mounted LOCAL drive dosbox-x reports DOS attributes from the host inode
 * (drive_local.cpp localDrive::GetFileAttr, non-WIN32 path): a regular file is
 * ARCHIVE (0x20), plus READ_ONLY (0x01) iff the owner write bit is clear. SET
 * (localDrive::SetFileAttr) chmods the owner write bit per the READ_ONLY bit, so
 * a SET-then-GET round-trips. These bits are a function of the inode, not of
 * host wall-clock time, so they are fully oracle-able (proven by a double-mint
 * diff). File TIMESTAMPS are NOT printed (dosbox-x derives those from host
 * mtime — non-deterministic; see plans/dos-oracle-report.md).
 *
 * Every file this program creates is removed before it exits, so the committed
 * corpus directory stays byte-identical (corpus-hygiene hard rule).
 *
 * dos.cpp:2212 (AH=43): GET -> CX=attr, AX=attr (undocumented), CF clear; on
 * error CF set, AX=errorcode. SET -> AX=0x0202, CF clear.
 * dos.cpp:2550 (AH=5B): if the file opens (exists) -> close it, set
 * DOSERR_FILE_ALREADY_EXISTS (80), CF set, AX=80; else create -> AX=handle.
 */
#include <stdio.h>
#include <dos.h>
#include <io.h>

#define AFILE "ATTRTEST.DAT"
#define BFILE "EXCLNEW.DAT"

int main(void)
{
    unsigned ret, attr;
    int fd;

    /* --- create a file and seed it with a few bytes --- */
    ret = _dos_creat(AFILE, _A_NORMAL, &fd);
    if (ret) { printf("FAIL: creat ret=%u\n", ret); return 1; }
    _dos_write(fd, "attr", 4, &attr);
    _dos_close(fd);

    /* --- AH=43 AL=00: initial attributes (a fresh writable file: ARCHIVE) --- */
    ret = _dos_getfileattr(AFILE, &attr);
    if (ret) { printf("FAIL: getattr1 ret=%u\n", ret); return 2; }
    printf("attr.initial=%02X\n", attr);

    /* --- AH=43 AL=01: set READ_ONLY (preserving ARCHIVE) --- */
    ret = _dos_setfileattr(AFILE, _A_RDONLY | _A_ARCH);
    if (ret) { printf("FAIL: setattr ro ret=%u\n", ret); return 3; }

    /* --- AH=43 AL=00: confirm the READ_ONLY bit took --- */
    ret = _dos_getfileattr(AFILE, &attr);
    if (ret) { printf("FAIL: getattr2 ret=%u\n", ret); return 4; }
    printf("attr.readonly=%02X\n", attr);

    /* --- a read-only file must NOT open for writing (AH=3D AL=01) --- */
    ret = _dos_open(AFILE, 1, &fd);   /* DOS access mode 1 = write-only */
    if (ret) {
        printf("write-open denied ax=%u\n", ret);
    } else {
        printf("write-open ALLOWED\n");
        _dos_close(fd);
    }

    /* --- clear READ_ONLY again --- */
    ret = _dos_setfileattr(AFILE, _A_ARCH);
    if (ret) { printf("FAIL: setattr rw ret=%u\n", ret); return 5; }
    ret = _dos_getfileattr(AFILE, &attr);
    if (ret) { printf("FAIL: getattr3 ret=%u\n", ret); return 6; }
    printf("attr.cleared=%02X\n", attr);

    /* now the file opens for writing again --- */
    ret = _dos_open(AFILE, 1, &fd);
    if (ret) { printf("FAIL: write-open after clear ret=%u\n", ret); return 7; }
    _dos_close(fd);
    printf("write-open ok after clear\n");

    /* --- AH=5B exclusive create: a NEW name succeeds --- */
    ret = _dos_creatnew(BFILE, _A_NORMAL, &fd);
    if (ret) { printf("FAIL: creatnew first ret=%u\n", ret); return 8; }
    _dos_close(fd);
    printf("creatnew ok\n");

    /* --- AH=5B again on the SAME name: must fail EEXIST (80) --- */
    ret = _dos_creatnew(BFILE, _A_NORMAL, &fd);
    if (!ret) {
        printf("FAIL: creatnew second unexpectedly succeeded\n");
        _dos_close(fd);
        return 9;
    }
    printf("creatnew dup denied ax=%u\n", ret);

    /* --- AH=43 AL=00 on a missing file: error (file-not-found) --- */
    ret = _dos_getfileattr("NOSUCH.ZZZ", &attr);
    printf("getattr missing ret=%u\n", ret);

    /* --- corpus hygiene: remove everything we created --- */
    remove(AFILE);
    remove(BFILE);
    return 0;
}
