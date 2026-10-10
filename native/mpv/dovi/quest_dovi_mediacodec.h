/* Profile 5 only: retain small RPU metadata alongside hardware decoding.
 * Match by presentation timestamp, never packet order (HEVC B frames reorder).
 * No pixel decode, CPU image readback or changes to non-Profile-5 packets. */
#include "dovi_rpu.h"
#include "h2645_parse.h"

#define QUEST_DOVI_QUEUE_SIZE 128
typedef struct QuestDoviFrame {
    int64_t pts;
    AVBufferRef *metadata;
} QuestDoviFrame;
typedef struct QuestDoviContext {
    int enabled;
    DOVIContext parser;
    H2645Packet packet;
    QuestDoviFrame frames[QUEST_DOVI_QUEUE_SIZE];
} QuestDoviContext;

static void quest_dovi_flush(QuestDoviContext *s)
{
    for (int n = 0; n < QUEST_DOVI_QUEUE_SIZE; n++)
        av_buffer_unref(&s->frames[n].metadata);
    ff_dovi_ctx_flush(&s->parser);
}

static void quest_dovi_close(QuestDoviContext *s)
{
    quest_dovi_flush(s);
    ff_dovi_ctx_unref(&s->parser);
    ff_h2645_packet_uninit(&s->packet);
}

static void quest_dovi_init(QuestDoviContext *s, AVCodecContext *avctx)
{
    if (avctx->codec_id != AV_CODEC_ID_HEVC)
        return;
    const AVPacketSideData *sd = av_packet_side_data_get(avctx->coded_side_data,
        avctx->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
    if (!sd || sd->size < sizeof(AVDOVIDecoderConfigurationRecord))
        return;
    const AVDOVIDecoderConfigurationRecord *cfg = (const void *)sd->data;
    if (cfg->dv_profile != 5 || !cfg->rpu_present_flag || cfg->el_present_flag)
        return;
    s->enabled = 1;
    s->parser.logctx = avctx;
    s->parser.cfg = *cfg;
    av_log(avctx, AV_LOG_INFO, "Thru3D Profile 5 RPU enabled; MediaCodec pixels retained\n");
}

static int quest_dovi_packet(QuestDoviContext *s, AVCodecContext *avctx,
                             const AVPacket *pkt)
{
    if (!s->enabled)
        return 0;
    if (pkt->pts == AV_NOPTS_VALUE)
        return AVERROR_INVALIDDATA;
    int ret = ff_h2645_packet_split(&s->packet, pkt->data, pkt->size, avctx, 0,
                                   AV_CODEC_ID_HEVC, H2645_FLAG_SMALL_PADDING);
    if (ret < 0)
        return ret;
    int has_rpu = 0, has_vcl = 0;
    for (int n = 0; n < s->packet.nb_nals; n++) {
        const H2645NAL *nal = &s->packet.nals[n];
        has_vcl |= nal->type < 32;
        if (nal->type != 62)
            continue;
        if (has_rpu++ || nal->size <= 2)
            return AVERROR_INVALIDDATA;
        ret = ff_dovi_rpu_parse(&s->parser, nal->data + 2, nal->size - 2,
                               avctx->err_recognition);
        if (ret < 0)
            return ret;
    }
    if (!has_vcl)
        return 0;
    if (!has_rpu) {
        av_log(avctx, AV_LOG_ERROR, "Profile 5 frame has no RPU\n");
        return AVERROR_INVALIDDATA;
    }
    AVDOVIMetadata *metadata = NULL;
    ret = ff_dovi_get_metadata(&s->parser, &metadata);
    if (ret <= 0)
        return ret < 0 ? ret : AVERROR_INVALIDDATA;
    AVBufferRef *buffer = av_buffer_create((uint8_t *)metadata, ret,
                                         av_buffer_default_free, NULL, 0);
    if (!buffer) {
        av_free(metadata);
        return AVERROR(ENOMEM);
    }
    for (int n = 0; n < QUEST_DOVI_QUEUE_SIZE; n++) {
        if (s->frames[n].metadata)
            continue;
        s->frames[n] = (QuestDoviFrame){.pts = pkt->pts, .metadata = buffer};
        return 0;
    }
    av_buffer_unref(&buffer);
    av_log(avctx, AV_LOG_ERROR, "Profile 5 RPU queue overflow\n");
    return AVERROR_INVALIDDATA;
}

static int quest_dovi_frame(QuestDoviContext *s, AVCodecContext *avctx,
                            AVFrame *frame, int ret)
{
    if (!s->enabled || ret < 0)
        return ret;
    for (int n = 0; n < QUEST_DOVI_QUEUE_SIZE; n++) {
        QuestDoviFrame *f = &s->frames[n];
        if (!f->metadata || f->pts != frame->pts)
            continue;
        AVBufferRef *buffer = f->metadata;
        f->metadata = NULL;
        av_frame_remove_side_data(frame, AV_FRAME_DATA_DOVI_METADATA);
        if (!av_frame_new_side_data_from_buf(frame, AV_FRAME_DATA_DOVI_METADATA, buffer)) {
            av_buffer_unref(&buffer);
            return AVERROR(ENOMEM);
        }
        frame->color_range = AVCOL_RANGE_JPEG;
        frame->color_primaries = AVCOL_PRI_BT2020;
        frame->color_trc = AVCOL_TRC_SMPTE2084;
        frame->colorspace = AVCOL_SPC_IPT_C2;
        return 0;
    }
    av_log(avctx, AV_LOG_ERROR, "Profile 5 output has no matching RPU for PTS %"PRId64"\n",
           frame->pts);
    av_frame_unref(frame);
    return AVERROR_INVALIDDATA;
}
