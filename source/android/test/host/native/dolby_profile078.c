/* Production container parser with synthetic allocation/packet IO; no decoder. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavutil/dovi_meta.h>
#define MP_HANDLE_OOM(p) do { if (!(p)) abort(); } while (0)
#define MP_DBG(d, ...) ((void)(d))
#define MKBETAG(a,b,c,d) ((uint32_t)(a)<<24 | (uint32_t)(b)<<16 | (uint32_t)(c)<<8 | (d))
#define STREAM_VIDEO 1
#define AV_PKT_DATA_DOVI_CONF 29
typedef struct { uint8_t *start; size_t len; } bstr;
struct demuxer { int unused; };
struct sh_stream { int type; };
struct packet { uint8_t *side_data; size_t size; };
struct demux_packet { struct packet *avpacket; };
typedef struct mkv_track {
    AVDOVIDecoderConfigurationRecord *dovi_config;
    struct sh_stream *stream;
} mkv_track_t;
struct ebml_block_addition_mapping {
    int n_block_add_id_type, n_block_add_id_extra_data;
    uint64_t block_add_id_type;
    bstr block_add_id_extra_data;
};
AVDOVIDecoderConfigurationRecord *av_dovi_alloc(size_t *size) {
    *size = sizeof(AVDOVIDecoderConfigurationRecord);
    return calloc(1, *size);
}
static void av_free(void *p) { free(p); }
static int av_packet_add_side_data(struct packet *p, int type, uint8_t *data, size_t size) {
    assert(type == AV_PKT_DATA_DOVI_CONF);
    free(p->side_data); p->side_data = data; p->size = size; return 0;
}
/* YINGYU_MKV_DOVI_HEADER */
int main(void) {
    struct demuxer demuxer = {0};
    struct sh_stream stream = {.type = STREAM_VIDEO};
    struct mkv_track track = {.stream = &stream};
    struct packet packet = {0};
    struct demux_packet dp = {.avpacket = &packet};
    int passed = 0;
    // Ordinary packets have no configuration allocation or mutation.
    yingyu_mkv_dovi_packet(&track, &dp); assert(!packet.side_data); passed++;
    int profiles[] = {1, 5, 7, 8, 9, 10};
    for (size_t i = 0; i < sizeof(profiles)/sizeof(profiles[0]); i++) {
        int profile = profiles[i], level = 37;
        uint16_t flags = (profile << 9) | (level << 3) | 5 | (profile == 7 ? 2 : 0);
        uint8_t data[] = {1, 0, flags >> 8, flags & 255, 0x10};
        struct ebml_block_addition_mapping mappings[] = {
            {0}, // Missing type must not hide a subsequent valid record.
            {1, 1, MKBETAG('u','n','k','n'), {data, sizeof(data)}},
            {1, 1, i % 2 ? MKBETAG('d','v','c','C') : MKBETAG('d','v','v','C'), {data, sizeof(data)}}
        };
        parse_block_addition_mapping(&demuxer, &track, mappings, 3);
        assert(track.dovi_config && track.dovi_config->dv_profile == profile);
        assert(track.dovi_config->dv_level == level);
        assert(track.dovi_config->rpu_present_flag == 1 && track.dovi_config->bl_present_flag == 1);
        assert(track.dovi_config->el_present_flag == (profile == 7));
        assert(track.dovi_config->dv_bl_signal_compatibility_id == 1);
        yingyu_mkv_dovi_packet(&track, &dp);
        assert(packet.size == sizeof(*track.dovi_config));
        assert(!memcmp(packet.side_data, track.dovi_config, packet.size));
        // Packet ownership is independent of the track's next config/lifetime.
        track.dovi_config->dv_profile = 99;
        assert(((AVDOVIDecoderConfigurationRecord *)packet.side_data)->dv_profile == profile);
        passed++;
    }
    uint8_t minimal[] = {1, 0, 0x0a, 5};
    parse_dovi_config(&demuxer, &track, minimal, 4);
    assert(track.dovi_config->dv_profile == 5 && !track.dovi_config->dv_bl_signal_compatibility_id);
    passed++;
    for (size_t size = 0; size < 4; size++) {
        parse_dovi_config(&demuxer, &track, minimal, size);
        assert(track.dovi_config->dv_profile == 5);
    }
    passed++;
    stream.type = 0;
    free(packet.side_data); packet.side_data = NULL;
    yingyu_mkv_dovi_packet(&track, &dp); assert(!packet.side_data); passed++;
    free(track.dovi_config);
    printf("{\"passed\":%d,\"failed\":0}\n", passed);
    return 0;
}
