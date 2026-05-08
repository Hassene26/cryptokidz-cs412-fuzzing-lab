#include <stdio.h>
#include <stdlib.h>
#include <png.h>
#include <setjmp.h>

/*
 * libpng fuzzing harness in fork mode.
 *
 * Reads a file path from argv[1], feeds the
 * bytes to libpng's read pipeline, and exits cleanly on success or on any
 * libpng-level error.
 */

int main(int argc, char **argv)
{
    /* Usage error: AFL++ should always provides an input file, so this only fires
     * during manual invocation. */
    if (argc < 2)
        return 1;

    FILE *fp = fopen(argv[1], "rb");
    if (!fp)
    {
        return 0;
    }

    /* Allocate libpng's main read state. The version string lets libpng
     * detect ABI mismatches between our headers and the linked library. */
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png)
    {
        fclose(fp);
        return 0;
    }

    /* Allocate the info struct that holds parsed metadata (dimensions,
     * color type, etc.) after png_read_info() runs. */
    png_infop info = png_create_info_struct(png);
    if (!info)
    {
        png_destroy_read_struct(&png, NULL, NULL);
        fclose(fp);
        return 0;
    }

    /* setjmp guard for libpng's error-handling.
     * On any malformed input, libpng calls png_error() which longjmps back
     * here. Without this, every malformed PNG looks like a real
     * crash to AFL++ and we get a lot of false positives. */
    if (setjmp(png_jmpbuf(png)))
    {
        png_destroy_read_struct(&png, &info, NULL);
        fclose(fp);
        return 0;
    }

    /* Wire libpng to read from our FILE*. */
    png_init_io(png, fp);
    png_read_info(png, info);

    /* Dimension guard. Done immediately after png_read_info (before any
     * png_set_* / png_read_update_info) so we fail fast on absurd headers
     * without triggering libpng's internal per-row allocations. */
    png_uint_32 w = png_get_image_width(png, info);
    png_uint_32 h = png_get_image_height(png, info);
    if (w == 0 || h == 0 || w > 4096 || h > 4096)
    {
        png_destroy_read_struct(&png, &info, NULL);
        fclose(fp);
        return 0;
    }

    /* Enable transformations to maximize coverage. Each one activates
     * additional code paths inside libpng:
     *   - set_expand:       palette/tRNS/sub-byte-gray expansion
     *   - set_strip_16:     16-bit -> 8-bit channel reduction
     *   - set_gray_to_rgb:  grayscale -> RGB channel duplication
     * png_read_update_info recomputes metadata for the post-transform output. */
    png_set_expand(png);
    png_set_strip_16(png);
    png_set_gray_to_rgb(png);
    png_read_update_info(png, info);

    /* Allocate one buffer per scanline. rowbytes must be read AFTER
     * png_read_update_info because the transforms change the row size. */
    png_bytep *rows = malloc(sizeof(png_bytep) * h);
    size_t rowbytes = png_get_rowbytes(png, info);
    for (png_uint_32 i = 0; i < h; i++)
        rows[i] = malloc(rowbytes);

    /* png_read_image: applies the transformations.
     * png_read_end: parses any trailing chunks. */
    png_read_image(png, rows);
    png_read_end(png, NULL);

    for (png_uint_32 i = 0; i < h; i++)
        free(rows[i]);
    free(rows);
    png_destroy_read_struct(&png, &info, NULL);
    fclose(fp);
    return 0;
}