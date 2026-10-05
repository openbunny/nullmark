// Redaction coverage regression is guarded by verify-redaction.sh in this
// directory; the Type0/CID case lives in tests/test_redactor.py.
#include "task4pdf.h"

#include <mupdf/fitz.h>
#include <mupdf/pdf.h>

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    MAX_NEEDLE = 256,
    XOBJ_NAME_CAP = 32,
    OP_CAP = 64,
    FORM_DICT_CAP = 5,
    CHANNEL_MASK = 0xFF,
    CHANNEL_SHIFT_R = 16,
    CHANNEL_SHIFT_G = 8,
    BYTE_BITS = 8,
    UTF16_MAX_BMP = 0xFFFF,
    UTF16_ASTRAL_BASE = 0x10000,
    UTF16_SURROGATE_HI = 0xD800,
    UTF16_SURROGATE_LO = 0xDC00,
    UTF16_HI_SHIFT = 10,
    UTF16_LO_MASK = 0x3FF,
    UTF16_UNIT_BYTES = 2,
    UTF16BE_BOM_HI = 0xFE,
    UTF16BE_BOM_LO = 0xFF,
    // Caps a decompressed stream (the XMP packet, and every content/object-graph/
    // embedded-file stream verify_residual scans) so a crafted compressed stream
    // cannot force unbounded decompression into memory before scrubbing or
    // scanning; an oversized stream fails closed instead. 64 MiB comfortably
    // covers any legitimate PDF metadata or content stream this tool handles.
    MAX_DECOMPRESSED_STREAM_BYTES = 64 * 1024 * 1024,
    STREAM_READ_CHUNK = 65536,
    // Caps recursion over directly-nested (non-indirect) dict/array structure so
    // a crafted deeply-nested PDF object cannot exhaust the call stack; exceeding
    // it fails closed as an unscrubbable/unverifiable object.
    MAX_CONTAINER_DEPTH = 64,
    HEX_ALPHA_OFFSET = 10,
    NIBBLE_BITS = 4,
    HEX_NIBBLE_MASK = 0xF,
};
static const float CHANNEL_MAX = 255.0f;

// Deletes an output file that must not ship: every early-exit and error path,
// and the path where verification found a residual. The caller is already told
// of the failure through the return code or a non-zero out->residual, and no
// recovery is possible beyond that, so remove()'s result is not checked here.
static void discard_output(const char *path) {
    remove(path); // NOLINT(cert-err33-c): best-effort cleanup on a failing path, see above.
}

// Drops every trailer entry but Size, Root, Info and ID: repairing a damaged
// file can park recovered bytes there that the save below would otherwise
// ship, and none of those entries carries document content.
static void sanitize_trailer(fz_context *ctx, pdf_document *doc) {
    pdf_obj *trailer = pdf_trailer(ctx, doc);
    for (;;) {
        pdf_obj *junk = NULL;
        int n = pdf_dict_len(ctx, trailer);
        for (int i = 0; i < n; i++) {
            pdf_obj *key = pdf_dict_get_key(ctx, trailer, i);
            if (!pdf_name_eq(ctx, key, PDF_NAME(Size)) && !pdf_name_eq(ctx, key, PDF_NAME(Root)) &&
                !pdf_name_eq(ctx, key, PDF_NAME(Info)) && !pdf_name_eq(ctx, key, PDF_NAME(ID))) {
                junk = key;
                break;
            }
        }
        if (junk == NULL) {
            return;
        }
        pdf_dict_del(ctx, trailer, junk);
    }
}

// A run of the target text located on a page: the bounding rect to redact and
// the position, font, size and colour needed to draw the replacement in its place.
typedef struct {
    fz_rect rect;
    fz_point origin;
    fz_font *font;
    float size;
    uint32_t argb;
} Match;

// Decodes every UTF-8 codepoint of `s`, storing up to `max` into `out`, and
// returns the total codepoint count. A return greater than `max` means the
// input was longer than the buffer and `out` holds only its first `max`.
static int decode_codepoints(const char *s, int *out, int max) {
    int n = 0;
    while (*s) {
        int r;
        s += fz_chartorune(&r, s);
        if (n < max) {
            out[n] = r;
        }
        n++;
    }
    return n;
}

static int count_stext_chars(const fz_stext_page *stext) {
    int count = 0;
    for (const fz_stext_block *b = stext->first_block; b; b = b->next) {
        if (b->type == FZ_STEXT_BLOCK_TEXT) {
            for (const fz_stext_line *l = b->u.t.first_line; l; l = l->next) {
                for (const fz_stext_char *c = l->first_char; c; c = c->next) {
                    count++;
                }
            }
        }
    }
    return count;
}

// Collects every occurrence of `needle` (codepoints) in reading order on one
// page into a freshly allocated array the caller owns and frees. Returns the
// match count and sets `*out` to the array (NULL when the count is 0). The
// array is sized to the page's glyph count, so no occurrence is dropped.
static int collect_matches(fz_context *ctx, const fz_stext_page *stext, const int *needle,
                           int needle_len, Match **out) {
    *out = NULL;
    int char_count = count_stext_chars(stext);
    if (char_count == 0 || needle_len == 0) {
        return 0;
    }

    fz_stext_char **chars = NULL;
    Match *matches = NULL;
    int found = 0;
    fz_var(chars);
    fz_var(matches);
    fz_try(ctx) {
        chars = fz_malloc_array(ctx, char_count, fz_stext_char *);
        int count = 0;
        for (const fz_stext_block *b = stext->first_block; b; b = b->next) {
            if (b->type == FZ_STEXT_BLOCK_TEXT) {
                for (const fz_stext_line *l = b->u.t.first_line; l; l = l->next) {
                    for (fz_stext_char *c = l->first_char; c; c = c->next) {
                        chars[count++] = c;
                    }
                }
            }
        }
        matches = fz_malloc_array(ctx, (char_count / needle_len) + 1, Match);
        for (int i = 0; i + needle_len <= count;) {
            int hit = 1;
            for (int k = 0; k < needle_len; k++) {
                if (chars[i + k]->c != needle[k]) {
                    hit = 0;
                    break;
                }
            }
            if (!hit) {
                i++;
                continue;
            }
            Match *m = &matches[found++];
            fz_rect r = fz_empty_rect;
            for (int k = 0; k < needle_len; k++) {
                r = fz_union_rect(r, fz_rect_from_quad(chars[i + k]->quad));
            }
            m->rect = r;
            m->origin = chars[i]->origin;
            m->font = chars[i]->font;
            m->size = chars[i]->size;
            m->argb = chars[i]->argb;
            i += needle_len;
        }
    }
    fz_always(ctx) { fz_free(ctx, (void *)chars); }
    fz_catch(ctx) {
        fz_free(ctx, matches);
        fz_rethrow(ctx);
    }
    *out = matches;
    return found;
}

// Draws `replacement` as a run of glyphs starting at `origin`, using `font` and
// falling back to a substitute font for any character the run's font lacks, so
// the new text always renders even when the original was a subset.
static void draw_replacement(fz_context *ctx, fz_device *dev, const char *replacement,
                             fz_font *font, float size, fz_point origin, uint32_t argb) {
    fz_text *text = fz_new_text(ctx);
    fz_matrix trm = fz_make_matrix(size, 0, 0, -size, origin.x, origin.y);
    const char *p = replacement;
    while (*p) {
        int c;
        p += fz_chartorune(&c, p);
        fz_font *gf = font;
        int gid = font ? fz_encode_character(ctx, font, c) : 0;
        if (gid <= 0) {
            gf = NULL;
            gid = fz_encode_character_with_fallback(ctx, font, c, 0, 0, &gf);
        }
        if (!gf) {
            gf = font;
            gid = fz_encode_character(ctx, gf, c);
        }
        fz_show_glyph(ctx, text, gf, trm, gid, c, 0, 0, FZ_BIDI_LTR, FZ_LANG_UNSET);
        float adv = fz_advance_glyph(ctx, gf, gid, 0);
        trm = fz_pre_translate(trm, adv, 0);
    }
    const float rgb[3] = {
        (float)((argb >> (unsigned)CHANNEL_SHIFT_R) & (unsigned)CHANNEL_MASK) / CHANNEL_MAX,
        (float)((argb >> (unsigned)CHANNEL_SHIFT_G) & (unsigned)CHANNEL_MASK) / CHANNEL_MAX,
        (float)(argb & (unsigned)CHANNEL_MASK) / CHANNEL_MAX,
    };
    fz_fill_text(ctx, dev, text, fz_identity, fz_device_rgb(ctx), rgb, 1.0f,
                 fz_default_color_params);
    fz_drop_text(ctx, text);
}

