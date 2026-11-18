// Use VideoLAN's exact UDF path for local files and other callbacks.
#define udf_image_open yd_original_udf_image_open
#include "libbluray/disc/udf_fs.c"
#undef udf_image_open
#include <stdbool.h>

extern bool yd_owns_iso_block_reader(int (*read_blocks)(void *, void *, int, int));
extern uint32_t yd_iso_block_count(void *handle);

static uint32_t yd_stream_block_count(struct udfread_block_input *input)
{
    const UDF_SI *stream = (const UDF_SI *)input;
    return yd_iso_block_count(stream->read_block_handle);
}

void *udf_image_open(const char *path, void *handle,
                     int (*read_blocks)(void *, void *, int, int))
{
    if (!yd_owns_iso_block_reader(read_blocks))
        return yd_original_udf_image_open(path, handle, read_blocks);

    udfread *udf = udfread_init();
    if (!udf) return NULL;

    struct udfread_block_input *input = _stream_input(handle, read_blocks);
    if (input) {
        input->size = yd_stream_block_count;
        if (udfread_open_input(udf, input) == 0)
            return udf;
        input->close(input);
    }
    udfread_close(udf);
    return NULL;
}
