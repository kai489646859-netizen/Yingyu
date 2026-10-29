// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <libavutil/buffer.h>
#include <libavutil/dovi_meta.h>
// -1 invalid/unknown, 0 proven null residual (MEL included), 1 required EL.
static inline int yydv_required_el(const AVBufferRef *b)
{
    if(!b||b->size<sizeof(AVDOVIMetadata))return -1;
    const AVDOVIMetadata *m=(const void*)b->data;
    if(m->header_offset<sizeof(*m)||m->header_offset>b->size||sizeof(AVDOVIRpuDataHeader)>b->size-m->header_offset)return -1;
    if(av_dovi_get_header(m)->disable_residual_flag==1)return 0;
    if(m->mapping_offset<sizeof(*m)||m->mapping_offset>b->size||sizeof(AVDOVIDataMapping)>b->size-m->mapping_offset)return -1;
    const AVDOVIDataMapping *map=av_dovi_get_mapping(m);
    if(map->nlq_method_idc!=AV_DOVI_NLQ_LINEAR_DZ)return 1;
    for(int i=0;i<3;i++)
        if(map->nlq[i].linear_deadzone_slope||map->nlq[i].linear_deadzone_threshold)return 1;
    return 0;
}
