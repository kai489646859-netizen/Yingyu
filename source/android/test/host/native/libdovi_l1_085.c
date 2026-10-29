/* Synthetic/public-RPU CPU checks of the complete pinned upstream LP helper.
 * No decoding, display, GPU or real account/media IO is performed.
 */
#include <libplacebo/utils/dolbyvision.h>
#include <libplacebo/colorspace.h>
#include <libdovi/rpu_parser.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int passed, failed;
static void check(const char *name, int ok) {
    printf("{\"case\":\"%s\",\"passed\":%s}\n", name, ok ? "true" : "false");
    if (ok) passed++; else failed++;
}
static unsigned char *load(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "Missing fixture: %s\n", path); exit(2); }
    fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    if (n <= 0 || n > 262144) exit(2);
    unsigned char *out = malloc((size_t)n);
    if (!out || fread(out, 1, (size_t)n, f) != (size_t)n) exit(2);
    fclose(f); *size = (size_t)n; return out;
}
static void raw(const unsigned char **data, size_t *size) {
    if (*size >= 4 && !memcmp(*data, "\0\0\0\1", 4)) { *data += 4; *size -= 4; }
    else if (*size >= 3 && !memcmp(*data, "\0\0\1", 3)) { *data += 3; *size -= 3; }
    if (*size >= 2 && (*data)[0] == 0x7c && (*data)[1] == 1) { *data += 2; *size -= 2; }
}
static struct pl_hdr_metadata seed(void) {
    return (struct pl_hdr_metadata){ .min_luma = 0.0001f, .max_luma = 4000.0f };
}
static int unchanged(struct pl_hdr_metadata x) {
    return x.min_luma == 0.0001f && x.max_luma == 4000.0f &&
           x.max_pq_y == 0 && x.avg_pq_y == 0;
}
static void valid(const char *name, const char *path, int expected_profile, int reference) {
    size_t size; unsigned char *storage = load(path, &size);
    const unsigned char *data = storage; raw(&data, &size);
    DoviRpuOpaque *rpu = dovi_parse_unspec62_nalu(data, size);
    const DoviRpuDataHeader *h = dovi_rpu_get_header(rpu);
    const DoviVdrDmData *dm = dovi_rpu_get_vdr_dm_data(rpu);
    int valid_rpu = h && !dovi_rpu_get_error(rpu) && h->guessed_profile == expected_profile &&
                    dm && dm->dm_data.level1 && dm->dm_data.level1->max_pq && dm->dm_data.level1->avg_pq;
    if (!valid_rpu) { fprintf(stderr, "Invalid test fixture: %s\n", path); exit(2); }
    if (reference && !h->use_prev_vdr_rpu_flag) { fprintf(stderr, "Not a reference RPU\n"); exit(2); }
    struct pl_hdr_metadata out = seed();
    pl_hdr_metadata_from_dovi_rpu(&out, data, size);
    check(name, fabsf(out.max_pq_y - dm->dm_data.level1->max_pq / 4095.0f) < 1e-6f &&
                fabsf(out.avg_pq_y - dm->dm_data.level1->avg_pq / 4095.0f) < 1e-6f &&
                out.max_luma == 4000.0f && out.min_luma == 0.0001f);
    printf("{\"fixture\":\"%s\",\"profile\":%d,\"use_prev\":%s,\"L1_max_pq\":%u,\"L1_avg_pq\":%u,\"helper_max\":%.9f,\"helper_avg\":%.9f}\n",
           name, expected_profile, h->use_prev_vdr_rpu_flag ? "true" : "false",
           dm->dm_data.level1->max_pq, dm->dm_data.level1->avg_pq, out.max_pq_y, out.avg_pq_y);
    dovi_rpu_free_vdr_dm_data(dm); dovi_rpu_free_header(h); dovi_rpu_free(rpu); free(storage);
}
int main(int argc, char **argv) {
    if (argc != 1) return 2;
    (void)argv;
    valid("profile5_raw_payload", "assets/tests/profile5.bin", 5, 0);
    valid("profile8_raw_payload", "assets/tests/profile8.bin", 8, 0);
    valid("profile84_raw_payload", "assets/tests/profile84.bin", 8, 0);
    valid("reference_p5_with_own_L1", "fixtures/p5-use-prev.bin", 5, 1);

    size_t size; unsigned char *storage = load("assets/tests/mel_variable_l8_length13.bin", &size);
    const unsigned char *data = storage; raw(&data, &size);
    struct pl_hdr_metadata out = seed();
    pl_hdr_metadata_from_dovi_rpu(&out, data, size);
    /* Independently asserted in pinned upstream tests/rpu/export.rs:107. */
    check("upstream_known_L1_3100_2048", fabsf(out.max_pq_y - 3100.0f/4095) < 1e-6f &&
          fabsf(out.avg_pq_y - 2048.0f/4095) < 1e-6f);
    struct pl_color_space csp = {.transfer = PL_COLOR_TRC_PQ, .hdr = out};
    float peak = 0, average = 0;
    pl_color_space_nominal_luma_ex(pl_nominal_luma_params(.color=&csp,
        .metadata=PL_HDR_METADATA_ANY, .scaling=PL_HDR_PQ, .out_max=&peak, .out_avg=&average));
    check("actual_nominal_luma_consumes_L1", fabsf(peak - 3100.0f/4095) < 1e-6f &&
          fabsf(average - 2048.0f/4095) < 1e-6f);
    free(storage);

    storage = load("assets/tests/empty_dmv1_blocks.bin", &size); data=storage; raw(&data,&size);
    DoviRpuOpaque *rpu=dovi_parse_unspec62_nalu(data,size);
    const DoviVdrDmData *dm=dovi_rpu_get_vdr_dm_data(rpu);
    if (!dm || dm->dm_data.level1 || dovi_rpu_get_error(rpu)) return 2;
    out=seed(); pl_hdr_metadata_from_dovi_rpu(&out,data,size);
    check("valid_no_L1_preserves_static_fallback", unchanged(out));
    dovi_rpu_free_vdr_dm_data(dm); dovi_rpu_free(rpu); free(storage);

    storage=load("assets/tests/profile4.bin",&size); data=storage; raw(&data,&size);
    rpu=dovi_parse_unspec62_nalu(data,size);
    const DoviRpuDataHeader *h=dovi_rpu_get_header(rpu);
    if (!h || h->guessed_profile != 4 || dovi_rpu_get_error(rpu)) return 2;
    out=seed(); pl_hdr_metadata_from_dovi_rpu(&out,data,size);
    check("profile4_keeps_upstream_skip", unchanged(out));
    dovi_rpu_free_header(h); dovi_rpu_free(rpu); free(storage);

    storage=load("assets/tests/profile5.bin",&size); data=storage; raw(&data,&size);
    out=seed(); pl_hdr_metadata_from_dovi_rpu(&out,data,12);
    check("truncated_RPU_preserves_fallback", unchanged(out));
    unsigned char *bad=malloc(size); memcpy(bad,data,size); bad[size-2] ^= 1;
    out=seed(); pl_hdr_metadata_from_dovi_rpu(&out,bad,size);
    check("bad_CRC_preserves_fallback", unchanged(out)); free(bad);
    out=seed(); pl_hdr_metadata_from_dovi_rpu(&out,NULL,0);
    check("absent_RPU_preserves_fallback", unchanged(out));
    out=seed(); pl_hdr_metadata_from_dovi_rpu(&out,data,0);
    check("zero_size_preserves_fallback", unchanged(out)); free(storage);
    printf("{\"passed\":%d,\"failed\":%d,\"total\":%d}\n",passed,failed,passed+failed);
    return failed ? 1 : 0;
}
