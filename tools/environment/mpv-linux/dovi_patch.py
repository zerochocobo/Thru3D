"""Reproducible, Profile-5-only additions to the pinned hardware/render path."""
import difflib
import hashlib
import json
import os
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[3]
HEADERS = ROOT / "native/mpv/dovi"


def apply_mpv_dovi(edited, replace):
    p = "video/out/opengl/common.c"
    edited[p] = replace(edited[p], '            DEF_FN(Uniform3f),\n',
                        '            DEF_FN(Uniform3f),\n            DEF_FN(Uniform4f),\n')
    edited["video/quest_dovi_profile.h"] = (HEADERS / "quest_dovi_profile.h").read_text()
    for name in ("quest_dovi_gpu.h", "quest_dovi_shader_cache.h"):
        edited["video/out/gpu/" + name] = (HEADERS / name).read_text()
    p = "video/out/gpu/video.c"
    s = edited[p]
    s = replace(s, '#include "video/out/vo.h"\n',
                '#include "video/out/vo.h"\n#include "video/quest_dovi_profile.h"\n')
    s = replace(s, '        gl_sc_uniform_texture(sc, texture_name, s->tex);\n',
                '        gl_sc_uniform_texture(sc, texture_name, s->tex);\n'
                '        if (s->tex->params.external_oes && quest_dovi_profile5(p->image.mpi))\n'
                '            gl_sc_quest_raw_yuv(sc, texture_name);\n')
    s = replace(s, '// yuv conversion, and any other conversions before main up/down-scaling\n',
                '#include "quest_dovi_gpu.h"\n\n'
                '// yuv conversion, and any other conversions before main up/down-scaling\n')
    s = replace(s, '    // Pre-colormatrix input gamma correction\n',
                '    if (quest_dovi_profile5(p->image.mpi)) {\n'
                '        quest_pass_dovi(p);\n        return;\n    }\n\n'
                '    // Pre-colormatrix input gamma correction\n')
    s = replace(s, '    bool detect_peak = tone_map.compute_peak >= 0 && pl_color_space_is_hdr(&src)\n',
                '    // Profile 5 already supplies frame HDR metadata. Avoid a GPU reduction\n'
                '    // and use the existing analytic tone mapping in the same output draw.\n'
                '    bool detect_peak = !quest_dovi_profile5(p->image.mpi) &&\n'
                '                       tone_map.compute_peak >= 0 && pl_color_space_is_hdr(&src)\n')
    s = replace(s, '    if (!gl_video_quest_source_valid(p, frame_id) || !m || !p->image.hwdec_mapped ||\n',
                '    if (quest_dovi_profile5(p->image.mpi) ||\n'
                '        !gl_video_quest_source_valid(p, frame_id) || !m || !p->image.hwdec_mapped ||\n')
    edited[p] = s
    p = "video/out/vo_libmpv.c"
    edited[p] = replace(edited[p], '#include "include/mpv/quest_frame.h"\n',
                        '#include "include/mpv/quest_frame.h"\n#include "video/quest_dovi_profile.h"\n')
    edited[p] = replace(edited[p], '            quest->frame_id = frame->frame_id;\n',
                        '            if (quest_dovi_profile5(image))\n'
                        '                quest->flags |= QUEST_MPV_DOVI_PROFILE5;\n'
                        '            quest->frame_id = frame->frame_id;\n')
    p = "video/out/gpu/shader_cache.h"
    edited[p] = replace(edited[p], 'struct mp_log;\n',
                        '#include <libplacebo/shaders.h>\n'
                        'bool gl_sc_quest_pl_shader(struct gl_shader_cache *sc, const struct pl_shader_res *res);\n'
                        'void gl_sc_quest_raw_yuv(struct gl_shader_cache *sc, const char *name);\n\n'
                        'struct mp_log;\n')
    # Declare the cache tag before the new API prototypes.
    edited[p] = edited[p].replace('#include <libplacebo/shaders.h>\n',
                                  '#include <libplacebo/shaders.h>\nstruct gl_shader_cache;\n', 1)
    p = "video/out/gpu/shader_cache.c"
    edited[p] = replace(edited[p], 'void gl_sc_uniform_image2D_wo(',
                        '#include "quest_dovi_shader_cache.h"\n\nvoid gl_sc_uniform_image2D_wo(')