// Appends the drawn content as a form XObject invoked from a new content stream,
// so its font resources cannot collide with the page's own resource names.
static void append_form(fz_context *ctx, pdf_document *doc, pdf_page *page, fz_rect bbox,
                        pdf_obj *resources, fz_buffer *contents) {
    pdf_obj *form = pdf_new_dict(ctx, doc, FORM_DICT_CAP);
    pdf_dict_put(ctx, form, PDF_NAME(Type), PDF_NAME(XObject));
    pdf_dict_put(ctx, form, PDF_NAME(Subtype), PDF_NAME(Form));
    pdf_dict_put_int(ctx, form, PDF_NAME(FormType), 1);
    pdf_dict_put_rect(ctx, form, PDF_NAME(BBox), bbox);
    pdf_dict_put(ctx, form, PDF_NAME(Resources), resources);
    pdf_obj *form_ref = pdf_add_stream(ctx, doc, contents, form, 0);

    pdf_obj *page_res = pdf_dict_get(ctx, page->obj, PDF_NAME(Resources));
    if (!page_res) {
        page_res = pdf_dict_put_dict(ctx, page->obj, PDF_NAME(Resources), 2);
    }
    pdf_obj *xobj = pdf_dict_get(ctx, page_res, PDF_NAME(XObject));
    if (!xobj) {
        xobj = pdf_dict_put_dict(ctx, page_res, PDF_NAME(XObject), 2);
    }

    char name[XOBJ_NAME_CAP];
    for (int i = 0;; i++) {
        snprintf(name, sizeof name, "T4R%d", i);
        if (!pdf_dict_gets(ctx, xobj, name)) {
            break;
        }
    }
    pdf_dict_puts(ctx, xobj, name, form_ref);

    char op[OP_CAP];
    snprintf(op, sizeof op, "q /%s Do Q\n", name);
    fz_buffer *cbuf = fz_new_buffer(ctx, OP_CAP);
    fz_append_string(ctx, cbuf, op);
    pdf_obj *cstream = pdf_add_stream(ctx, doc, cbuf, NULL, 0);
    fz_drop_buffer(ctx, cbuf);

    pdf_obj *page_contents = pdf_dict_get(ctx, page->obj, PDF_NAME(Contents));
    if (pdf_is_array(ctx, page_contents)) {
        pdf_array_push(ctx, page_contents, cstream);
    } else {
        pdf_obj *arr = pdf_new_array(ctx, doc, 2);
        if (page_contents) {
            pdf_array_push(ctx, arr, page_contents);
        }
        pdf_array_push(ctx, arr, cstream);
        pdf_dict_put_drop(ctx, page->obj, PDF_NAME(Contents), arr);
    }
    pdf_drop_obj(ctx, form);
    pdf_drop_obj(ctx, form_ref);
    pdf_drop_obj(ctx, cstream);
}

// True when the string `obj` decodes to text holding U+0000: every
// strlen/strstr caller downstream would stop there and miss the rest of the
// value, so both scrub and verify fail closed on it. Reads raw bytes with
// explicit length (a BOM opens UTF-16BE units; elsewhere a 0x00 byte decides).
// Names need no check: the lexer splits them at a NUL escape. Call before
// fetching decoded text: both convert through shared static buffers.
static int decoded_text_is_nul_truncated(fz_context *ctx, pdf_obj *obj) {
    size_t len = 0;
    const unsigned char *raw = (const unsigned char *)pdf_to_string(ctx, obj, &len);
    if (len >= 2 && raw[0] == UTF16BE_BOM_HI && raw[1] == UTF16BE_BOM_LO) {
        for (size_t i = 2; i + 1 < len; i += UTF16_UNIT_BYTES) {
            if (raw[i] == 0 && raw[i + 1] == 0) {
                return 1;
            }
        }
        return 0;
    }
    return memchr(raw, 0, len) != NULL;
}

// Replaces every occurrence of `find` in the UTF-8 string `hay` with `repl`,
// returning a NUL-terminated buffer the caller drops, or NULL when `find` does
// not occur. UTF-8 is self-synchronising, so a byte-level search matches only at
// codepoint boundaries of valid UTF-8.
static fz_buffer *str_replace_all(fz_context *ctx, const char *hay, const char *find,
                                  const char *repl) {
    size_t flen = strlen(find);
    if (flen == 0 || strstr(hay, find) == NULL) {
        return NULL;
    }
    fz_buffer *out = fz_new_buffer(ctx, strlen(hay) + 1);
    fz_try(ctx) {
        const char *p = hay;
        for (const char *m = NULL; (m = strstr(p, find)) != NULL; p = m + flen) {
            fz_append_data(ctx, out, p, (size_t)(m - p));
            fz_append_string(ctx, out, repl);
        }
        fz_append_string(ctx, out, p);
        fz_terminate_buffer(ctx, out);
    }
    fz_catch(ctx) {
        fz_drop_buffer(ctx, out);
        fz_rethrow(ctx);
    }
    return out;
}

// Encodes the UTF-8 string `utf8` as UTF-16 code units, big-endian unless
// `little_endian`, into a freshly allocated buffer the caller frees, setting
// `*out_len` to the byte count.
static unsigned char *encode_utf16(fz_context *ctx, const char *utf8, int little_endian,
                                   size_t *out_len) {
    unsigned char *out = fz_malloc(ctx, (strlen(utf8) * UTF16_UNIT_BYTES) + UTF16_UNIT_BYTES);
    size_t w = 0;
    for (const char *p = utf8; *p != '\0';) {
        int c = 0;
        p += fz_chartorune(&c, p);
        int units[2];
        int n = 1;
        if (c > UTF16_MAX_BMP) {
            int v = c - UTF16_ASTRAL_BASE;
            units[0] =
                (int)((unsigned)UTF16_SURROGATE_HI + ((unsigned)v >> (unsigned)UTF16_HI_SHIFT));
            units[1] =
                (int)((unsigned)UTF16_SURROGATE_LO + ((unsigned)v & (unsigned)UTF16_LO_MASK));
            n = 2;
        } else {
            units[0] = c;
        }
        for (int i = 0; i < n; i++) {
            unsigned char hi = (unsigned char)(((unsigned)units[i] >> (unsigned)BYTE_BITS) &
                                               (unsigned)CHANNEL_MASK);
            unsigned char lo = (unsigned char)((unsigned)units[i] & (unsigned)CHANNEL_MASK);
            out[w++] = little_endian ? lo : hi;
            out[w++] = little_endian ? hi : lo;
        }
    }
    *out_len = w;
    return out;
}

// Used to find and to replace the target where a PDF text string or an XMP
// packet stores it in big-endian UTF-16, the form pdf_to_text_string decodes.
static unsigned char *encode_utf16be(fz_context *ctx, const char *utf8, size_t *out_len) {
    return encode_utf16(ctx, utf8, 0, out_len);
}

// Used to find the target in little-endian UTF-16, the form a PDF string
// object never carries (pdf_to_text_string normalises that distinction away)
// but a producer-controlled raw stream — an embedded file, a /JS script, an
// XFA datasets packet — commonly does when authored by Windows tooling.
static unsigned char *encode_utf16le(fz_context *ctx, const char *utf8, size_t *out_len) {
    return encode_utf16(ctx, utf8, 1, out_len);
}

// Builds a new string object with the target replaced in the decoded text of
// `str`, or NULL when the target does not occur. pdf_to_text_string decodes
// PDFDocEncoding and UTF-16BE alike, and pdf_new_text_string re-encodes,
// so both PDF string forms and both text encodings are handled.
static pdf_obj *scrub_string_value(fz_context *ctx, pdf_obj *str, const char *find,
                                   const char *repl) {
    if (decoded_text_is_nul_truncated(ctx, str)) {
        fz_throw(ctx, FZ_ERROR_GENERIC, "string value holds an embedded NUL byte");
    }
    const char *decoded = pdf_to_text_string(ctx, str);
    fz_buffer *replaced = str_replace_all(ctx, decoded, find, repl);
    if (replaced == NULL) {
        return NULL;
    }
    pdf_obj *out = NULL;
    fz_try(ctx) {
        unsigned char *data = NULL;
        fz_buffer_storage(ctx, replaced, &data);
        out = pdf_new_text_string(ctx, (const char *)data);
    }
    fz_always(ctx) { fz_drop_buffer(ctx, replaced); }
    fz_catch(ctx) { fz_rethrow(ctx); }
    return out;
}

