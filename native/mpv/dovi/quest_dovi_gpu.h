/* Included in the pinned vo_gpu renderer. libplacebo generates only the Dolby
 * reshaping/IPT conversion; MPV's existing color management maps PQ to SDR.
 * Profile 5 uses MPV's full-precision HDR intermediate before the SDR FBO;
 * other videos retain the original single-pass renderer. */
#include <libplacebo/shaders/colorspace.h>

static void quest_pass_dovi(struct gl_video *p)
{
    const struct mp_image *image = p->image.mpi;
    struct pl_color_repr repr = image->params.repr;
    repr.sys = PL_COLOR_SYSTEM_DOLBYVISION;
    repr.levels = PL_COLOR_LEVELS_FULL;
    // pass_get_images has already normalized software texture bit packing;
    // GL_EXT_YUV_target returns normalized components for hardware images.
    repr.bits = (struct pl_bit_encoding){0};
    struct pl_shader_params params = {
        .id = 71,
        .glsl = {.version = 300, .gles = true},
        .dynamic_constants = true,
    };
    pl_shader shader = pl_shader_alloc(NULL, &params);
    pl_shader_decode_color_ex(shader, pl_color_decode_args(.repr = &repr));
    const struct pl_shader_res *res = pl_shader_finalize(shader);
    if (!res || !gl_sc_quest_pl_shader(p->sc, res)) {
        MP_ERR(p, "Profile 5 color shader generation failed\n");
        // Mark the render invalid, rather than publish unconverted green pixels.
        p->broken_frame = true;
    }
    pl_shader_free(&shader);
    p->image_params.color = image->params.color;
    p->image_params.color.primaries = PL_COLOR_PRIM_BT_2020;
    p->image_params.color.transfer = PL_COLOR_TRC_PQ;
    p->image_params.light = MP_CSP_LIGHT_DISPLAY;
    p->user_gamma = 1.0;
}
