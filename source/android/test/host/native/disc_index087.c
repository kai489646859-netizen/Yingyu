#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "disc_seek_index.h"

static int passed;
#define CHECK(name, condition) do { if (!(condition)) { fprintf(stderr, "FAIL %s\n", name); exit(1); } printf("PASS %s\n", name); passed++; } while (0)
int main(void)
{
    const char *index = "YI1|session-1|00001,4113,10000,0:0,90000:100,180000:200,270000:300,360000:400";
    const char *url = "yingyu-disc://session-1/clip/00001.m2ts";
    int64_t pos = -1;
    CHECK("real access point before exact target", yd_index_offset(index, url, 4113, 1920000, 3.5, &pos) && pos == 38400);
    CHECK("one second preroll at exact point", yd_index_offset(index, url, 4113, 1920000, 3, &pos) && pos == 38400);
    CHECK("beginning decodes from actual file start", yd_index_offset(index, url, 4113, 1920000, 0, &pos) && pos == 0);
    CHECK("past indexed coverage retains existing seek", !yd_index_offset(index, url, 4113, 1920000, 8, &pos));
    CHECK("different session rejected", !yd_index_offset(index, "yingyu-disc://session-2/clip/00001.m2ts", 4113, 1920000, 3, &pos));
    CHECK("different PID rejected", !yd_index_offset(index, url, 4114, 1920000, 3, &pos));
    CHECK("different file size rejected", !yd_index_offset(index, url, 4113, 1920001, 3, &pos));
    CHECK("ordinary source untouched", !yd_index_offset(index, "https://example.invalid/00001.m2ts", 4113, 1920000, 3, &pos));
    CHECK("different clip rejected", !yd_index_offset(index, "yingyu-disc://session-1/clip/00002.m2ts", 4113, 1920000, 3, &pos));
    CHECK("nonfinite target rejected", !yd_index_offset(index, url, 4113, 1920000, NAN, &pos));
    CHECK("negative target rejected", !yd_index_offset(index, url, 4113, 1920000, -1, &pos));
    CHECK("missing index rejected", !yd_index_offset(NULL, url, 4113, 1920000, 3, &pos));
    const char *beginning = "YI1|session-1|00001,4113,10000,54000000:4096,54045000:4200,54900000:5000";
    CHECK("nonzero first PTS and bounded prefix decode from byte zero", yd_index_offset(beginning, url, 4113, 1920000, 600, &pos) && pos == 0);
    CHECK("within first second ignores nonzero access-point offset", yd_index_offset(beginning, url, 4113, 1920000, 600.75, &pos) && pos == 0);
    CHECK("immediately before one second still decodes whole prefix", yd_index_offset(beginning, url, 4113, 1920000, 600.999999, &pos) && pos == 0);
    CHECK("one second boundary uses existing full-preroll point", yd_index_offset(beginning, url, 4113, 1920000, 601, &pos) && pos == 4096 * 192);
    CHECK("later target uses normal index point", yd_index_offset(beginning, url, 4113, 1920000, 602, &pos) && pos == 4200 * 192);
    CHECK("codec padding before first PTS still reads full file head", yd_index_offset(beginning, url, 4113, 1920000, 599.75, &pos) && pos == 0);
    CHECK("one second before first PTS reads full file head", yd_index_offset(beginning, url, 4113, 1920000, 599, &pos) && pos == 0);
    CHECK("over one second before first PTS remains timestamp search", !yd_index_offset(beginning, url, 4113, 1920000, 598.999999, &pos));
    const char *far_beginning = "YI1|session-1|00001,4113,10000,54000000:4097,54900000:5000";
    CHECK("prefix one packet beyond bound rejects beginning shortcut", !yd_index_offset(far_beginning, url, 4113, 1920000, 600.5, &pos));
    CHECK("large prefix still permits an ordinary preroll point", yd_index_offset(far_beginning, url, 4113, 1920000, 601.5, &pos) && pos == 4097 * 192);
    CHECK("beginning beyond final point remains timestamp search", !yd_index_offset("YI1|session-1|00001,4113,10000,54000000:1,54022500:2", url, 4113, 1920000, 600.5, &pos));
    CHECK("beginning still rejects different session", !yd_index_offset(beginning, "yingyu-disc://session-2/clip/00001.m2ts", 4113, 1920000, 600.5, &pos));
    CHECK("beginning still rejects different PID", !yd_index_offset(beginning, url, 4114, 1920000, 600.5, &pos));
    CHECK("beginning still rejects different size", !yd_index_offset(beginning, url, 4113, 1920001, 600.5, &pos));
    CHECK("beginning still rejects wrong clip", !yd_index_offset(beginning, "yingyu-disc://session-1/clip/00002.m2ts", 4113, 1920000, 600.5, &pos));
    CHECK("beginning still rejects ordinary URL", !yd_index_offset(beginning, "https://example.invalid/00001.m2ts", 4113, 1920000, 600.5, &pos));
    CHECK("beginning validates subsequent index blocks", !yd_index_offset("YI1|session-1|00001,4113,10000,54000000:8,54900000:100|00002,0,10000,0:0,90000:1", url, 4113, 1920000, 600.5, &pos));
    CHECK("beginning still rejects duplicate clip index", !yd_index_offset("YI1|session-1|00001,4113,10000,54000000:8,54900000:100|00001,4113,10000,54000000:8,54900000:100", url, 4113, 1920000, 600.5, &pos));
    const char *bad[] = {
        "YI1|session-1|00001,4113,10000,0:0,180000:200,90000:300",
        "YI1|session-1|00001,4113,10000,0:0,90000:200,180000:100",
        "YI1|session-1|00001,4113,10000,0:0,90000:10000",
        "YI1|session-1|00001,4113,10000,0:0",
        "YI1|session-1|00001,4113,10000,0:0,90000:1|",
        "YI1|session-1|00001,4113,10000,0:0,18446744073709551616:1",
        "YI1|session-1|00001,4113,10000,0:0,90000:100,360000:300|00001,4113,10000,0:0,90000:100,360000:300",
        "YI1|session-1|00001,4113,10000,0:0,90000:100,360000:300|00002,0,10000,0:0,90000:1",
        "YI1|session-1|00001,4113,10000,0:0,90000:",
        "YI1|session-1|00001,4113,10000,",
    };
    for (unsigned i = 0; i < sizeof(bad) / sizeof(*bad); i++) {
        char name[64]; snprintf(name, sizeof(name), "malformed or ambiguous index %u", i);
        CHECK(name, !yd_index_offset(bad[i], url, 4113, 1920000, 3, &pos));
    }
    CHECK("later clip in same playlist", yd_index_offset("YI1|session-1|00002,4113,10000,0:0,360000:300|00001,4113,10000,0:0,90000:100,360000:300", url, 4113, 1920000, 3, &pos) && pos == 19200);
    // Every truncation boundary must reject cleanly; never scan beyond NUL.
    for (size_t n = 0; n < strlen(index); n++) {
        char *prefix = malloc(n + 1); memcpy(prefix, index, n); prefix[n] = 0;
        (void)yd_index_offset(prefix, url, 4113, 1920000, 3, &pos); free(prefix);
    }
    CHECK("all truncated inputs return safely", true);
    printf("SUMMARY passed=%d failed=0\n", passed);
    return 0;
}