// Builds a new name object with the target replaced in the decoded text of
// `nm`, or NULL when the target does not occur. pdf_to_name resolves a name's
// '#XX' byte-escapes and pdf_new_name re-escapes on write as needed, so a
// target hidden behind such an escape is still found and replaced.
static pdf_obj *scrub_name_value(fz_context *ctx, pdf_obj *nm, const char *find, const char *repl) {
    const char *decoded = pdf_to_name(ctx, nm);
    fz_buffer *replaced = str_replace_all(ctx, decoded, find, repl);
    if (replaced == NULL) {
        return NULL;
    }
    pdf_obj *out = NULL;
    fz_try(ctx) {
        unsigned char *data = NULL;
        fz_buffer_storage(ctx, replaced, &data);
        out = pdf_new_name(ctx, (const char *)data);
    }
    fz_always(ctx) { fz_drop_buffer(ctx, replaced); }
    fz_catch(ctx) { fz_rethrow(ctx); }
    return out;
}

// Builds a replacement for `val` with the target scrubbed from its decoded
// text, or NULL when `val` is neither a string nor a name or holds no target.
// Dict keys never reach here: renaming a key changes which entry a reader
// finds under the standard name, a structural change past what a value-level
// scrub makes (see scrub_container).
static pdf_obj *scrub_value(fz_context *ctx, pdf_obj *val, const char *find, const char *repl) {
    if (pdf_is_string(ctx, val)) {
        return scrub_string_value(ctx, val, find, repl);
    }
    if (pdf_is_name(ctx, val)) {
        return scrub_name_value(ctx, val, find, repl);
    }
    return NULL;
}

// Replaces the target in every string or name reachable through the direct
// (non-indirect) structure of `obj`, returning the number of values changed.
// A name used as a dict *key* (rather than a value) is not scrubbed: renaming
// a key changes which entry a reader finds under the standard name, a
// structural change past what a value-level scrub can safely make. A key
// bearing the target is instead caught by the verification scan, which reads
// keys and fails closed. Indirect references are left to their own pass, so each object is
// visited once and cycles cannot recur. `depth` is the nesting level of `obj`
// below the object scrub_metadata_strings loaded (0 at that top level); once it
// would exceed MAX_CONTAINER_DEPTH this throws rather than recursing further, so
// a crafted deeply-nested dict/array cannot exhaust the call stack. That failure
// propagates out of the scrub pass and, like any other, causes the output to be
// discarded rather than shipped partially scrubbed.
static int scrub_container(fz_context *ctx, pdf_obj *obj, const char *find, const char *repl,
                           int depth) {
    if (depth > MAX_CONTAINER_DEPTH) {
        fz_throw(ctx, FZ_ERROR_GENERIC, "object nesting exceeds the depth limit of %d",
                 MAX_CONTAINER_DEPTH);
    }
    int changed = 0;
    if (pdf_is_dict(ctx, obj)) {
        int n = pdf_dict_len(ctx, obj);
        for (int i = 0; i < n; i++) {
            pdf_obj *val = pdf_dict_get_val(ctx, obj, i);
            if (pdf_is_indirect(ctx, val)) {
                continue;
            }
            pdf_obj *nw = scrub_value(ctx, val, find, repl);
            if (nw != NULL) {
                pdf_dict_put_drop(ctx, obj, pdf_dict_get_key(ctx, obj, i), nw);
                changed++;
            } else if (pdf_is_dict(ctx, val) || pdf_is_array(ctx, val)) {
                changed += scrub_container(ctx, val, find, repl, depth + 1);
            }
        }
    } else if (pdf_is_array(ctx, obj)) {
        int n = pdf_array_len(ctx, obj);
        for (int i = 0; i < n; i++) {
            pdf_obj *val = pdf_array_get(ctx, obj, i);
            if (pdf_is_indirect(ctx, val)) {
                continue;
            }
            pdf_obj *nw = scrub_value(ctx, val, find, repl);
            if (nw != NULL) {
                pdf_array_put_drop(ctx, obj, i, nw);
                changed++;
            } else if (pdf_is_dict(ctx, val) || pdf_is_array(ctx, val)) {
                changed += scrub_container(ctx, val, find, repl, depth + 1);
            }
        }
    }
    return changed;
}

// Scrubs the target from every string or name object in the document: Info
// dictionary values, outline and annotation and form-field text, Name-typed
// values (§7.3.5's '#XX' byte-escapes resolved), and any other string or
// name, custom keys included. Each numbered object is loaded once, covering
// strings and names packed into object streams. Returns the number changed.
static int scrub_metadata_strings(fz_context *ctx, pdf_document *doc, const char *find,
                                  const char *repl) {
    int total = 0;
    int count = pdf_count_objects(ctx, doc);
    pdf_obj *obj = NULL;
    fz_var(obj);
    for (int i = 1; i < count; i++) {
        fz_try(ctx) {
            obj = pdf_load_object(ctx, doc, i);
            pdf_obj *nw = scrub_value(ctx, obj, find, repl);
            if (nw != NULL) {
                pdf_update_object(ctx, doc, i, nw);
                pdf_drop_obj(ctx, nw);
                total++;
            } else {
                total += scrub_container(ctx, obj, find, repl, 0);
            }
        }
        fz_always(ctx) {
            pdf_drop_obj(ctx, obj);
            obj = NULL;
        }
        fz_catch(ctx) { fz_rethrow(ctx); }
    }
    return total;
}

// Replaces occurrences of `find` (as bytes `flen` long) with `repl` in `in`,
// returning a new buffer the caller drops, or NULL when the pattern is absent.
// `*count` receives the number of replacements. `in` is capped to
// MAX_DECOMPRESSED_STREAM_BYTES by every caller, so a 64-bit counter is not
// load-bearing for overflow on its own, but matches the width of every other
// occurrence count derived from decompressed stream bytes.
static fz_buffer *buf_replace_all(fz_context *ctx, fz_buffer *in, const unsigned char *find,
                                  size_t flen, const unsigned char *repl, size_t rlen,
                                  int64_t *count) {
    unsigned char *data = NULL;
    size_t len = fz_buffer_storage(ctx, in, &data);
    int64_t n = 0;
    if (flen > 0) {
        for (size_t i = 0; i + flen <= len;) {
            if (memcmp(data + i, find, flen) == 0) {
                n++;
                i += flen;
            } else {
                i++;
            }
        }
    }
    *count = n;
    if (n == 0) {
        return NULL;
    }
    fz_buffer *out = fz_new_buffer(ctx, len + ((size_t)n * rlen));
    fz_try(ctx) {
        for (size_t i = 0; i < len;) {
            if (i + flen <= len && memcmp(data + i, find, flen) == 0) {
                fz_append_data(ctx, out, repl, rlen);
                i += flen;
            } else {
                fz_append_byte(ctx, out, data[i]);
                i++;
            }
        }
    }
    fz_catch(ctx) {
        fz_drop_buffer(ctx, out);
        fz_rethrow(ctx);
    }
    return out;
}

// Reads PDF stream `num`'s decompressed bytes into a freshly allocated buffer
// the caller drops, reading incrementally and rejecting the stream once its
// decompressed size exceeds MAX_DECOMPRESSED_STREAM_BYTES. Reading in bounded
// chunks, rather than calling pdf_load_stream_number (which decompresses the
// whole stream into memory unconditionally before any size can be checked),
// keeps a crafted compression bomb from forcing an unbounded allocation.
// Throws on an oversized stream, consistent with this file's fail-closed
// design: the caller's failure path discards the output rather than scanning
// or scrubbing a truncated read.
static fz_buffer *load_stream_capped(fz_context *ctx, pdf_document *doc, int num) {
    fz_stream *stm = NULL;
    fz_buffer *buf = NULL;
    fz_var(stm);
    fz_var(buf);
    fz_try(ctx) {
        stm = pdf_open_stream_number(ctx, doc, num);
        buf = fz_new_buffer(ctx, STREAM_READ_CHUNK);
        unsigned char chunk[STREAM_READ_CHUNK];
        size_t total = 0;
        for (;;) {
            size_t n = fz_read(ctx, stm, chunk, sizeof chunk);
            if (n == 0) {
                break;
            }
            total += n;
            if (total > MAX_DECOMPRESSED_STREAM_BYTES) {
                fz_throw(ctx, FZ_ERROR_GENERIC, "stream %d decompresses beyond the %d-byte cap",
                         num, MAX_DECOMPRESSED_STREAM_BYTES);
            }
            fz_append_data(ctx, buf, chunk, n);
        }
    }
    fz_always(ctx) { fz_drop_stream(ctx, stm); }
    fz_catch(ctx) {
        fz_drop_buffer(ctx, buf);
        fz_rethrow(ctx);
    }
    return buf;
}

