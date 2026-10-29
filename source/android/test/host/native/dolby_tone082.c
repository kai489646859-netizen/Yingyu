#include <math.h>
#include <stdio.h>
#include <libplacebo/tone_mapping.h>

int main(void) {
    const float peaks[] = {1000, 4000, 10000};
    const float values[] = {1, 10, 50, 100, 203, 1000};
    int count = 0;
    puts("{\"scope\":\"Actual pinned libplacebo CPU tone curves, not GPU pixels or screen luminance\",\"samples\":[");
    for (int p = 0; p < 3; p++) {
        for (int v = 0; v < 6; v++) {
            struct pl_tone_map_params old = {
                .function = &pl_tone_map_bt2390,
                .constants = { PL_TONE_MAP_CONSTANTS },
                .input_scaling = PL_HDR_NITS,
                .output_scaling = PL_HDR_NITS,
                .input_min = 0.005f, .input_max = peaks[p],
                .output_min = 0.203f, .output_max = 203,
            };
            struct pl_tone_map_params standard = old;
            standard.constants.knee_offset = 0.5f;
            float a = pl_tone_map_sample(values[v], &old);
            float b = pl_tone_map_sample(values[v], &standard);
            printf("%s{\"input_peak_nits\":%.0f,\"input_nits\":%.0f,\"old_output_nits\":%.6f,\"spec_knee_output_nits\":%.6f}",
                   count++ ? ",\n" : "", peaks[p], values[v], a, b);
            if (!isfinite(a) || !isfinite(b) || a < 0 || b < 0 ||
                a > 203.01f || b > 203.01f || b + 0.01f < a)
                return 1;
        }
    }
    printf("],\"passed\":%d,\"failed\":0}\n", count);
    return 0;
}
