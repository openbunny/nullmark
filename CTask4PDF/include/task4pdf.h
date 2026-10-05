#ifndef TASK4PDF_H
#define TASK4PDF_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { T4_ERROR_CAP = 512 };

typedef struct {
    int64_t matches;          // occurrences of the target removed from page text and metadata
    int pages_changed;        // pages whose content was edited
    int64_t residual;         // occurrences of the target still present on any surface (must be 0)
    char error[T4_ERROR_CAP]; // empty when the return code is 0
} T4Result;

// Replaces every occurrence of `find` with `replace` in the PDF at `in_path`,
// writing the result to `out_path`. The target is removed from the page content
// streams (true redaction, not a visual cover), where the replacement is drawn
// as vector text in the target's font, size, colour and position, and from the
// document's non-page surfaces: Info dictionary values, the XMP packet, outline
// titles, annotation text and form-field values. Only occurrences of the target
// change; every other value keeps the same content. The save is a full,
// non-incremental rewrite (garbage collection + recompression), so the output
// is not byte-identical to the input as a whole; the Info dictionary, XMP
// packet, /ID and header version come out byte-identical, and that is what is
// asserted (see task4pdf.c and README.md).
//
// After writing, an independent scan reopens the output and searches every
// surface — page text, each string's decoded text, and every content,
// object-graph and embedded-file stream's decompressed bytes in the target's
// UTF-8 and UTF-16BE encodings. An embedded file or an appearance stream that
// still bears the target is not rewritten but is detected here, so the output is
// refused rather than shipped with the target intact.
//
// Returns 0 on success. On failure returns non-zero and fills out->error.
// A return of 0 with out->residual > 0 means verification found the target still
// present on some surface; the caller must treat that as failure. Output is
// shippable only when the return code is 0 and out->residual is 0, which means
// the target is absent from every surface.
//
// out_path holds a written, verified-clean file only on that shippable outcome.
// On every other outcome — a non-zero return, or out->residual > 0 — out_path is
// removed before returning, so no partial, unverified or target-bearing file is
// left on disk. A verification pass that cannot run (the written file fails to
// reopen or re-parse) is reported through a non-zero return, never as success.
int t4_replace(const char *in_path, const char *out_path, const char *find, const char *replace,
               T4Result *out);

#ifdef __cplusplus
}
#endif

#endif
