/* Profile 5 has no backwards-compatible base layer. Do not opt other profiles
 * into this renderer: they retain the existing playback/Alpha fast paths. */
#include <libavutil/dovi_meta.h>
#include <libavutil/frame.h>
#include <libavutil/buffer.h>

static bool quest_dovi_profile5(const struct mp_image *image)
{
    if (!image || !image->dovi)
        return false;
    for (int n = 0; n < image->num_ff_side_data; n++) {
        const struct mp_ff_side_data *sd = &image->ff_side_data[n];
        if (sd->type != AV_FRAME_DATA_DOVI_METADATA)
            continue;
        const AVDOVIMetadata *md = (const void *)sd->buf->data;
        const AVDOVIRpuDataHeader *h = av_dovi_get_header(md);
        return h->vdr_rpu_profile == 0 && h->bl_video_full_range_flag &&
               h->disable_residual_flag;
    }
    return false;
}
