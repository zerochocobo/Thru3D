/* Appended to player/client.c by the separately verified PGS patch. */
MPV_EXPORT uint32_t mpv_quest_pgs_api_version(void)
{
    return QUEST_MPV_PGS_API_VERSION;
}

MPV_EXPORT int mpv_quest_get_pgs(mpv_handle *ctx, int width, int height,
                               double pts, quest_mpv_pgs_callback callback,
                               void *opaque)
{
    if (!ctx || !callback || width < 1 || height < 1 ||
        width > 4096 || height > 4096 || !isfinite(pts) || pts < 0)
        return MPV_ERROR_INVALID_PARAMETER;
    quest_mpv_pgs_part parts[64];
    quest_mpv_pgs_frame frame = {
        .canvas_width = width, .canvas_height = height, .parts = parts,
    };
    lock_core(ctx);
    struct track *track = ctx->mpctx->current_track[0][STREAM_SUB];
    struct sub_bitmaps *images = NULL;
    if (track && track->d_sub && track->stream &&
        !strcmp(track->stream->codec->codec, "hdmv_pgs_subtitle"))
    {
        frame.track_id = track->user_tid;
        // Hidden bitmap subtitles do not get VO redraws. A paused track switch
        // can fill the decoder queue before its render clock advances; keep
        // feeding the selected decoder at the requested clock without seeking
        // or restarting video/audio. This is nonblocking demux packet reading.
        bool packets_read = false, sub_updated = false;
        sub_read_packets(track->d_sub, pts, true, &packets_read, &sub_updated);
        struct mp_osd_res dim = {.w = width, .h = height, .display_par = 1.0};
        images = sub_get_bitmaps(track->d_sub, dim, SUBBITMAP_BGRA, pts);
        if (images && images->format == SUBBITMAP_BGRA &&
            images->num_parts >= 0 && images->num_parts <= 64)
        {
            frame.changed = images->change_id;
            frame.num_parts = images->num_parts;
            for (int n = 0; n < frame.num_parts; n++) {
                struct sub_bitmap *p = &images->parts[n];
                parts[n] = (quest_mpv_pgs_part){
                    .bgra = p->bitmap, .stride = p->stride,
                    .width = p->w, .height = p->h,
                    .x = p->x, .y = p->y,
                    .display_width = p->dw, .display_height = p->dh,
                };
            }
        }
    }
    callback(opaque, &frame);
    talloc_free(images);
    unlock_core(ctx);
    return 0;
}
