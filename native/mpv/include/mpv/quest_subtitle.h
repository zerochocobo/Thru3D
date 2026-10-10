/* Independent PGS bitmap extension for the pinned mpv client. */
#ifndef QUEST_MPV_SUBTITLE_H
#define QUEST_MPV_SUBTITLE_H
#include <stdint.h>
#include "client.h"
#ifdef __cplusplus
extern "C" {
#endif
#define QUEST_MPV_PGS_API_VERSION 1u
typedef struct quest_mpv_pgs_part {
    const uint8_t *bgra; /* premultiplied; valid only during the callback */
    int32_t stride, width, height;
    int32_t x, y, display_width, display_height;
} quest_mpv_pgs_part;
typedef struct quest_mpv_pgs_frame {
    int32_t canvas_width, canvas_height, track_id, changed;
    int32_t num_parts;
    const quest_mpv_pgs_part *parts;
} quest_mpv_pgs_frame;
typedef void (*quest_mpv_pgs_callback)(void *, const quest_mpv_pgs_frame *);
MPV_EXPORT uint32_t mpv_quest_pgs_api_version(void);
/* Ordinary client API: never call from a renderer/update callback. The callback
 * must copy pixels synchronously and must not call back into any mpv API.
 * Reads the selected PGS decoder even with sub-visibility=no, preserving the
 * clean video used for Alpha/depth inference. Empty cues also invoke callback. */
MPV_EXPORT int mpv_quest_get_pgs(mpv_handle *, int, int, double,
                               quest_mpv_pgs_callback, void *);
#ifdef __cplusplus
}
#endif
#endif
