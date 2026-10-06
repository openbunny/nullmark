// libFuzzer harness for t4_replace, the entry point that ingests an untrusted
// PDF. A crash or sanitizer report here is a defect in task4pdf.c to fix, never
// a reason to weaken this harness.
//
// An output t4_replace reports as verified (rc 0, residual 0) is re-scanned for the raw
// needle, independently of verify_residual, so a false negative in that scan
// fails the run. The re-scan reads raw bytes only and cannot see a needle inside
// a compressed stream.
#include "task4pdf.h"

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char NEEDLE[] = "OLDNAME";
enum { PATH_CAP = 4096, SCAN_CHUNK = 65536, NEEDLE_LEN = sizeof NEEDLE - 1 };

static int make_temp(char *buf, const char *tag) {
    const char *dir = getenv("TMPDIR");
    if (dir == NULL || dir[0] == '\0') {
        dir = "/tmp";
    }
    int n = snprintf(buf, PATH_CAP, "%s/t4_fuzz_%s_XXXXXX", dir, tag);
    if (n < 0 || n >= PATH_CAP) {
        return -1;
    }
    return mkstemp(buf);
}

// t4_replace removes its own output on failure, so a missing file is expected.
static void remove_temp(const char *path) {
    if (remove(path) != 0 && errno != ENOENT) {
        abort();
    }
}

static void close_or_abort(int fd) {
    if (close(fd) != 0) {
        abort();
    }
}

// Carries the last NEEDLE_LEN - 1 bytes of each chunk forward, so an occurrence
// that straddles a chunk boundary is still found.
static void abort_if_needle_survives(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        abort();
    }
    unsigned char window[(NEEDLE_LEN - 1) + SCAN_CHUNK];
    unsigned char chunk[SCAN_CHUNK];
    size_t carry = 0;
    for (;;) {
        size_t got = fread(chunk, 1, SCAN_CHUNK, f);
        memcpy(window + carry, chunk, got);
        size_t avail = carry + got;
        for (size_t i = 0; i + NEEDLE_LEN <= avail; i++) {
            if (memcmp(window + i, NEEDLE, NEEDLE_LEN) == 0) {
                (void)fprintf(stderr, "fuzz_t4_replace: t4_replace reported rc=0 residual=0, "
                                      "but the raw output still contains the needle\n");
                abort();
            }
        }
        carry = avail >= (size_t)(NEEDLE_LEN - 1) ? (size_t)(NEEDLE_LEN - 1) : avail;
        memmove(window, window + avail - carry, carry);
        if (got < SCAN_CHUNK) {
            break;
        }
    }
    if (ferror(f) || fclose(f) != 0) {
        abort();
    }
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
        close_or_abort(in_fd);
        remove_temp(in_path);
        return 0;
    }
    close_or_abort(out_fd);

    int wrote_ok = size == 0 || (size_t)write(in_fd, data, size) == size;
    close_or_abort(in_fd);
    if (wrote_ok) {
        T4Result r;
        int rc = t4_replace(in_path, out_path, NEEDLE, "NEWNAME", &r);
        if (rc == 0 && r.residual == 0) {
            abort_if_needle_survives(out_path);
        }
    }
    remove_temp(in_path);
    remove_temp(out_path);
    return 0;
}
