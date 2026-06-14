/* FILEDATE — exercises INT 21h AH=57 (get/set file date & time) via the Borland
 * _dos_getftime / _dos_setftime intrinsics on an OPEN file handle.
 *
 * DETERMINISM BOUNDARY (see plans/dos-oracle-report.md band 9): real DOS (and
 * dosbox-x) implement AH=57 AL=00 (GET) by re-reading the HOST file's mtime
 * (drive_local.cpp LocalFile::UpdateDateTimeFromHost -> fstat), so the words
 * returned by a GET are the host wall-clock time the file was last written — NOT
 * whatever a prior SET stored, and NOT a fixed value. Two oracle mints of a
 * GET-the-returned-words program differ (the host clock advanced). Therefore the
 * GET return VALUE is NOT oracle-able and we deliberately do not print it.
 *
 * What IS deterministic — and what this program asserts — is the CONTROL FLOW:
 *   - the packed words the program itself computes (pure arithmetic),
 *   - that SET (AH=57 AL=01) on a valid handle SUCCEEDS (CF clear),
 *   - that GET (AH=57 AL=00) on a valid handle SUCCEEDS (CF clear),
 *   - that GET (AH=57 AL=00) on an INVALID handle FAILS (CF set -> errno),
 * none of which depend on the host clock. This is the faithful, reproducible
 * slice of the AH=57 surface.
 *
 * The DOS packed formats (re-derived from the documented layout):
 *   time: bits 15-11 hour (0-23), 10-5 minute (0-59), 4-0 second/2
 *   date: bits 15-9  year-1980,   8-5  month (1-12),  4-0 day (1-31) */
#include <stdio.h>
#include <fcntl.h>
#include <io.h>
#include <dos.h>
#include <errno.h>

int main(void)
{
    int handle, rc;
    unsigned setdate, settime, gotdate, gottime;

    /* Pack 1995-03-17 14:22:30 into DOS words (pure arithmetic, deterministic). */
    setdate = (unsigned)(((1995 - 1980) << 9) | (3 << 5) | 17);
    settime = (unsigned)((14 << 11) | (22 << 5) | (30 / 2));
    printf("packed: date=%04X time=%04X\n", setdate, settime);

    /* Create the scratch file via the low-level handle API (AH=3C). */
    if (_dos_creat("FDATE.DAT", _A_NORMAL, &handle) != 0) {
        printf("FAIL: create\n");
        return 1;
    }

    /* SET date+time on the open handle (AH=57 AL=01) -> CF clear on success. */
    rc = _dos_setftime(handle, setdate, settime);
    printf("setftime rc=%d\n", rc);

    /* GET it back on the SAME handle (AH=57 AL=00) -> CF clear on success. The
     * returned words are host-mtime-dependent, so we report only SUCCESS, never
     * the values. */
    rc = _dos_getftime(handle, &gotdate, &gottime);
    printf("getftime rc=%d\n", rc);

    _dos_close(handle);

    /* GET on a now-CLOSED / invalid handle must FAIL (CF set). Borland maps the
     * failure to a nonzero return and sets errno. We print only that it failed,
     * plus errno (EBADF is a fixed CRT constant -> deterministic). */
    rc = _dos_getftime(handle, &gotdate, &gottime);
    printf("getftime(closed) rc=%d errno=%d\n", rc != 0, errno);

    return 0;
}