// Scrubs the target from the /Root/Metadata XMP packet, covering a UTF-8, a
// UTF-16BE and a UTF-16LE encoding of the name, and writes the packet back
// uncompressed with a corrected length. Returns the number of replacements;
// leaves the stream untouched when the target does not occur.
static int64_t scrub_xmp(fz_context *ctx, pdf_document *doc, const char *find, const char *repl) {
    pdf_obj *root = pdf_dict_get(ctx, pdf_trailer(ctx, doc), PDF_NAME(Root));
    pdf_obj *meta = pdf_dict_get(ctx, root, PDF_NAME(Metadata));
    int meta_num = pdf_to_num(ctx, meta);
    if (meta_num <= 0 || !pdf_obj_num_is_stream(ctx, doc, meta_num)) {
        return 0;
    }
    fz_buffer *raw = NULL;
    fz_buffer *step8 = NULL;
    fz_buffer *step16be = NULL;
    fz_buffer *step16le = NULL;
    unsigned char *find16be = NULL;
    unsigned char *repl16be = NULL;
    unsigned char *find16le = NULL;
    unsigned char *repl16le = NULL;
    int64_t total = 0;
    fz_var(raw);
    fz_var(step8);
    fz_var(step16be);
    fz_var(step16le);
    fz_var(find16be);
    fz_var(repl16be);
    fz_var(find16le);
    fz_var(repl16le);
    fz_var(total);
    fz_try(ctx) {
        raw = load_stream_capped(ctx, doc, meta_num);
        int64_t n8 = 0;
        step8 = buf_replace_all(ctx, raw, (const unsigned char *)find, strlen(find),
                                (const unsigned char *)repl, strlen(repl), &n8);
        fz_buffer *base = step8 != NULL ? step8 : raw;
        size_t find16be_len = 0;
        size_t repl16be_len = 0;
        find16be = encode_utf16be(ctx, find, &find16be_len);
        repl16be = encode_utf16be(ctx, repl, &repl16be_len);
        int64_t n16be = 0;
        step16be =
            buf_replace_all(ctx, base, find16be, find16be_len, repl16be, repl16be_len, &n16be);
        base = step16be != NULL ? step16be : base;
        size_t find16le_len = 0;
        size_t repl16le_len = 0;
        find16le = encode_utf16le(ctx, find, &find16le_len);
        repl16le = encode_utf16le(ctx, repl, &repl16le_len);
        int64_t n16le = 0;
        step16le =
            buf_replace_all(ctx, base, find16le, find16le_len, repl16le, repl16le_len, &n16le);
        total = n8 + n16be + n16le;
        fz_buffer *result = step16le;
        if (result == NULL) {
            result = step16be;
        }
        if (result == NULL) {
            result = step8;
        }
        if (result != NULL) {
            pdf_update_stream(ctx, doc, meta, result, 0);
        }
    }
    fz_always(ctx) {
        fz_free(ctx, find16be);
        fz_free(ctx, repl16be);
        fz_free(ctx, find16le);
        fz_free(ctx, repl16le);
        fz_drop_buffer(ctx, step16le);
        fz_drop_buffer(ctx, step16be);
        fz_drop_buffer(ctx, step8);
        fz_drop_buffer(ctx, raw);
    }
    fz_catch(ctx) { fz_rethrow(ctx); }
    return total;
}

// Counts non-overlapping occurrences of the `nlen`-byte `needle` in `hay`. A
// 64-bit counter avoids overflow on `hay` buffers up to
// MAX_DECOMPRESSED_STREAM_BYTES: even an nlen-1 needle cannot produce more
// occurrences than the buffer has bytes, and that count alone already exceeds
// what a 32-bit signed counter can hold without this width.
static int64_t count_needle_bytes(const unsigned char *hay, size_t hlen,
                                  const unsigned char *needle, size_t nlen) {
    if (nlen == 0) {
        return 0;
    }
    int64_t c = 0;
    for (size_t i = 0; i + nlen <= hlen;) {
        if (memcmp(hay + i, needle, nlen) == 0) {
            c++;
            i += nlen;
        } else {
            i++;
        }
    }
    return c;
}

// Counts occurrences of `find` in the decoded text of every string or name
// reachable through the direct structure of `obj`. Indirect references are
// visited in their own pass, so each object is counted once. `depth` bounds
// recursion exactly as in scrub_container (see there); exceeding
// MAX_CONTAINER_DEPTH throws, which verify_residual's caller treats as an
// unverifiable output and therefore a failure, never a silent pass.
static int64_t scan_container_strings(fz_context *ctx, pdf_obj *obj, const char *find, int depth);

// Counts occurrences of `find` in an /ID array's digest elements on raw bytes
// with explicit lengths. These elements are opaque 128-bit digests, not text:
// reading them through a C-string view would trip on any 0x00 byte they
// legitimately hold (about one run in sixteen per element), while the save
// preserves them byte-identical, so a raw count is exact and never blind.
static int64_t count_id_needles(fz_context *ctx, pdf_obj *arr, const char *find, int depth) {
    int64_t total = 0;
    int n = pdf_array_len(ctx, arr);
    for (int i = 0; i < n; i++) {
        pdf_obj *elt = pdf_array_get(ctx, arr, i);
        if (pdf_is_string(ctx, elt)) {
            size_t len = 0;
            const unsigned char *raw = (const unsigned char *)pdf_to_string(ctx, elt, &len);
            total += count_needle_bytes(raw, len, (const unsigned char *)find, strlen(find));
        } else if (!pdf_is_indirect(ctx, elt)) {
            total += scan_container_strings(ctx, elt, find, depth + 1);
        }
    }
    return total;
}

static int64_t scan_container_strings(fz_context *ctx, pdf_obj *obj, const char *find, int depth) {
    if (depth > MAX_CONTAINER_DEPTH) {
        fz_throw(ctx, FZ_ERROR_GENERIC, "object nesting exceeds the depth limit of %d",
                 MAX_CONTAINER_DEPTH);
    }
    int64_t total = 0;
    if (pdf_is_string(ctx, obj)) {
        if (decoded_text_is_nul_truncated(ctx, obj)) {
            fz_throw(ctx, FZ_ERROR_GENERIC, "string value holds an embedded NUL byte");
        }
        const char *decoded = pdf_to_text_string(ctx, obj);
        total += count_needle_bytes((const unsigned char *)decoded, strlen(decoded),
                                    (const unsigned char *)find, strlen(find));
    } else if (pdf_is_name(ctx, obj)) {
        const char *name = pdf_to_name(ctx, obj);
        total += count_needle_bytes((const unsigned char *)name, strlen(name),
                                    (const unsigned char *)find, strlen(find));
    } else if (pdf_is_dict(ctx, obj)) {
        int n = pdf_dict_len(ctx, obj);
        for (int i = 0; i < n; i++) {
            pdf_obj *key = pdf_dict_get_key(ctx, obj, i);
            const char *kname = pdf_to_name(ctx, key);
            total += count_needle_bytes((const unsigned char *)kname, strlen(kname),
                                        (const unsigned char *)find, strlen(find));
            pdf_obj *val = pdf_dict_get_val(ctx, obj, i);
            if (pdf_name_eq(ctx, key, PDF_NAME(ID)) && pdf_is_array(ctx, val)) {
                total += count_id_needles(ctx, val, find, depth + 1);
            } else if (!pdf_is_indirect(ctx, val)) {
                total += scan_container_strings(ctx, val, find, depth + 1);
            }
        }
    } else if (pdf_is_array(ctx, obj)) {
        int n = pdf_array_len(ctx, obj);
        for (int i = 0; i < n; i++) {
            pdf_obj *val = pdf_array_get(ctx, obj, i);
            if (!pdf_is_indirect(ctx, val)) {
                total += scan_container_strings(ctx, val, find, depth + 1);
            }
        }
    }
    return total;
}

