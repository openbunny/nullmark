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
    UTF16_MAX_UNITS = 2,
    NEW_CONTAINER_CAP = 2,
    TEXT_OP_LEN = 2,
    GARBAGE_DEDUPLICATE = 3,
    // Caps every decompressed stream this file scrubs or scans, so a crafted
    // compressed stream cannot force unbounded decompression into memory; an
    // oversized stream fails closed.
    MAX_DECOMPRESSED_STREAM_BYTES = 64 * 1024 * 1024,
    STREAM_READ_CHUNK = 65536,
    // Caps recursion over directly nested dict/array structure, so a crafted
    // object cannot exhaust the call stack; exceeding it fails closed.
    MAX_CONTAINER_DEPTH = 64,
    ID_DIGEST_COUNT = 2,
    HEX_ALPHA_OFFSET = 10,
    NIBBLE_BITS = 4,
    HEX_NIBBLE_MASK = 0xF,
};
static const float CHANNEL_MAX = 255.0f;

// remove()'s result is not checked: every caller is already reporting a failure
// through the return code or a non-zero out->residual, and no recovery exists.
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
            break;
        }
        pdf_dict_del(ctx, trailer, junk);
    }
    // /ID ships as parsed, so it must hold only the two digest strings the
    // format defines. Repairing an unterminated /ID array absorbs the bytes
    // that follow it, page text included, and the scrub never reaches them.
    pdf_obj *id = pdf_dict_get(ctx, trailer, PDF_NAME(ID));
    if (id != NULL && !(pdf_is_array(ctx, id) && pdf_array_len(ctx, id) == ID_DIGEST_COUNT &&
                        pdf_is_string(ctx, pdf_array_get(ctx, id, 0)) &&
                        pdf_is_string(ctx, pdf_array_get(ctx, id, 1)))) {
        fz_throw(ctx, FZ_ERROR_GENERIC, "trailer /ID is not an array of two strings");
    }
}

typedef struct {
    fz_rect rect;
    fz_point origin;
    fz_font *font;
    float size;
    uint32_t argb;
} Match;

// Returns the total codepoint count of `s`. A return greater than `max` means
// `out` holds only the first `max` codepoints.
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

// The caller frees `*out`, which is NULL when the count is 0. The array is
// sized from the page's glyph count, so no occurrence is dropped.
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

