#pragma once
#include <stdint.h>
#include "libbluray/bluray.h"
#include "libbluray/bdnav/clpi_data.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef void (*yd_clpi_visitor)(void *, uint32_t, uint16_t, uint8_t,
                                const CLPI_CL *);
int yd_visit_playlist_clpi(BLURAY *, uint32_t, void *, yd_clpi_visitor);
#ifdef __cplusplus
}
#endif
