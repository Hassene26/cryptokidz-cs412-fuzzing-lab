#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <png.h>
#include <setjmp.h>

__AFL_FUZZ_INIT();

/* Custom in-memory reader: replaces FILE-based input with a byte buffer.
 * Persistent mode receives input as bytes in shared memory, not as a file. */
typedef struct
{
    const unsigned char *data;
    size_t size;
    size_t pos;
} mem_reader;

static void mem_read_fn(png_structp png, png_bytep out, png_size_t len)
{
    mem_reader *r = (mem_reader *)png_get_io_ptr(png);
    if (!r || r->pos + len > r->size)
    {
        /* Asked for more bytes than we have, raise a libpng error,
         * which longjmps back to setjmp. not a crash but a rejected input. */
        png_error(png, "short read");
        return;
    }
    memcpy(out, r->data + r->pos, len);
    r->pos += len;
}

int main(int argc, char **argv)
{
    /* Deferred fork server: everything ABOVE this line runs once,
     * everything below runs per fuzz iteration. */
    __AFL_INIT();

    /* Pointer to shared input buffer. Constant across iterations;
     * AFL just rewrites the bytes between loops. */
    unsigned char *buf = __AFL_FUZZ_TESTCASE_BUF;

    /* Persistent loop: process up to 10000 (to bound state leaks) inputs in this process,
     * then exit and let AFL fork a fresh one. */
    while (__AFL_LOOP(10000))
    {
        int len = __AFL_FUZZ_TESTCASE_LEN;
        if (len < 8)
            continue; /* PNG signature is 8 bytes, smaller cannot be parse */

        /* accumulates internal state so we re-allocate at every iteration */
        png_structp png = png_create_read_struct(
            PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
        if (!png)
            continue;

        png_infop info = png_create_info_struct(png);
        if (!info)
        {
            png_destroy_read_struct(&png, NULL, NULL);
            continue;
        }

        /* Same setjmp guard as fork-mode: catches png_error longjmps so
         * malformed inputs don't look like crashes. */
        if (setjmp(png_jmpbuf(png)))
        {
            png_destroy_read_struct(&png, &info, NULL);
            continue;
        }

        /* Wire libpng to read from our memory buffer instead of a FILE. */
        mem_reader r = {.data = buf, .size = (size_t)len, .pos = 0};
        png_set_read_fn(png, &r, mem_read_fn);

        png_read_info(png, info);

        /* Dimension guard. Same rationale as fork-mode harness: check
         * immediately after png_read_info so that absurd headers don't
         * trigger libpng's internal allocations during read_update_info. */
        png_uint_32 w = png_get_image_width(png, info);
        png_uint_32 h = png_get_image_height(png, info);
        if (w == 0 || h == 0 || w > 4096 || h > 4096)
        {
            png_destroy_read_struct(&png, &info, NULL);
            continue;
        }

        /* Same coverage-maximizing transformations as fork-mode. */
        png_set_expand(png);
        png_set_strip_16(png);
        png_set_gray_to_rgb(png);
        png_read_update_info(png, info);

        png_bytep *rows = malloc(sizeof(png_bytep) * h);
        size_t rowbytes = png_get_rowbytes(png, info);
        for (png_uint_32 i = 0; i < h; i++)
            rows[i] = malloc(rowbytes);

        png_read_image(png, rows);
        png_read_end(png, NULL);

        /* Cleanup for leaks not to accumulate across iterations. */
        for (png_uint_32 i = 0; i < h; i++)
            free(rows[i]);
        free(rows);
        png_destroy_read_struct(&png, &info, NULL);
    }

    return 0;
}