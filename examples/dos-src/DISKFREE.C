/* DISKFREE — INT 21h AH=36 get-free-disk-space via Borland's getdfree(). Prints
 * cluster geometry (sectors/cluster, bytes/sector, total clusters) and free
 * clusters. PROVISIONAL: only kept in the corpus if dosbox-x mints a stable
 * (byte-identical-across-two-mints) golden; free space may be host-dependent. */
#include <stdio.h>
#include <dos.h>

int main(void)
{
    struct dfree df;

    getdfree(0, &df);            /* 0 = current drive */
    if (df.df_sclus == 0xFFFF) { printf("FAIL: getdfree\n"); return 1; }

    printf("sectors_per_cluster=%u\n", df.df_sclus);
    printf("bytes_per_sector=%u\n", df.df_bsec);
    printf("total_clusters=%u\n", df.df_total);
    printf("avail_clusters=%u\n", df.df_avail);
    return 0;
}
