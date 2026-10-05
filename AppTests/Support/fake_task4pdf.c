// Stand-in for CTask4PDF/task4pdf.c's t4_replace, compiled into the
// NullmarkTests bundle and never into the app, so EditorModel runs without
// linking MuPDF.
#include "task4pdf.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { DECIMAL = 10, MICROSECONDS_PER_MS = 1000 };

// Sleeps for T4_FAKE_DELAY_MS milliseconds when `find` equals T4_FAKE_DELAY_ON,
// so a test can make one call outlast another.
int t4_replace(const char *in_path, const char *out_path, const char *find, const char *replace,
               T4Result *out) {
    (void)in_path;
    (void)replace;
    memset(out, 0, sizeof(*out));

    const char *delay_on = getenv("T4_FAKE_DELAY_ON");
    const char *delay_ms = getenv("T4_FAKE_DELAY_MS");
    if (delay_on != NULL && delay_ms != NULL && strcmp(find, delay_on) == 0) {
        char *end = NULL;
        errno = 0;
        long ms = strtol(delay_ms, &end, DECIMAL);
        if (errno != 0 || *end != '\0' || ms < 0) {
            snprintf(out->error, sizeof(out->error),
                     "fake_task4pdf: T4_FAKE_DELAY_MS is not a non-negative integer: %s", delay_ms);
            return 1;
        }
        usleep((useconds_t)(ms * MICROSECONDS_PER_MS));
    }

    FILE *f = fopen(out_path, "wb");
    if (f == NULL) {
        snprintf(out->error, sizeof(out->error), "fake_task4pdf: could not open %s", out_path);
        return 1;
    }
    int put_failed = fputs("fake", f) == EOF;
    if (fclose(f) != 0 || put_failed) {
        snprintf(out->error, sizeof(out->error), "fake_task4pdf: could not write %s", out_path);
        return 1;
    }
    return 0;
}