// True for the cross-reference and object-stream containers, whose serialised
// form holds other objects' bytes. Their logical contents are scanned as
// individual objects, so scanning the container too would double-count and
// could match a structural name that is not a scrubbable string.
static int is_structural_stream(fz_context *ctx, pdf_obj *obj) {
    pdf_obj *type = pdf_dict_get(ctx, obj, PDF_NAME(Type));
    return pdf_name_eq(ctx, type, PDF_NAME(ObjStm)) || pdf_name_eq(ctx, type, PDF_NAME(XRef));
}

// The hex digit value of `c`, or -1 when `c` is not one.
static int hexval(char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return c - 'a' + HEX_ALPHA_OFFSET;
    }
    if (c >= 'A' && c <= 'F') {
        return c - 'A' + HEX_ALPHA_OFFSET;
    }
    return -1;
}

// Parses the next `<hex...>` CMap literal at or after `s[*pos]` (within
// `len`), writing its decoded bytes to `buf` (capped at `cap`; non-hex bytes
// such as embedded whitespace are skipped, matching how a CMap interpreter
// reads one) and advancing `*pos` past the closing '>'. Returns the decoded
// byte count, which may exceed `cap`. Leaves `*pos` at `len` when no '<'
// remains.
static size_t parse_hex_literal(const char *s, size_t len, size_t *pos, unsigned char *buf,
                                size_t cap) {
    size_t i = *pos;
    while (i < len && s[i] != '<') {
        i++;
    }
    if (i >= len) {
        *pos = i;
        return 0;
    }
    i++;
    size_t n = 0;
    int hi = -1;
    while (i < len && s[i] != '>') {
        int d = hexval(s[i]);
        if (d >= 0) {
            if (hi < 0) {
                hi = d;
            } else {
                if (n < cap) {
                    buf[n] = (unsigned char)(((unsigned)hi << 4u) | (unsigned)d);
                }
                n++;
                hi = -1;
            }
        }
        i++;
    }
    if (i < len && s[i] == '>') {
        i++;
    }
    *pos = i;
    return n;
}

// Decodes `n` big-endian UTF-16 bytes (surrogate pairs included) into
// codepoints, storing up to `max` into `out`. Returns the codepoint count,
// which may exceed `max`.
static int decode_utf16be_bytes(const unsigned char *bytes, size_t n, int *out, int max) {
    int cnt = 0;
    size_t i = 0;
    while (i + UTF16_UNIT_BYTES <= n) {
        int u = (int)(((unsigned)bytes[i] << (unsigned)BYTE_BITS) | (unsigned)bytes[i + 1]);
        i += UTF16_UNIT_BYTES;
        int cp = u;
        if (u >= UTF16_SURROGATE_HI && u <= UTF16_SURROGATE_HI + UTF16_LO_MASK &&
            i + UTF16_UNIT_BYTES <= n) {
            int lo = (int)(((unsigned)bytes[i] << (unsigned)BYTE_BITS) | (unsigned)bytes[i + 1]);
            if (lo >= UTF16_SURROGATE_LO && lo <= UTF16_SURROGATE_LO + UTF16_LO_MASK) {
                cp = (int)((unsigned)UTF16_ASTRAL_BASE +
                           ((unsigned)(u - UTF16_SURROGATE_HI) << (unsigned)UTF16_HI_SHIFT) +
                           (unsigned)(lo - UTF16_SURROGATE_LO));
                i += UTF16_UNIT_BYTES;
            }
        }
        if (cnt < max) {
            out[cnt] = cp;
        }
        cnt++;
    }
    return cnt;
}

// Appends `cp` to `set` (sized `*n`, capped at `max`) unless already present.
static void add_unique_codepoint(int *set, int *n, int max, int cp) {
    // *n is allowed to exceed max on return (the caller treats that as an
    // overflow signal), but set[] only has max slots: the dedup scan below
    // must stop at max once *n has passed it, or it reads past the array.
    int seen = *n < max ? *n : max;
    for (int i = 0; i < seen; i++) {
        if (set[i] == cp) {
            return;
        }
    }
    if (*n < max) {
        set[*n] = cp;
    }
    (*n)++;
}

// Collects the distinct Unicode codepoints reachable through a CMap stream's
// beginbfchar/endbfchar blocks (ISO 32000-1 §9.10.3): each entry's
// destination hex literal, decoded as UTF-16BE text. Into `out` (capped at
// `max`, deduplicated); returns the distinct count. A single forward pass
// over `s`, so a crafted stream cannot make this quadratic. bfrange blocks
// are not parsed — the ranged form this scan does not cover — so a target
// mapped only through one is not caught by it.
static int cmap_bfchar_codepoints(const char *s, size_t len, int *out, int max) {
    int n = 0;
    size_t i = 0;
    static const char kBegin[] = "beginbfchar";
    static const char kEnd[] = "endbfchar";
    while (i < len) {
        if (i + sizeof(kBegin) - 1 > len || memcmp(s + i, kBegin, sizeof(kBegin) - 1) != 0) {
            i++;
            continue;
        }
        size_t stop = i + sizeof(kBegin) - 1;
        int found_end = 0;
        while (stop < len) {
            if (stop + sizeof(kEnd) - 1 <= len && memcmp(s + stop, kEnd, sizeof(kEnd) - 1) == 0) {
                found_end = 1;
                break;
            }
            stop++;
        }
        if (!found_end) {
            break;
        }
        size_t q = i + sizeof(kBegin) - 1;
        while (q < stop) {
            unsigned char srcbuf[MAX_NEEDLE];
            size_t srclen = parse_hex_literal(s, stop, &q, srcbuf, sizeof srcbuf);
            if (srclen == 0 && q >= stop) {
                break;
            }
            unsigned char dstbuf[MAX_NEEDLE * UTF16_UNIT_BYTES];
            size_t dstlen = parse_hex_literal(s, stop, &q, dstbuf, sizeof dstbuf);
            if (dstlen == 0) {
                continue;
            }
            int cps[MAX_NEEDLE];
            size_t capped = dstlen < sizeof dstbuf ? dstlen : sizeof dstbuf;
            int cn = decode_utf16be_bytes(dstbuf, capped, cps, MAX_NEEDLE);
            for (int k = 0; k < cn && k < MAX_NEEDLE; k++) {
                add_unique_codepoint(out, &n, max, cps[k]);
            }
        }
        i = stop + sizeof(kEnd) - 1;
    }
    return n;
}

// True when a ToUnicode CMap's bfchar destinations decode to exactly the
// target's distinct codepoints and no others: the signature of a font
// subsetted (as nullmark's own tests/fixtures/generate.py:build_cidfont does)
// to draw only the target's letters, whose glyph-to-Unicode table survives a
// content-stream redaction of those glyphs (whether on the page or in an
// annotation appearance stream, both scanned as ordinary streams below) and
// so still reconstructs the target's character set. A real document's
// broader-coverage embedded font is not flagged: its CMap maps many more
// codepoints than the target's, failing the exact-match test.
static int cmap_reveals_target(const char *data, size_t len, const int *needle, int needle_len) {
    if (needle_len <= 0 || needle_len > MAX_NEEDLE) {
        return 0;
    }
    int dest[MAX_NEEDLE];
    int dest_n = cmap_bfchar_codepoints(data, len, dest, MAX_NEEDLE);
    if (dest_n <= 0 || dest_n > MAX_NEEDLE) {
        return 0;
    }
    int want[MAX_NEEDLE];
    int want_n = 0;
    for (int i = 0; i < needle_len; i++) {
        add_unique_codepoint(want, &want_n, MAX_NEEDLE, needle[i]);
    }
    if (dest_n != want_n) {
        return 0;
    }
    for (int i = 0; i < want_n; i++) {
        int found = 0;
        for (int j = 0; j < dest_n; j++) {
            if (dest[j] == want[i]) {
                found = 1;
                break;
            }
        }
        if (!found) {
            return 0;
        }
    }
    return 1;
}

// True when `cp` is one of the `n` codepoints in `set`.
static int codepoint_in_set(int cp, const int *set, int n) {
    for (int i = 0; i < n; i++) {
        if (set[i] == cp) {
            return 1;
        }
    }
    return 0;
}

