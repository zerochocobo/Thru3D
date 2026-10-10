"""Generate the small source-frame patch against the exact pinned mpv archive."""
import os
from pathlib import Path
import difflib
import hashlib
import json
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[3]
ARCHIVE = Path(str(Path(os.environ.get('THRU3D_TOOL_ROOT', str(Path.home() / '.cache/thru3d-toolchain'))) / 'linux-build/downloads/mpv-0b7ed67.tar.gz'))
TARGETS = ("video/out/vo_libmpv.c", "video/out/gpu/libmpv_gpu.c",
           "video/out/gpu/video.c", "video/out/gpu/video.h",
           "video/decode/vd_lavc.c", "video/out/hwdec/hwdec_aimagereader.c", "audio/out/buffer.c",
           "video/out/gpu/hwdec.h", "video/out/gpu/shader_cache.c",
           "video/out/gpu/shader_cache.h", "video/out/opengl/common.c")


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"Pinned source anchor changed: {old[:80]}")
    return text.replace(old, new, 1)


def main():
    original = {}
    with tarfile.open(ARCHIVE) as archive:
        for name in TARGETS:
            entry = next(p for p in archive.getnames() if p.endswith("/"+name))
            original[name] = archive.extractfile(entry).read().decode()
    edited = dict(original)
    p = "video/out/vo_libmpv.c"
    s = edited[p]
    s = replace_once(s, '#include "libmpv.h"\n',
                     '#include "libmpv.h"\n#include "include/mpv/quest_frame.h"\n')
    s = replace_once(s, '    struct vo_frame *next_frame;    // next frame to draw\n',
        '    struct vo_frame *next_frame;    // next frame to draw\n'
        '    uint64_t quest_source_epoch, quest_next_epoch, quest_current_epoch;\n'
        '    uint64_t quest_render_sequence;\n')
    # Epochs stay attached to selected images, including old redraws after reset.
    s = replace_once(s, '    struct vo_frame *frame = ctx->next_frame;\n    int64_t wait_present_count',
        '    struct vo_frame *frame = ctx->next_frame;\n'
        '    uint64_t quest_epoch = frame ? ctx->quest_next_epoch : ctx->quest_current_epoch;\n'
        '    int64_t wait_present_count')
    s = replace_once(s, '        ctx->cur_frame = vo_frame_ref(frame);\n',
        '        ctx->cur_frame = vo_frame_ref(frame);\n'
        '        ctx->quest_current_epoch = quest_epoch;\n')
    s = replace_once(s, '    mp_mutex_unlock(&ctx->lock);\n\n    MP_STATS(ctx, "glcb-render");\n',
        '''    quest_mpv_source_frame *quest = get_mpv_render_param(
        params, MPV_RENDER_PARAM_QUEST_SOURCE_FRAME, NULL);
    if (quest) {
        memset(quest, 0, sizeof(*quest));
        quest->struct_size = sizeof(*quest);
        quest->api_version = QUEST_MPV_SOURCE_FRAME_API_VERSION;
        quest->render_sequence = ++ctx->quest_render_sequence;
        if (frame->current) {
            const struct mp_image *image = frame->current;
            quest->flags = QUEST_MPV_HAS_IMAGE |
                (frame->redraw ? QUEST_MPV_REDRAW : 0) |
                (frame->repeat ? QUEST_MPV_REPEAT : 0);
            quest->frame_id = frame->frame_id;
            quest->source_epoch = quest_epoch;
            quest->width = image->w;
            quest->height = image->h;
            quest->crop_x0 = image->params.crop.x0;
            quest->crop_y0 = image->params.crop.y0;
            quest->crop_x1 = image->params.crop.x1;
            quest->crop_y1 = image->params.crop.y1;
            quest->rotation_degrees = image->params.rotate;
            quest->mpv_image_format = image->imgfmt;
            double us = image->pts * 1e6;
            if (image->pts != MP_NOPTS_VALUE && isfinite(us) &&
                us > (double)INT64_MIN && us < (double)INT64_MAX) {
                quest->media_pts_us = llround(us);
                quest->flags |= QUEST_MPV_PTS_VALID;
            }
        }
    }
    mp_mutex_unlock(&ctx->lock);

    MP_STATS(ctx, "glcb-render");
''')
    # Validation must run before mutating GL state or selecting a queued frame.
    anchor = 'int mpv_render_context_render(mpv_render_context *ctx, mpv_render_param *params)\n{\n'
    s = replace_once(s, anchor, anchor+'''    quest_mpv_source_frame *quest_request = get_mpv_render_param(
        params, MPV_RENDER_PARAM_QUEST_SOURCE_FRAME, NULL);
    if (quest_request && (quest_request->struct_size != sizeof(*quest_request) ||
        quest_request->api_version != QUEST_MPV_SOURCE_FRAME_API_VERSION))
        return MPV_ERROR_INVALID_PARAMETER;
''')
    s = replace_once(s, '    ctx->next_frame = vo_frame_ref(frame);\n',
        '    ctx->next_frame = vo_frame_ref(frame);\n'
        '    if (!ctx->quest_source_epoch) ctx->quest_source_epoch = 1;\n'
        '    // VO may queue an old redraw after RESET; preserve its image epoch.\n'
        '    bool retained = frame->current && ctx->cur_frame && ctx->cur_frame->current &&\n'
        '                    frame->frame_id == ctx->cur_frame->frame_id;\n'
        '    ctx->quest_next_epoch = retained ? ctx->quest_current_epoch : ctx->quest_source_epoch;\n')
    s = replace_once(s, '        ctx->cur_frame = ctx->next_frame;\n',
        '        ctx->cur_frame = ctx->next_frame;\n'
        '        ctx->quest_current_epoch = ctx->quest_next_epoch;\n')
    s = replace_once(s, '        forget_frames(ctx, false);\n        ctx->need_reset = true;\n',
        '        forget_frames(ctx, false);\n'
        '        if (!ctx->quest_source_epoch) ctx->quest_source_epoch = 1;\n'
        '        ctx->quest_source_epoch++;\n'
        '        ctx->need_reset = true;\n')
    s += '\nMPV_EXPORT uint32_t mpv_quest_source_frame_api_version(void)\n{\n'
    s += '    return QUEST_MPV_SOURCE_FRAME_API_VERSION;\n}\n'
    edited[p] = s
    p = "video/out/gpu/video.h"
    edited[p] = replace_once(edited[p], 'void gl_video_resize(struct gl_video *p,\n',
        'bool gl_video_quest_source_valid(struct gl_video *p, uint64_t frame_id);\n'
        'void gl_video_resize(struct gl_video *p,\n')
    p = "video/out/gpu/video.c"
    edited[p] = replace_once(edited[p], 'void gl_video_screenshot(struct gl_video *p, struct vo_frame *frame,\n',
        '''bool gl_video_quest_source_valid(struct gl_video *p, uint64_t frame_id)
{
    return !p->broken_frame && !p->is_interpolated && !p->hwdec_overlay &&
        p->image.mpi && p->image.id == frame_id;
}

void gl_video_screenshot(struct gl_video *p, struct vo_frame *frame,
''')
    p = "video/out/gpu/libmpv_gpu.c"
    edited[p] = replace_once(edited[p], '#include "video/out/libmpv.h"\n',
        '#include "video/out/libmpv.h"\n#include "include/mpv/quest_frame.h"\n')
    edited[p] = replace_once(edited[p],
        '    p->context->fns->done_frame(p->context, frame->display_synced);\n\n    return 0;\n',
        '''    p->context->fns->done_frame(p->context, frame->display_synced);
    quest_mpv_source_frame *quest = get_mpv_render_param(
        params, MPV_RENDER_PARAM_QUEST_SOURCE_FRAME, NULL);
    if (quest && frame->current) {
        if (!gl_video_quest_source_valid(p->renderer, frame->frame_id))
            return MPV_ERROR_GENERIC;
        quest->flags |= QUEST_MPV_RENDER_VALID;
    }
    return 0;
''')
    p = "video/decode/vd_lavc.c"
    edited[p] = replace_once(edited[p], '    bool flushing;\n',
        '    bool flushing;\n    bool quest_mediacodec_drained;\n')
    edited[p] = replace_once(edited[p], '    avcodec_free_context(&ctx->avctx);\n',
        '    avcodec_free_context(&ctx->avctx);\n    ctx->quest_mediacodec_drained = false;\n')
    edited[p] = replace_once(edited[p],
        '    if (ctx->avctx && avcodec_is_open(ctx->avctx))\n        avcodec_flush_buffers(ctx->avctx);\n',
        '    // EOF cleanup/reset must not invalidate unmapped surface references.\n'
        '    // send_packet clears this guard before starting a new decode cycle.\n'
        '    if (ctx->avctx && avcodec_is_open(ctx->avctx) && !ctx->quest_mediacodec_drained)\n'
        '        avcodec_flush_buffers(ctx->avctx);\n')
    edited[p] = replace_once(edited[p], '    prepare_decoding(vd);\n\n    if (ctx->wait_for_keyframe > 0 && pkt)',
        '    prepare_decoding(vd);\n'
        '    // Deferred EOS reset: only a new packet or an explicit seek may\n'
        '    // invalidate MediaCodec output still awaiting GPU presentation.\n'
        '    if (pkt && ctx->quest_mediacodec_drained) {\n'
        '        ctx->quest_mediacodec_drained = false;\n'
        '        reset_avctx(vd);\n'
        '    }\n\n    if (ctx->wait_for_keyframe > 0 && pkt)')
    edited[p] = replace_once(edited[p], '            if (!ctx->num_delay_queue)\n                reset_avctx(vd);\n',
        '            // MediaCodec flush invalidates surface outputs still in the VO.\n'
        '            // Preserve the final output until presentation or explicit reset.\n'
        '            if (!ctx->num_delay_queue) {\n'
        '                if (ctx->use_hwdec && avctx->pix_fmt == AV_PIX_FMT_MEDIACODEC) {\n'
        '                    MP_VERBOSE(vd, "Preserving MediaCodec output references at EOF.\\n");\n'
        '                    ctx->quest_mediacodec_drained = true;\n'
        '                }\n'
        '                else\n                    reset_avctx(vd);\n'
        '            }\n')
    edited[p] = replace_once(edited[p],
        '    // Re-send old packets (typically after a hwdec fallback during init).\n',
        '    // After a drained decoder/filter reset, request the next input before\n'
        '    // polling its stale EOF. lavc_process otherwise emits EOF without\n'
        '    // ever feeding the packet that performs our deferred flush. An\n'
        '    // upstream EOF with no packets is still propagated by lavc_process.\n'
        '    if (ctx->quest_mediacodec_drained && !ctx->state.packets_sent)\n'
        '        return AVERROR(EAGAIN);\n\n'
        '    // Re-send old packets (typically after a hwdec fallback during init).\n')
    p = "video/out/hwdec/hwdec_aimagereader.c"
    edited[p] = replace_once(edited[p],
        '''            // HACK: If the buffer has been released already, return fake
            // success to avoid flashing frames of render errors.
            // The VOs need to be fixed to handle this gracefully.
            return err == AVERROR(ENOENT) ? 0 : -1;
''',
        '''            // Never report the previous external texture as this new source.
            return -1;
''')
    edited[p] = replace_once(edited[p],
        '''        // (same hack as above)
        return (ret == AMEDIA_IMGREADER_NO_BUFFER_AVAILABLE && !image_available)
            ? 0 : -1;
''',
        '''        // Missing images are render failures, never successful source maps.
        return -1;
''')
    # API 2 export: hand the mapped AImage to the libmpv caller instead of deleting it on
    # unmap, so the player can sample the decoder's YUV buffer directly (no RGBA copy).
    edited[p] = replace_once(edited[p], '    const int max_images = 3;\n',
        '    // Quest: the libmpv caller may hold several exported images (display + RVM).\n'
        '    const int max_images = 10;\n')
    edited[p] = replace_once(edited[p],
        '    if (p->image) {\n        o->AImage_delete(p->image);\n        p->image = NULL;\n    }\n',
        '    if (p->image) {\n'
        '        // An exported image belongs to the libmpv caller, which deletes it.\n'
        '        if (!mapper->quest_detached)\n'
        '            o->AImage_delete(p->image);\n'
        '        p->image = NULL;\n'
        '    }\n'
        '    mapper->quest_image = mapper->quest_buffer = NULL;\n'
        '    mapper->quest_detached = false;\n')
    edited[p] = replace_once(edited[p], '    mp_assert(hwbuf);\n',
        '    mp_assert(hwbuf);\n'
        '    mapper->quest_image = p->image;\n'
        '    mapper->quest_buffer = hwbuf;\n'
        '    mapper->quest_detached = false;\n')
    p = "video/out/gpu/hwdec.h"
    edited[p] = replace_once(edited[p], '    struct ra_tex *tex[4];\n};\n',
        '    struct ra_tex *tex[4];\n\n'
        '    // Quest export: platform image (AImage*) and buffer of the mapped frame; once\n'
        '    // detached, unmap leaves the image to the libmpv caller.\n'
        '    void *quest_image, *quest_buffer;\n'
        '    bool quest_detached;\n'
        '};\n')
    p = "video/out/gpu/video.h"
    edited[p] = replace_once(edited[p], 'bool gl_video_quest_source_valid(struct gl_video *p, uint64_t frame_id);\n',
        'bool gl_video_quest_source_valid(struct gl_video *p, uint64_t frame_id);\n'
        'bool gl_video_quest_export(struct gl_video *p, uint64_t frame_id, void **image, void **buffer);\n')
    p = "video/out/gpu/video.c"
    edited[p] = replace_once(edited[p], 'void gl_video_screenshot(struct gl_video *p, struct vo_frame *frame,\n',
        """bool gl_video_quest_export(struct gl_video *p, uint64_t frame_id, void **image, void **buffer)
{
    struct ra_hwdec_mapper *m = p->hwdec_mapper;
    if (!gl_video_quest_source_valid(p, frame_id) || !m || !p->image.hwdec_mapped ||
        !m->quest_image || m->quest_detached)
        return false;
    m->quest_detached = true;
    *image = m->quest_image;
    *buffer = m->quest_buffer;
    return true;
}

void gl_video_screenshot(struct gl_video *p, struct vo_frame *frame,
""")
    p = "video/out/gpu/libmpv_gpu.c"
    edited[p] = replace_once(edited[p], '        quest->flags |= QUEST_MPV_RENDER_VALID;\n    }\n',
        '        quest->flags |= QUEST_MPV_RENDER_VALID;\n'
        '        quest_mpv_export *export = get_mpv_render_param(\n'
        '            params, MPV_RENDER_PARAM_QUEST_EXPORT, NULL);\n'
        '        if (export && export->struct_size == sizeof(*export)) {\n'
        '            void *image = NULL, *buffer = NULL;\n'
        '            export->exported = gl_video_quest_export(p->renderer, frame->frame_id, &image, &buffer);\n'
        '            export->image = (uintptr_t)image;\n'
        '            export->hardware_buffer = (uintptr_t)buffer;\n'
        '        }\n'
        '    }\n')
    # Pull AOs that implement hardware pause retain their queued samples. Their
    # remaining device delay must also remain fixed while paused: using end-now
    # reports a falsely advancing audio-pts even though no PCM is being played.
    p = "audio/out/buffer.c"
    edited[p] = replace_once(edited[p],
        '''        int64_t end = p->end_time_ns;
        int64_t now = mp_time_ns();
        driver_delay = MPMAX(0, MP_TIME_NS_TO_S(end - now));
''',
        '''        if (p->paused && p->hw_paused) {
            driver_delay = MPMAX(0, MP_TIME_NS_TO_S(p->queued_time_ns));
        } else {
            int64_t end = p->end_time_ns;
            int64_t now = mp_time_ns();
            driver_delay = MPMAX(0, MP_TIME_NS_TO_S(end - now));
        }
''')
    from dovi_patch import apply_mpv_dovi
    apply_mpv_dovi(edited, replace_once)
    header = (ROOT/"native/mpv/include/mpv/quest_frame.h").read_text(encoding="utf-8")
    edited["include/mpv/quest_frame.h"] = header
    output = ROOT/"native/mpv/patches/0001-quest-source-frame.patch"
    output.parent.mkdir(parents=True, exist_ok=True)
    patch = ""
    for name, text in edited.items():
        patch += "".join(difflib.unified_diff(
            original.get(name, "").splitlines(keepends=True), text.splitlines(keepends=True),
            fromfile="a/"+name if name in original else "/dev/null", tofile="b/"+name))
    output.write_text(patch, encoding="utf-8", newline="\n")
    record = {
        "base_mpv_revision": "0b7ed670f7c353dd3dd4f8ae0fc788a181a15aa6",
        "base_archive_sha256": hashlib.sha256(ARCHIVE.read_bytes()).hexdigest(),
        "base_files_sha256": {p: hashlib.sha256(s.encode()).hexdigest() for p,s in original.items()},
        "patched_files_sha256": {p: hashlib.sha256(s.encode()).hexdigest() for p,s in edited.items()},
        "patch_sha256": hashlib.sha256(patch.encode()).hexdigest(),
        "private_header_sha256": hashlib.sha256(header.encode()).hexdigest(),
        "api_version": 2, "state": "source_patch_generated; build_and_device_validation_pending"
    }
    (output.parent/"source-frame-manifest.json").write_text(json.dumps(record,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(record,indent=2))


if __name__ == "__main__":
    main()