def create_ffmpeg_patch():
    archive_path = Path(str(Path(os.environ.get('THRU3D_MPV_DOWNLOADS', str(Path.home() / '.cache/thru3d-mpv/downloads'))) / 'ffmpeg-094a2f8a.tar.gz'))
    names = ("libavcodec/mediacodecdec.c", "configure")
    original = {}
    with tarfile.open(archive_path) as archive:
        members = archive.getnames()
        for name in names:
            entry = next(p for p in members if p.endswith("/" + name))
            original[name] = archive.extractfile(entry).read().decode()
    from create_frame_patch import replace_once as replace
    edited = dict(original)
    p = "libavcodec/mediacodecdec.c"
    s = edited[p]
    s = replace(s, '#include "mediacodecdec_common.h"\n',
                '#include "mediacodecdec_common.h"\n#include "quest_dovi_mediacodec.h"\n')
    s = replace(s, '    int operating_rate;\n', '    int operating_rate;\n    QuestDoviContext quest_dovi;\n')
    s = replace(s, '    ff_mediacodec_dec_close(avctx, s->ctx);\n',
                '    quest_dovi_close(&s->quest_dovi);\n    ff_mediacodec_dec_close(avctx, s->ctx);\n')
    s = replace(s, '    s->ctx->delay_flush = s->delay_flush;\n',
                '    quest_dovi_init(&s->quest_dovi, avctx);\n    s->ctx->delay_flush = s->delay_flush;\n')
    anchor = 'static int mediacodec_receive_frame(AVCodecContext *avctx, AVFrame *frame)\n'
    wrapper = '''static int quest_mediacodec_receive(AVCodecContext *avctx,
                                    MediaCodecContext *s, AVFrame *frame, int wait)
{
    int ret = ff_mediacodec_dec_receive(avctx, s->ctx, frame, wait);
    return quest_dovi_frame(&s->quest_dovi, avctx, frame, ret);
}

'''
    # Only replace callers, before inserting the wrapper's original receive.
    s = s.replace('ff_mediacodec_dec_receive(avctx, s->ctx, frame,',
                  'quest_mediacodec_receive(avctx, s, frame,')
    s = replace(s, anchor, wrapper + anchor)
    s = replace(s, '        ret = ff_decode_get_packet(avctx, &s->buffered_pkt);\n',
                '        ret = ff_decode_get_packet(avctx, &s->buffered_pkt);\n'
                '        if (ret >= 0) {\n'
                '            ret = quest_dovi_packet(&s->quest_dovi, avctx, &s->buffered_pkt);\n'
                '            if (ret < 0)\n                return ret;\n        }\n')
    s = replace(s, '    ff_mediacodec_dec_flush(avctx, s->ctx);\n',
                '    quest_dovi_flush(&s->quest_dovi);\n    ff_mediacodec_dec_flush(avctx, s->ctx);\n')
    edited[p] = s
    p = "configure"
    edited[p] = replace(edited[p],
                        'hevc_mediacodec_decoder_select="hevc_mp4toannexb_bsf hevc_parser"',
                        'hevc_mediacodec_decoder_select="hevc_mp4toannexb_bsf hevc_parser dovi_rpudec"')
    edited["libavcodec/quest_dovi_mediacodec.h"] = (HEADERS / "quest_dovi_mediacodec.h").read_text()
    patch = ''.join(''.join(difflib.unified_diff(
        original.get(name, '').splitlines(keepends=True), source.splitlines(keepends=True),
        fromfile='a/' + name if name in original else '/dev/null', tofile='b/' + name))
        for name, source in edited.items())
    patch_dir = ROOT / "native/mpv/patches"
    (patch_dir / "0002-ffmpeg-profile5-rpu.patch").write_text(patch, encoding="utf-8", newline="\n")
    sha = lambda data: hashlib.sha256(data).hexdigest()
    record = {
        "base_ffmpeg_revision": "094a2f8a2a5e7fa64736e067de224ce28fdf5979",
        "base_archive_sha256": sha(archive_path.read_bytes()),
        "base_files_sha256": {p: sha(s.encode()) for p, s in original.items()},
        "patched_files_sha256": {p: sha(s.encode()) for p, s in edited.items()},
        "patch_sha256": sha(patch.encode()),
        "scope": "HEVC MediaCodec Dolby Vision Profile 5 RPU only; other profiles unchanged",
    }
    (patch_dir / "dovi-rpu-manifest.json").write_text(json.dumps(record, indent=2) + '\n', encoding="utf-8")


if __name__ == "__main__":
    create_ffmpeg_patch()
