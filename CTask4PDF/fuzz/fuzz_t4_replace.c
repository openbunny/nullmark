// libFuzzer harness for t4_replace: the entry point that ingests an untrusted
// PDF. Each input is written to a temp file and run through t4_replace with a
// fixed find/replace pair; both temp files are removed every iteration. A crash,
// sanitizer report or non-graceful exit here is a defect in task4pdf.c to fix,
// never a reason to weaken this harness.
//
// A successful run (rc==0, residual==0) is also re-scanned here for the raw
// "OLDNAME" needle, independently of task4pdf.c's own verify_residual: rc and
// residual are t4_replace's only success oracle, and a false negative in
// verify_residual itself would otherwise go undetected by this harness, which
// until now only fuzzed for crashes. This re-scan checks raw bytes only, not
// decompressed streams, so it cannot see a needle hidden inside a compressed
// stream that verify_residual's own decompressing scan would still catch.
#include "task4pdf.h"

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { PATH_CAP = 4096, SCAN_CHUNK = 65536 };

static int make_temp(char *buf, const char *tag) {
    const char *dir = getenv("TMPDIR");
    if (dir == NULL || dir[0] == '\0') {
        dir = "/tmp";
    }
    snprintf(buf, PATH_CAP, "%s/t4_fuzz_%s_XXXXXX", dir, tag);
    return mkstemp(buf);
}

// Scans `path`'s raw bytes for the fixed needle "OLDNAME" in fixed-size
// chunks, carrying the last (needle length - 1) bytes of each chunk forward
// so an occurrence straddling a chunk boundary is still found. Aborts (a
// libFuzzer crash, with the input saved as the reproducer) if the needle is
// present, since the caller only reaches here when t4_replace itself reported
// success with zero residual.
static void abort_if_needle_survives(const char *path) {
    static const char needle[] = "OLDNAME";
    enum { NEEDLE_LEN = sizeof(needle) - 1 };
    FILE *f = fopen(path, "rb");
    if (!f) {
        return;
    }
    unsigned char window[(NEEDLE_LEN - 1) + SCAN_CHUNK];
    unsigned char chunk[SCAN_CHUNK];
    size_t carry = 0;
    size_t got;
    while ((got = fread(chunk, 1, SCAN_CHUNK, f)) > 0) {
        memcpy(window + carry, chunk, got);
        size_t avail = carry + got;
        for (size_t i = 0; i + NEEDLE_LEN <= avail; i++) {
            if (memcmp(window + i, needle, NEEDLE_LEN) == 0) {
                fclose(f);
                fprintf(stderr, "fuzz_t4_replace: t4_replace reported rc=0 residual=0 but the "
                                "raw output still contains the needle (independent re-scan, "
                                "not reusing verify_residual)\n");
                abort();
            }
        }
        carry = avail >= (size_t)(NEEDLE_LEN - 1) ? (size_t)(NEEDLE_LEN - 1) : avail;
        memmove(window, window + avail - carry, carry);
    }
    fclose(f);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    char in_path[PATH_CAP];
    char out_path[PATH_CAP];
    int in_fd = make_temp(in_path, "in");
    if (in_fd < 0) {
        return 0;
    }
    int out_fd = make_temp(out_path, "out");
    if (out_fd < 0) {
        close(in_fd);
        remove(in_path);
        return 0;
    }
    close(out_fd);

    int wrote_ok = size == 0 || (size_t)write(in_fd, data, size) == size;
    close(in_fd);
    if (wrote_ok) {
        T4Result r;
        int rc = t4_replace(in_path, out_path, "OLDNAME", "NEWNAME", &r);
        if (rc == 0 && r.residual == 0) {
            abort_if_needle_survives(out_path);
        }
    }
    remove(in_path);
    remove(out_path);
    return 0;
}