// Falls back to a substitute font for any character `font` lacks: the original
// run's font can be a subset holding only the target's glyphs.
static void draw_replacement(fz_context *ctx, fz_device *dev, const char *replacement,
                             fz_font *font, float size, fz_point origin, uint32_t argb) {
    fz_text *text = fz_new_text(ctx);
    fz_try(ctx) {
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
    }
    fz_always(ctx) { fz_drop_text(ctx, text); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}

// A form XObject keeps the replacement's font resources from colliding with
// the page's own resource names.
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
        page_res = pdf_dict_put_dict(ctx, page->obj, PDF_NAME(Resources), NEW_CONTAINER_CAP);
    }
    pdf_obj *xobj = pdf_dict_get(ctx, page_res, PDF_NAME(XObject));
    if (!xobj) {
        xobj = pdf_dict_put_dict(ctx, page_res, PDF_NAME(XObject), NEW_CONTAINER_CAP);
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
        pdf_obj *arr = pdf_new_array(ctx, doc, NEW_CONTAINER_CAP);
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

// A decoded U+0000 would stop every strlen/strstr caller downstream before the
// rest of the value, so scrub and verify both fail closed on it. Names need no
// check: the lexer splits them at a NUL escape. Call before fetching decoded
// text: both convert through shared static buffers.
static int decoded_text_is_nul_truncated(fz_context *ctx, pdf_obj *obj) {
    size_t len = 0;
    const unsigned char *raw = (const unsigned char *)pdf_to_string(ctx, obj, &len);
    if (len >= UTF16_UNIT_BYTES && raw[0] == UTF16BE_BOM_HI && raw[1] == UTF16BE_BOM_LO) {
        for (size_t i = UTF16_UNIT_BYTES; i + 1 < len; i += UTF16_UNIT_BYTES) {
            if (raw[i] == 0 && raw[i + 1] == 0) {
                return 1;
            }
        }
        return 0;
    }
    return memchr(raw, 0, len) != NULL;
}

// Returns a NUL-terminated buffer the caller drops, or NULL when `find` does not
// occur. UTF-8 is self-synchronising, so a byte-level search matches only at
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

// The caller frees the returned buffer.
static unsigned char *encode_utf16(fz_context *ctx, const char *utf8, int little_endian,
                                   size_t *out_len) {
    unsigned char *out = fz_malloc(ctx, (strlen(utf8) * UTF16_UNIT_BYTES) + UTF16_UNIT_BYTES);
    size_t w = 0;
    for (const char *p = utf8; *p != '\0';) {
        int c = 0;
        p += fz_chartorune(&c, p);
        int units[UTF16_MAX_UNITS];
        int n = 1;
        if (c > UTF16_MAX_BMP) {
            int v = c - UTF16_ASTRAL_BASE;
            units[0] =
                (int)((unsigned)UTF16_SURROGATE_HI + ((unsigned)v >> (unsigned)UTF16_HI_SHIFT));
            units[1] =
                (int)((unsigned)UTF16_SURROGATE_LO + ((unsigned)v & (unsigned)UTF16_LO_MASK));
            n = UTF16_MAX_UNITS;
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

static unsigned char *encode_utf16be(fz_context *ctx, const char *utf8, size_t *out_len) {
    return encode_utf16(ctx, utf8, 0, out_len);
}

// A PDF string object never carries little-endian UTF-16, but a raw stream
// (an embedded file, a /JS script, an XFA datasets packet) can.
static unsigned char *encode_utf16le(fz_context *ctx, const char *utf8, size_t *out_len) {
    return encode_utf16(ctx, utf8, 1, out_len);
}

// Returns NULL when the target does not occur. pdf_to_text_string decodes
// PDFDocEncoding and UTF-16BE alike and pdf_new_text_string re-encodes, so both
// PDF string forms and both text encodings are covered.
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

// Returns NULL when the target does not occur. pdf_to_name resolves '#XX'
// escapes and pdf_new_name re-escapes, so a target hidden behind an escape is
// still found.
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

static pdf_obj *scrub_value(fz_context *ctx, pdf_obj *val, const char *find, const char *repl) {
    if (pdf_is_string(ctx, val)) {
        return scrub_string_value(ctx, val, find, repl);
    }
    if (pdf_is_name(ctx, val)) {
        return scrub_name_value(ctx, val, find, repl);
    }
    return NULL;
}

// A dict key is not scrubbed: renaming a key changes which entry a reader finds
// under the standard name. A key bearing the target is caught by the
// verification scan instead, which fails closed. Indirect references are skipped
// so each object is visited once by its own pass and a cycle cannot recur.
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
            pdf_obj *key = pdf_dict_get_key(ctx, obj, i);
            pdf_obj *val = pdf_dict_get_val(ctx, obj, i);
            // An /ID array is the opaque digest pair a cross-reference stream
            // dict carries in place of a trailer. It is not text: decoding it
            // refuses any digest holding a 0x00 byte. count_id_needles reads
            // it raw during verification, so a target inside it still fails
            // closed.
            if (pdf_is_indirect(ctx, val) ||
                (pdf_name_eq(ctx, key, PDF_NAME(ID)) && pdf_is_array(ctx, val))) {
                continue;
            }
            pdf_obj *nw = scrub_value(ctx, val, find, repl);
            if (nw != NULL) {
                pdf_dict_put_drop(ctx, obj, key, nw);
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

// Loading each numbered object reaches strings and names packed into object
// streams as well as top-level ones.
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

// Returns a buffer the caller drops, or NULL when the pattern is absent.
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

// Reads in bounded chunks instead of calling pdf_load_stream_number, which
// decompresses the whole stream before any size can be checked, so a
// compression bomb cannot force an unbounded allocation. Throws past
// MAX_DECOMPRESSED_STREAM_BYTES rather than returning a truncated read.
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

// Writes the packet back uncompressed, and only when the target occurred.
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

// The count is 64-bit because verify_residual sums it over every stream in the
// document, and MAX_DECOMPRESSED_STREAM_BYTES bounds only one stream.
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

// Exceeding MAX_CONTAINER_DEPTH throws, which t4_replace treats as an
// unverifiable output and therefore a failure.
static int64_t scan_container_strings(fz_context *ctx, pdf_obj *obj, const char *find, int depth);

// /ID elements are opaque 128-bit digests, not text, and a random digest holds
// a 0x00 byte about one time in sixteen: a C-string view would stop there, so
// they are counted on raw bytes with explicit lengths.
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

// Cross-reference and object-stream containers hold other objects' bytes, which
// are scanned as individual objects; scanning the container too would
// double-count and could match a structural name.
static int is_structural_stream(fz_context *ctx, pdf_obj *obj) {
    pdf_obj *type = pdf_dict_get(ctx, obj, PDF_NAME(Type));
    return pdf_name_eq(ctx, type, PDF_NAME(ObjStm)) || pdf_name_eq(ctx, type, PDF_NAME(XRef));
}

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

// Skips non-hex bytes inside the literal, as a CMap interpreter does. Returns
// the decoded byte count, which may exceed `cap`. Leaves `*pos` at `len` when
// no '<' remains.
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
                    buf[n] = (unsigned char)(((unsigned)hi << (unsigned)NIBBLE_BITS) | (unsigned)d);
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

// Returns the codepoint count, which may exceed `max`.
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

static void add_unique_codepoint(int *set, int *n, int max, int cp) {
    // *n may exceed max on return as the caller's overflow signal, but set[]
    // has only max slots, so the scan stops at max.
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

// Reads beginbfchar destinations as UTF-16BE (ISO 32000-1 section 9.10.3,
// https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/PDF32000_2008.pdf).
// bfrange blocks are not parsed, so a target mapped only through one is not
// caught here.
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

// True when the bfchar destinations are exactly the target's distinct
// codepoints: the signature of a font subsetted to the target's letters, whose
// glyph-to-Unicode table survives the redaction of those glyphs and still
// spells the target's character set. A font mapping any other codepoint is not
// flagged.
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

static int codepoint_in_set(int cp, const int *set, int n) {
    for (int i = 0; i < n; i++) {
        if (set[i] == cp) {
            return 1;
        }
    }
    return 0;
}

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

// Keeps only the bfchar entries whose destination lies entirely in `keep`, the
// replacement's codepoints. Returns a buffer the caller drops, or NULL when no
// entry is kept. bfrange entries are not carried over: cmap_reveals_target
// does not parse them either, so a CMap reaching here maps the target only
// through bfchar.
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

// Removes the /ToUnicode outright when the filtered CMap is empty or would still
// reveal the target (the replacement's letters cover the target's); the save's
// garbage collection then drops the unreferenced stream.
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

// A Type0 font with no /ToUnicode has no declared way to recover the text its
// codes draw: fz_stext and cmap_reveals_target are both blind to it, so its
// presence is checked, not its content.
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

// "Shows text" is a substring search for Tj or TJ, not a content-stream parse:
// a match inside operand bytes can only add a fail-closed result.
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
        shows_text = count_needle_bytes(data, len, (const unsigned char *)"Tj", TEXT_OP_LEN) > 0 ||
                     count_needle_bytes(data, len, (const unsigned char *)"TJ", TEXT_OP_LEN) > 0;
    }
    fz_always(ctx) { fz_drop_buffer(ctx, buf); }
    fz_catch(ctx) { fz_rethrow(ctx); }
    return shows_text;
}

// Visits every appearance state, not only the one /AS names: every state ships
// in the file, and no appearance stream is rewritten.
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

// pdf_first_annot/pdf_next_annot walk the /Annots array itself, so Hidden and
// NoView annotations are included.
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

// Reopens the written file and counts the target through oracles independent
// of the redaction path: fz_stext page text (blind to /ActualText, hidden
// layers and metadata); every string's and name's decoded text; every
// non-structural stream's decompressed bytes in UTF-8, UTF-16BE and UTF-16LE;
// every ToUnicode CMap that reveals the target; and every appearance stream
// drawn through an unverifiable CID font, which counts as a failure to verify.
// A non-zero result means the target survives, or cannot be shown absent, on
// some surface. A file that will not reopen or reparse throws.
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
        // Repairing a damaged file can park bytes in the trailer that no object
        // pass reaches.
        residual += scan_container_strings(ctx, pdf_trailer(ctx, doc), find, 0);
        // A repaired reopen parses a different structure from the bytes
        // written, so the scans above cannot vouch for those bytes.
        if (pdf_was_repaired(ctx, doc)) {
            fz_throw(ctx, FZ_ERROR_GENERIC, "the written file needed repair to reopen");
        }
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

        // Embedded-file and appearance streams are not rewritten; the
        // verification scan catches the target there and fails closed.
        out->matches += scrub_metadata_strings(ctx, doc, find, replace);
        out->matches += scrub_xmp(ctx, doc, find, replace);
        out->matches += scrub_tounicode_cmaps(ctx, doc, replace, needle, needle_len);
        sanitize_trailer(ctx, doc);

        // A full, non-incremental rewrite: object numbers and stream encodings
        // change even where no value did (README.md, "What preservation means
        // at the byte level").
        pdf_write_options wopts = pdf_default_write_options;
        wopts.do_garbage = GARBAGE_DEDUPLICATE;
        wopts.do_compress = 1;
        wopts.do_compress_images = 1;
        // A regenerated /ID would mark the file as rewritten.
        wopts.dont_regenerate_id = 1;
        // Keeps the MuPDF version number out of the output.
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

    // A scan that cannot run leaves the output unverified, which is a failure.
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
    enum { ARG_IN = 1, ARG_OUT, ARG_FIND, ARG_REPLACE, EXPECTED_ARGC };
    enum { EXIT_USAGE = 2 };
    if (argc != EXPECTED_ARGC) {
        (void)fprintf(stderr, "usage: %s in.pdf out.pdf find replace\n", argv[0]);
        return EXIT_USAGE;
    }
    T4Result r;
    int rc = t4_replace(argv[ARG_IN], argv[ARG_OUT], argv[ARG_FIND], argv[ARG_REPLACE], &r);
    printf("rc=%d matches=%" PRId64 " pages=%d residual=%" PRId64 " error=%s\n", rc, r.matches,
           r.pages_changed, r.residual, r.error);
    return rc || r.residual ? 1 : 0;
}
#endif
