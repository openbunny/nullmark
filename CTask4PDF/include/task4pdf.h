#ifndef TASK4PDF_H
#define TASK4PDF_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { T4_ERROR_CAP = 512 };

typedef struct {
    int64_t matches; // replacements in page text, metadata values and ToUnicode CMaps
    int pages_changed;
    int64_t residual;         // occurrences, or unverifiable surfaces, left in the output
    char error[T4_ERROR_CAP]; // NUL-terminated; empty when the return code is 0
} T4Result;

// Replaces every occurrence of `find` with `replace` in the PDF at `in_path` and
// writes the result to `out_path`. Page text is removed from the content streams,
// not covered, and the replacement is drawn in the target's font, size, colour
// and position. Info dictionary values, the XMP packet, outline titles,
// annotation text and form-field values are scrubbed. Every value that does not
// contain the target keeps its content. The save is a full, non-incremental
// rewrite, so the file as a whole is not byte-identical to the input
// (README.md, "What preservation means at the byte level").
//
// Postconditions:
// - A non-zero return fills out->error. An empty `find`, or one longer than the
//   codepoint limit task4pdf.c sets, returns non-zero before the input is read.
// - A zero return with out->residual > 0 is a failure: an independent scan of
//   the written file found the target, or found a surface it cannot read back.
//   The scan covers page text, every string's and name's decoded text, every
//   non-structural stream's decompressed bytes in UTF-8, UTF-16BE and UTF-16LE,
//   every ToUnicode CMap mapping exactly the target's codepoints, and every
//   annotation appearance stream drawn through a Type0 font with no /ToUnicode.
//   Embedded files and appearance streams are not rewritten, so a target there
//   always ends in this outcome.
// - A scan that cannot run (the written file does not reopen or reparse) returns
//   non-zero.
// - out_path holds a file only when the return is 0 and out->residual is 0. On
//   every other outcome out_path is removed before returning.
int t4_replace(const char *in_path, const char *out_path, const char *find, const char *replace,
               T4Result *out);

#ifdef __cplusplus
}
#endif

#endif
