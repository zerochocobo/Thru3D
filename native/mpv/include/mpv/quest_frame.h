/* Project-specific extension for the pinned mpv source build. */
#ifndef QUEST_MPV_SOURCE_FRAME_H
#define QUEST_MPV_SOURCE_FRAME_H
#include <stdint.h>
#include "client.h"
#include "render.h"
#ifdef __cplusplus
extern "C" {
#endif

#define QUEST_MPV_SOURCE_FRAME_API_VERSION 2u
#define MPV_RENDER_PARAM_QUEST_SOURCE_FRAME ((mpv_render_param_type)0x51530001)
enum quest_mpv_source_frame_flags {
    QUEST_MPV_HAS_IMAGE = 1u << 0,
    QUEST_MPV_PTS_VALID = 1u << 1,
    QUEST_MPV_REDRAW = 1u << 2,
    QUEST_MPV_REPEAT = 1u << 3,
    QUEST_MPV_RENDER_VALID = 1u << 4,
    QUEST_MPV_DOVI_PROFILE5 = 1u << 5
};

/* Output from the SAME render transaction that selects and draws the vo_frame.
 * media_pts_us comes from current->pts, not vo_frame.pts or target display time.
 * source_epoch changes on VOCTRL_RESET; retained old redraws keep their old epoch.
 * RENDER_VALID requires a single successfully uploaded/cached GPU source image;
 * it is not a fence completion, pixel oracle or permission to reuse an FBO.
 * Caller sets struct_size and api_version before every call. 80 bytes on ARM64.
 */
typedef struct quest_mpv_source_frame {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t flags;
    uint64_t frame_id;
    uint64_t source_epoch;
    int64_t media_pts_us;
    uint64_t render_sequence;
    int32_t width, height;
    int32_t crop_x0, crop_y0, crop_x1, crop_y1;
    int32_t rotation_degrees;
    int32_t mpv_image_format;
} quest_mpv_source_frame;

/* Optional, with the source frame param (API 2): hand the decoded MediaCodec image of THIS
 * render to the caller instead of drawing it into an RGBA copy. On success image is an
 * AImage* and hardware_buffer its AHardwareBuffer* (valid while the AImage lives); the caller
 * owns the AImage and must AImage_delete() it once its GPU reads are complete. A frame is
 * exported at most once: redraws of an exported frame report exported = 0.
 * The AImageReader keeps up to 10 images, so callers may hold several at a time.
 */
#define MPV_RENDER_PARAM_QUEST_EXPORT ((mpv_render_param_type)0x51530002)
typedef struct quest_mpv_export {
    uint32_t struct_size;
    uint32_t exported;
    uint64_t image;
    uint64_t hardware_buffer;
} quest_mpv_export;

/* Resolve this symbol before using the private param: stock mpv ignores unknown
 * render params. A missing symbol/version mismatch must disable this backend.
 */
MPV_EXPORT uint32_t mpv_quest_source_frame_api_version(void);
#ifdef __cplusplus
}
static_assert(sizeof(quest_mpv_source_frame) == 80, "Quest source frame ABI");
static_assert(sizeof(quest_mpv_export) == 24, "Quest export ABI");
#endif
#endif