// Appends a CMap hex literal `<HH...>` for the `n` bytes of `bytes` to `out`.
static void append_hex_literal(fz_context *ctx, fz_buffer *out, const unsigned char *bytes,
                               size_t n) {
    static const char hexd[] = "0123456789ABCDEF";
    fz_append_byte(ctx, out, '<');
    for (size_t k = 0; k < n; k++) {
        fz_append_byte(
            ctx, out,
            hexd[((unsigned)bytes[k] >> (unsigned)NIBBLE_BITS) & (unsigned)HEX_NIBBLE_MASK]);
        fz_append_byte(ctx, out, hexd[(unsigned)bytes[k] & (unsigned)HEX_NIBBLE_MASK]);
    }
    fz_append_byte(ctx, out, '>');
}

// Rebuilds a ToUnicode CMap keeping only the bfchar entries whose destination
// decodes entirely to codepoints in `keep` (the replacement's codepoints): the
// glyphs the replacement still draws through this font. The orphaned entries a
// redaction leaves behind — glyphs that spelled the now-removed target and are
// no longer drawn — are dropped, so the rebuilt CMap no longer reconstructs the
// target while every mapping the replacement relies on survives. Returns a new
// buffer the caller drops, or NULL when no entry is kept (the caller then
// removes the /ToUnicode outright). bfrange entries are not carried over;
// cmap_reveals_target does not parse them either, so a CMap flagged and reached
// here maps the target only through bfchar.
static fz_buffer *filter_tounicode(fz_context *ctx, const char *s, size_t len, const int *keep,
                                   int keep_n) {
    fz_buffer *entries = fz_new_buffer(ctx, len);
    int kept = 0;
    fz_try(ctx) {
        size_t i = 0;
        static const char kBegin[] = "beginbfchar";
        static const char kEnd[] = "endbfchar";
        while (i < len) {
            if (i + sizeof(kBegin) - 1 > len || memcmp(s + i, kBegin, sizeof(kBegin) - 1) != 0) {
                i++;
                continue;
            }
            size_t stop = i + sizeof(kBegin) - 1;
            int found_end = 0;
            while (stop < len) {
                if (stop + sizeof(kEnd) - 1 <= len &&
                    memcmp(s + stop, kEnd, sizeof(kEnd) - 1) == 0) {
                    found_end = 1;
                    break;
                }
                stop++;
            }
            if (!found_end) {
                break;
            }
            size_t q = i + sizeof(kBegin) - 1;
            while (q < stop) {
                unsigned char srcbuf[MAX_NEEDLE];
                size_t srclen = parse_hex_literal(s, stop, &q, srcbuf, sizeof srcbuf);
                if (srclen == 0 && q >= stop) {
                    break;
                }
                unsigned char dstbuf[MAX_NEEDLE * UTF16_UNIT_BYTES];
                size_t dstlen = parse_hex_literal(s, stop, &q, dstbuf, sizeof dstbuf);
                if (srclen == 0 || srclen > sizeof srcbuf || dstlen == 0 ||
                    dstlen > sizeof dstbuf) {
                    continue;
                }
                int cps[MAX_NEEDLE];
                int cn = decode_utf16be_bytes(dstbuf, dstlen, cps, MAX_NEEDLE);
                int all_kept = cn > 0 && cn <= MAX_NEEDLE;
                for (int k = 0; k < cn && k < MAX_NEEDLE; k++) {
                    if (!codepoint_in_set(cps[k], keep, keep_n)) {
                        all_kept = 0;
                        break;
                    }
                }
                if (all_kept) {
                    append_hex_literal(ctx, entries, srcbuf, srclen);
                    fz_append_byte(ctx, entries, ' ');
                    append_hex_literal(ctx, entries, dstbuf, dstlen);
                    fz_append_byte(ctx, entries, '\n');
                    kept++;
                }
            }
            i = stop + sizeof(kEnd) - 1;
        }
    }
    fz_catch(ctx) {
        fz_drop_buffer(ctx, entries);
        fz_rethrow(ctx);
    }
    if (kept == 0) {
        fz_drop_buffer(ctx, entries);
        return NULL;
    }
    fz_buffer *out = fz_new_buffer(ctx, len);
    fz_try(ctx) {
        fz_append_string(ctx, out,
                         "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
                         "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> "
                         "def\n/CMapName /Task4-UCS def\n/CMapType 2 def\n"
                         "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
        fz_append_printf(ctx, out, "%d beginbfchar\n", kept);
        unsigned char *edata = NULL;
        size_t elen = fz_buffer_storage(ctx, entries, &edata);
        fz_append_data(ctx, out, edata, elen);
        fz_append_string(ctx, out,
                         "endbfchar\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\n"
                         "end\n");
    }
    fz_always(ctx) { fz_drop_buffer(ctx, entries); }
    fz_catch(ctx) {
        fz_drop_buffer(ctx, out);
        fz_rethrow(ctx);
    }
    return out;
}

// Repairs every font whose /ToUnicode CMap reconstructs exactly the target and
// nothing else (cmap_reveals_target) after that font's glyphs were redacted from
// the page: the drawn glyphs are gone, but the glyph-to-Unicode table still
// spells the target out for a text extractor, which verify_residual's own
// cmap_reveals_target scan catches and fails closed on. The CMap is rewritten
// (filter_tounicode) to keep only the entries the replacement still draws
// through this font and drop the target's now-orphaned ones; if nothing is kept,
// or the rewrite would still reveal the target (the replacement's own letters
// cover the target's), the /ToUnicode is removed outright and the now-unreferenced
// stream is dropped by the do_garbage=3 save. A broader-coverage font, whose CMap
// maps more than the target, is never flagged and keeps its /ToUnicode intact.
// Returns the number of CMaps repaired or removed.
static int scrub_tounicode_cmaps(fz_context *ctx, pdf_document *doc, const char *replace,
                                 const int *needle, int needle_len) {
    int keep[MAX_NEEDLE];
    int keep_raw = decode_codepoints(replace, keep, MAX_NEEDLE);
    int keep_n = keep_raw < MAX_NEEDLE ? keep_raw : MAX_NEEDLE;

    int total = 0;
    int count = pdf_count_objects(ctx, doc);
    pdf_obj *obj = NULL;
    fz_buffer *buf = NULL;
    fz_buffer *rebuilt = NULL;
    fz_var(obj);
    fz_var(buf);
    fz_var(rebuilt);
    for (int i = 1; i < count; i++) {
        fz_try(ctx) {
            obj = pdf_load_object(ctx, doc, i);
            pdf_obj *tu = pdf_dict_get(ctx, obj, PDF_NAME(ToUnicode));
            if (pdf_is_stream(ctx, tu)) {
                buf = load_stream_capped(ctx, doc, pdf_to_num(ctx, tu));
                unsigned char *data = NULL;
                size_t len = fz_buffer_storage(ctx, buf, &data);
                if (cmap_reveals_target((const char *)data, len, needle, needle_len)) {
                    rebuilt = filter_tounicode(ctx, (const char *)data, len, keep, keep_n);
                    int drop = rebuilt == NULL;
                    if (!drop) {
                        unsigned char *rd = NULL;
                        size_t rl = fz_buffer_storage(ctx, rebuilt, &rd);
                        drop = cmap_reveals_target((const char *)rd, rl, needle, needle_len);
                    }
                    if (drop) {
                        pdf_dict_del(ctx, obj, PDF_NAME(ToUnicode));
                    } else {
                        pdf_update_stream(ctx, doc, tu, rebuilt, 0);
                    }
                    fz_drop_buffer(ctx, rebuilt);
                    rebuilt = NULL;
                    total++;
                }
            }
        }
        fz_always(ctx) {
            fz_drop_buffer(ctx, rebuilt);
            rebuilt = NULL;
            fz_drop_buffer(ctx, buf);
            buf = NULL;
            pdf_drop_obj(ctx, obj);
            obj = NULL;
        }
        fz_catch(ctx) { fz_rethrow(ctx); }
    }
    return total;
}

// True when `font`, a Font resource dict, is a Type0 (CID-keyed) font with no
// /ToUnicode CMap: no declared way to recover the Unicode text its codes
// draw. Content shown through such a font is invisible to both the
// stext-based oracle below (fz_stext needs a Unicode mapping to produce text)
// and cmap_reveals_target above (nothing to parse), so its presence, not its
// content, is what gets checked: this function does not and cannot determine
// what text such a font draws.
static int font_is_unverifiable_cid(fz_context *ctx, pdf_obj *font) {
    if (!pdf_is_dict(ctx, font)) {
        return 0;
    }
    pdf_obj *subtype = pdf_dict_get(ctx, font, PDF_NAME(Subtype));
    if (!pdf_name_eq(ctx, subtype, PDF_NAME(Type0))) {
        return 0;
    }
    return pdf_dict_get(ctx, font, PDF_NAME(ToUnicode)) == NULL;
}

// True when appearance-stream object `stream_obj` both shows text (contains a
// Tj or TJ operator — a cheap substring check, sufficient to decide whether
// the stream draws glyphs at all without a full content-stream parse) and
// resolves at least one font in its own /Resources/Font dict to an
// unverifiable CID font per font_is_unverifiable_cid. A PDF form XObject
// carries its own /Resources, so this needs nothing from the page or
// annotation that references the stream.
static int ap_stream_is_unverifiable(fz_context *ctx, pdf_obj *stream_obj) {
    if (!pdf_is_stream(ctx, stream_obj)) {
        return 0;
    }
    pdf_obj *resources = pdf_dict_get(ctx, stream_obj, PDF_NAME(Resources));
    pdf_obj *fonts = pdf_dict_get(ctx, resources, PDF_NAME(Font));
    if (!pdf_is_dict(ctx, fonts)) {
        return 0;
    }
    int has_unverifiable_font = 0;
    int nfonts = pdf_dict_len(ctx, fonts);
    for (int i = 0; i < nfonts && !has_unverifiable_font; i++) {
        if (font_is_unverifiable_cid(ctx, pdf_dict_get_val(ctx, fonts, i))) {
            has_unverifiable_font = 1;
        }
    }
    if (!has_unverifiable_font) {
        return 0;
    }
    fz_buffer *buf = NULL;
    int shows_text = 0;
    fz_var(buf);
    fz_try(ctx) {
        buf = pdf_load_stream(ctx, stream_obj);
        unsigned char *data = NULL;
        size_t len = fz_buffer_storage(ctx, buf, &data);
        shows_text = count_needle_bytes(data, len, (const unsigned char *)"Tj", 2) > 0 ||
                     count_needle_bytes(data, len, (const unsigned char *)"TJ", 2) > 0;
    }
    fz_always(ctx) { fz_drop_buffer(ctx, buf); }
    fz_catch(ctx) { fz_rethrow(ctx); }
    return shows_text;
}

// Applies ap_stream_is_unverifiable to every leaf stream reachable from an
// annotation appearance-dict entry `v`: a stream directly, or (a widget with
// more than one appearance, e.g. a checkbox's Off/On states) a dict of
// streams keyed by state name. Every state is visited, not only the one
// /AS currently names — every state ships bytes in the file regardless of
// which one is selected, and t4_replace's redaction pass never rewrites
// annotation appearance streams at all (see the comment in t4_replace), so
// an unselected state is exactly as unverified as the selected one. Returns
// the number of unverifiable leaf streams found.
static int scan_ap_state(fz_context *ctx, pdf_obj *v) {
    if (v == NULL) {
        return 0;
    }
    if (pdf_is_stream(ctx, v)) {
        return ap_stream_is_unverifiable(ctx, v);
    }
    if (pdf_is_dict(ctx, v)) {
        int total = 0;
        int n = pdf_dict_len(ctx, v);
        for (int i = 0; i < n; i++) {
            total += scan_ap_state(ctx, pdf_dict_get_val(ctx, v, i));
        }
        return total;
    }
    return 0;
}

// Scans every annotation on `page` — Hidden and NoView ones included, since
// pdf_first_annot/pdf_next_annot walk the /Annots array itself rather than
// anything rendering-filtered — for an appearance stream this tool cannot
// prove is target-free (see ap_stream_is_unverifiable). Returns the count
// found, added into verify_residual's fail-closed total below.
static int scan_page_annots_unverifiable(fz_context *ctx, pdf_page *page) {
    int total = 0;
    for (pdf_annot *annot = pdf_first_annot(ctx, page); annot != NULL;
         annot = pdf_next_annot(ctx, annot)) {
        pdf_obj *obj = pdf_annot_obj(ctx, annot);
        pdf_obj *ap = pdf_dict_get(ctx, obj, PDF_NAME(AP));
        if (!pdf_is_dict(ctx, ap)) {
            continue;
        }
        total += scan_ap_state(ctx, pdf_dict_get(ctx, ap, PDF_NAME(N)));
        total += scan_ap_state(ctx, pdf_dict_get(ctx, ap, PDF_NAME(R)));
        total += scan_ap_state(ctx, pdf_dict_get(ctx, ap, PDF_NAME(D)));
    }
    return total;
}

// Counts the target still present anywhere in the written file, independently of
// the redaction path. Oracles run against a freshly opened copy: the page
// text extracted by fz_stext (blind to /ActualText, hidden layers and metadata),
// a byte-and-decode scan of every object — each string's and name's decoded
// text, and every content, object-graph and embedded-file stream's decompressed
// bytes in the target's UTF-8, UTF-16BE and UTF-16LE encodings — a CMap-aware
// scan of every stream for a ToUnicode table that reveals the target (see
// cmap_reveals_target), and a scan of every annotation's appearance streams,
// Hidden and NoView ones included, for CID-font text this tool has no way to
// read back (see scan_page_annots_unverifiable): such a stream is treated as
// a failure to verify, not as an absence of the target, and fails closed the
// same as a confirmed match. A non-zero result means the target survives, or
// cannot be shown not to survive, on some surface. A throw (a file that will
// not reopen or reparse) propagates, so an unverifiable output is a failure,
// never a silent pass.
static int64_t verify_residual(fz_context *ctx, const char *out_path, const char *find,
                               const int *needle, int needle_len) {
    pdf_document *doc = NULL;
    pdf_page *pg = NULL;
    fz_stext_page *stext = NULL;
    int *flat = NULL;
    fz_buffer *sbuf = NULL;
    pdf_obj *obj = NULL;
    unsigned char *find16be = NULL;
    unsigned char *find16le = NULL;
    int64_t residual = 0;
    fz_var(doc);
    fz_var(pg);
    fz_var(stext);
    fz_var(flat);
    fz_var(sbuf);
    fz_var(obj);
    fz_var(find16be);
    fz_var(find16le);
    fz_var(residual);
    fz_try(ctx) {
        doc = pdf_open_document(ctx, out_path);
        int pages = pdf_count_pages(ctx, doc);
        for (int i = 0; i < pages; i++) {
            fz_stext_options sopts = {0};
            pg = pdf_load_page(ctx, doc, i);
            residual += scan_page_annots_unverifiable(ctx, pg);
            stext = fz_new_stext_page_from_page(ctx, (fz_page *)pg, &sopts);
            int char_count = count_stext_chars(stext);
            if (char_count > 0) {
                flat = fz_malloc_array(ctx, char_count, int);
                int fi = 0;
                for (const fz_stext_block *b = stext->first_block; b; b = b->next) {
                    if (b->type == FZ_STEXT_BLOCK_TEXT) {
                        for (const fz_stext_line *l = b->u.t.first_line; l; l = l->next) {
                            for (const fz_stext_char *c = l->first_char; c; c = c->next) {
                                flat[fi++] = c->c;
                            }
                        }
                    }
                }
                for (int j = 0; j + needle_len <= fi; j++) {
                    int hit = 1;
                    for (int k = 0; k < needle_len; k++) {
                        if (flat[j + k] != needle[k]) {
                            hit = 0;
                            break;
                        }
                    }
                    if (hit) {
                        residual++;
                    }
                }
                fz_free(ctx, flat);
                flat = NULL;
            }
            fz_drop_stext_page(ctx, stext);
            stext = NULL;
            fz_drop_page(ctx, (fz_page *)pg);
            pg = NULL;
        }

        size_t find16be_len = 0;
        size_t find16le_len = 0;
        find16be = encode_utf16be(ctx, find, &find16be_len);
        find16le = encode_utf16le(ctx, find, &find16le_len);
        size_t find8_len = strlen(find);
        int count = pdf_count_objects(ctx, doc);
        for (int i = 1; i < count; i++) {
            obj = pdf_load_object(ctx, doc, i);
            residual += scan_container_strings(ctx, obj, find, 0);
            if (pdf_obj_num_is_stream(ctx, doc, i) && !is_structural_stream(ctx, obj)) {
                sbuf = load_stream_capped(ctx, doc, i);
                unsigned char *data = NULL;
                size_t len = fz_buffer_storage(ctx, sbuf, &data);
                residual += count_needle_bytes(data, len, (const unsigned char *)find, find8_len);
                residual += count_needle_bytes(data, len, find16be, find16be_len);
                residual += count_needle_bytes(data, len, find16le, find16le_len);
                residual += cmap_reveals_target((const char *)data, len, needle, needle_len);
                fz_drop_buffer(ctx, sbuf);
                sbuf = NULL;
            }
            pdf_drop_obj(ctx, obj);
            obj = NULL;
        }
        // The trailer dict itself ships in the file, so it is scanned like any
        // other object: repairing a damaged file can park bytes there that no
        // object pass reaches.
        residual += scan_container_strings(ctx, pdf_trailer(ctx, doc), find, 0);
    }
    fz_always(ctx) {
        fz_free(ctx, find16be);
        fz_free(ctx, find16le);
        fz_free(ctx, flat);
        fz_drop_buffer(ctx, sbuf);
        pdf_drop_obj(ctx, obj);
        fz_drop_stext_page(ctx, stext);
        fz_drop_page(ctx, (fz_page *)pg);
        pdf_drop_document(ctx, doc);
    }
    fz_catch(ctx) { fz_rethrow(ctx); }
    return residual;
}

int t4_replace(const char *in_path, const char *out_path, const char *find, const char *replace,
               T4Result *out) {
    memset(out, 0, sizeof *out);
    int needle[MAX_NEEDLE];
    int needle_len = decode_codepoints(find, needle, MAX_NEEDLE);
    if (needle_len == 0) {
        snprintf(out->error, sizeof out->error, "The text to replace is empty.");
        discard_output(out_path);
        return 1;
    }
    if (needle_len > MAX_NEEDLE) {
        snprintf(out->error, sizeof out->error,
                 "The text to replace is longer than the %d-character limit.", MAX_NEEDLE);
        discard_output(out_path);
        return 1;
    }

    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    if (!ctx) {
        snprintf(out->error, sizeof out->error, "MuPDF context could not be created.");
        discard_output(out_path);
        return 1;
    }
    fz_register_document_handlers(ctx);

    pdf_document *doc = NULL;
    pdf_page *page = NULL;
    fz_stext_page *stext = NULL;
    fz_device *dev = NULL;
    pdf_obj *resources = NULL;
    fz_buffer *contents = NULL;
    pdf_annot *annot = NULL;
    Match *matches = NULL;
    fz_var(doc);
    fz_var(page);
    fz_var(stext);
    fz_var(dev);
    fz_var(resources);
    fz_var(contents);
    fz_var(annot);
    fz_var(matches);
    fz_try(ctx) {
        doc = pdf_open_document(ctx, in_path);
        int pages = pdf_count_pages(ctx, doc);
        for (int i = 0; i < pages; i++) {
            page = pdf_load_page(ctx, doc, i);
            fz_rect bbox = fz_bound_page(ctx, (fz_page *)page);

            fz_stext_options sopts = {0};
            stext = fz_new_stext_page_from_page(ctx, (fz_page *)page, &sopts);

            int n = collect_matches(ctx, stext, needle, needle_len, &matches);
            if (n > 0) {
                for (int m = 0; m < n; m++) {
                    annot = pdf_create_annot(ctx, page, PDF_ANNOT_REDACT);
                    // stext quads are in transformed page space; pdf_set_annot_rect
                    // applies the inverse page transform itself, so pass them raw.
                    pdf_set_annot_rect(ctx, annot, matches[m].rect);
                    pdf_drop_annot(ctx, annot);
                    annot = NULL;
                }
                pdf_redact_options ropts = {0};
                ropts.black_boxes = 0;
                ropts.image_method = PDF_REDACT_IMAGE_NONE;
                ropts.line_art = PDF_REDACT_LINE_ART_NONE;
                ropts.text = PDF_REDACT_TEXT_REMOVE;
                if (!pdf_redact_page(ctx, doc, page, &ropts)) {
                    fz_throw(ctx, FZ_ERROR_GENERIC, "redaction removed nothing on page %d", i + 1);
                }

                dev = pdf_page_write(ctx, doc, bbox, &resources, &contents);
                for (int m = 0; m < n; m++) {
                    draw_replacement(ctx, dev, replace, matches[m].font, matches[m].size,
                                     matches[m].origin, matches[m].argb);
                }
                fz_close_device(ctx, dev);
                fz_drop_device(ctx, dev);
                dev = NULL;
                append_form(ctx, doc, page, bbox, resources, contents);
                pdf_drop_obj(ctx, resources);
                resources = NULL;
                fz_drop_buffer(ctx, contents);
                contents = NULL;

                out->matches += n;
                out->pages_changed++;
            }
            fz_free(ctx, matches);
            matches = NULL;
            fz_drop_stext_page(ctx, stext);
            stext = NULL;
            fz_drop_page(ctx, (fz_page *)page);
            page = NULL;
        }

        // Scrub the target from every non-page surface: Info dictionary, outline
        // titles, annotation and form-field text, and the XMP packet. Only
        // occurrences of the target change; every other value keeps the same
        // content. That is not the same as whole-file byte identity: the save
        // below (do_garbage=3, do_compress=1) is a full, non-incremental
        // rewrite that renumbers every object and recompresses untouched
        // streams, so only specific fields -- Info dictionary, XMP, /ID and
        // header version -- come out byte-identical (asserted in
        // tests/test_redactor.py; see README.md). Embedded-file streams and
        // appearance streams are not rewritten here; the verification scan
        // below catches the target there and fails closed rather than
        // shipping a file that still contains it.
        out->matches += scrub_metadata_strings(ctx, doc, find, replace);
        out->matches += scrub_xmp(ctx, doc, find, replace);
        // Drop any /ToUnicode CMap that still reconstructs exactly the target
        // after its glyphs were redacted from the page (see
        // scrub_tounicode_cmaps): a target-subset font's glyph-to-Unicode table
        // is the last surface the redaction above does not reach.
        out->matches += scrub_tounicode_cmaps(ctx, doc, replace, needle, needle_len);
        // Drop repair-parked trailer entries the save would otherwise ship.
        sanitize_trailer(ctx, doc);

        // Full non-incremental rewrite: garbage-collects and renumbers every
        // object and recompresses streams. Field-level content is preserved
        // for anything not scrubbed above, but the file's bytes are not --
        // see the comment above and README.md's "What preservation means at
        // the byte level".
        pdf_write_options wopts = pdf_default_write_options;
        wopts.do_garbage = 3;
        wopts.do_compress = 1;
        wopts.do_compress_images = 1;
        // Keep the original /ID so the file is not flagged as modified.
        wopts.dont_regenerate_id = 1;
        // Do not stamp the MuPDF version into the output.
        wopts.reproducible = 1;
        pdf_save_document(ctx, doc, out_path, &wopts);
    }
    fz_always(ctx) {
        fz_free(ctx, matches);
        fz_drop_device(ctx, dev);
        pdf_drop_obj(ctx, resources);
        fz_drop_buffer(ctx, contents);
        pdf_drop_annot(ctx, annot);
        fz_drop_stext_page(ctx, stext);
        fz_drop_page(ctx, (fz_page *)page);
    }
    fz_catch(ctx) {
        snprintf(out->error, sizeof out->error, "%s", fz_caught_message(ctx));
        pdf_drop_document(ctx, doc);
        fz_drop_context(ctx);
        discard_output(out_path);
        return 1;
    }
    pdf_drop_document(ctx, doc);

    // Verify the target no longer appears anywhere in the written file. A scan
    // that cannot run leaves the output unverified, which is a failure: the file
    // is removed and a non-zero code returned rather than reporting success.
    int rc = 0;
    fz_try(ctx) { out->residual = verify_residual(ctx, out_path, find, needle, needle_len); }
    fz_catch(ctx) {
        snprintf(out->error, sizeof out->error, "Output verification could not run: %s",
                 fz_caught_message(ctx));
        rc = 1;
    }

    fz_drop_context(ctx);
    if (rc != 0 || out->residual != 0) {
        discard_output(out_path);
    }
    return rc;
}

#ifdef T4_MAIN
int main(int argc, char **argv) {
    enum { EXPECTED_ARGC = 5 };
    if (argc != EXPECTED_ARGC) {
        fprintf(stderr, "usage: %s in.pdf out.pdf find replace\n", argv[0]);
        return 2;
    }
    T4Result r;
    int rc = t4_replace(argv[1], argv[2], argv[3], argv[4], &r);
    printf("rc=%d matches=%" PRId64 " pages=%d residual=%" PRId64 " error=%s\n", rc, r.matches,
           r.pages_changed, r.residual, r.error);
    return rc || r.residual ? 1 : 0;
}
#endif
