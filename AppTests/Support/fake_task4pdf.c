// Stand-in for CTask4PDF/task4pdf.c's t4_replace, compiled into the
// NullmarkTests XCTest bundle (never into the app) so EditorModel's own code
// can be exercised without linking MuPDF.
#include "task4pdf.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Sleeps for T4_FAKE_DELAY_MS milliseconds before returning when `find`
// equals T4_FAKE_DELAY_ON, so a test can make one call outlast another and
// observe which result EditorModel keeps.
int t4_replace(const char *in_path, const char *out_path, const char *find, const char *replace,
               T4Result *out) {
    (void)in_path;
    (void)replace;
    memset(out, 0, sizeof(*out));

    const char *delay_on = getenv("T4_FAKE_DELAY_ON");
    if (delay_on != NULL && strcmp(find, delay_on) == 0) {
        const char *ms = getenv("T4_FAKE_DELAY_MS");
        if (ms != NULL) {
            usleep((useconds_t)(atoi(ms) * 1000));
        }
    }

    FILE *f = fopen(out_path, "wb");
    if (f == NULL) {
        snprintf(out->error, sizeof(out->error), "fake_task4pdf: could not open %s", out_path);
        return 1;
    }
    fputs("fake", f);
    fclose(f);

    out->matches = 0;
    out->pages_changed = 0;
    out->residual = 0;
    return 0;
}
