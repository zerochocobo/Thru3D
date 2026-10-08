#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>
#include <GLES2/gl2ext.h>
#include <android/hardware_buffer.h>
#include <jni.h>
#include <android/log.h>
#include <sys/system_properties.h>
#include <cstdio>
#include <algorithm>
#include <array>
#include <cmath>
#include <chrono>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace {
void check_gl(const char* operation) {
    const auto error = glGetError();
    if (error == GL_NO_ERROR) return;
    char message[160];
    std::snprintf(message, sizeof(message), "%s: GL error 0x%04x", operation, error);
    throw std::runtime_error(message);
}
// Touch only private objects and unit zero; restore Godot's actual GL state.
struct State final {
    GLint program, vao, draw_fbo, read_fbo, active, tex2d, oes, sampler, pack, unpack;
    GLint viewport[4];
    GLint pack_alignment, pack_row_length, pack_skip_rows, pack_skip_pixels;
    GLint unpack_alignment, unpack_row_length, unpack_skip_rows, unpack_skip_pixels, unpack_image_height, unpack_skip_images;
    GLboolean mask[4];
    static constexpr std::array<GLenum, 10> toggles{{GL_BLEND, GL_DEPTH_TEST, GL_CULL_FACE, GL_SCISSOR_TEST,
        GL_STENCIL_TEST, GL_DITHER, GL_RASTERIZER_DISCARD, GL_SAMPLE_ALPHA_TO_COVERAGE, GL_SAMPLE_COVERAGE,
        GL_POLYGON_OFFSET_FILL}};
    std::array<GLboolean, toggles.size()> enabled;
    State() {
        glGetIntegerv(GL_CURRENT_PROGRAM, &program); glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw_fbo); glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_fbo);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &active); glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex2d); glGetIntegerv(GL_TEXTURE_BINDING_EXTERNAL_OES, &oes);
        glGetIntegerv(GL_SAMPLER_BINDING, &sampler); glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pack);
        glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &unpack);
        glGetIntegerv(GL_VIEWPORT, viewport); glGetBooleanv(GL_COLOR_WRITEMASK, mask);
        glGetIntegerv(GL_PACK_ALIGNMENT, &pack_alignment); glGetIntegerv(GL_PACK_ROW_LENGTH, &pack_row_length);
        glGetIntegerv(GL_PACK_SKIP_ROWS, &pack_skip_rows); glGetIntegerv(GL_PACK_SKIP_PIXELS, &pack_skip_pixels);
        glGetIntegerv(GL_UNPACK_ALIGNMENT, &unpack_alignment); glGetIntegerv(GL_UNPACK_ROW_LENGTH, &unpack_row_length);
        glGetIntegerv(GL_UNPACK_SKIP_ROWS, &unpack_skip_rows); glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &unpack_skip_pixels);
        glGetIntegerv(GL_UNPACK_IMAGE_HEIGHT, &unpack_image_height); glGetIntegerv(GL_UNPACK_SKIP_IMAGES, &unpack_skip_images);
        for (size_t i = 0; i < toggles.size(); ++i) enabled[i] = glIsEnabled(toggles[i]);
        glBindSampler(0, 0); glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        glPixelStorei(GL_PACK_ALIGNMENT, 1); glPixelStorei(GL_PACK_ROW_LENGTH, 0);
        glPixelStorei(GL_PACK_SKIP_ROWS, 0); glPixelStorei(GL_PACK_SKIP_PIXELS, 0);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1); glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        glPixelStorei(GL_UNPACK_SKIP_ROWS, 0); glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
        glPixelStorei(GL_UNPACK_IMAGE_HEIGHT, 0); glPixelStorei(GL_UNPACK_SKIP_IMAGES, 0);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        for (auto toggle : toggles) glDisable(toggle);
    }
    ~State() {
        glUseProgram(program); glBindVertexArray(vao);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, draw_fbo); glBindFramebuffer(GL_READ_FRAMEBUFFER, read_fbo);
        glViewport(viewport[0], viewport[1], viewport[2], viewport[3]); glColorMask(mask[0], mask[1], mask[2], mask[3]);
        for (size_t i = 0; i < toggles.size(); ++i) { if (enabled[i]) glEnable(toggles[i]); else glDisable(toggles[i]); }
        glBindBuffer(GL_PIXEL_PACK_BUFFER, pack); glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpack);
        glPixelStorei(GL_PACK_ALIGNMENT, pack_alignment); glPixelStorei(GL_PACK_ROW_LENGTH, pack_row_length);
        glPixelStorei(GL_PACK_SKIP_ROWS, pack_skip_rows); glPixelStorei(GL_PACK_SKIP_PIXELS, pack_skip_pixels);
        glPixelStorei(GL_UNPACK_ALIGNMENT, unpack_alignment); glPixelStorei(GL_UNPACK_ROW_LENGTH, unpack_row_length);
        glPixelStorei(GL_UNPACK_SKIP_ROWS, unpack_skip_rows); glPixelStorei(GL_UNPACK_SKIP_PIXELS, unpack_skip_pixels);
        glPixelStorei(GL_UNPACK_IMAGE_HEIGHT, unpack_image_height); glPixelStorei(GL_UNPACK_SKIP_IMAGES, unpack_skip_images);
        glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tex2d); glBindTexture(GL_TEXTURE_EXTERNAL_OES, oes);
        glBindSampler(0, sampler); glActiveTexture(active);
    }
};
constexpr const char* vertex = R"(#version 300 es
out highp vec2 uv;
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    uv = p; gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
})";
constexpr const char* copy_fragment = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
uniform samplerExternalOES source;
uniform mat4 transform;
in highp vec2 uv;
out vec4 result;
void main() { result = vec4(texture(source, (transform * vec4(uv.x, 1.0-uv.y, 0.0, 1.0)).xy).rgb, 1.0); }
)";
// Model input: each output pixel averages a 4x4 grid over its source footprint (eye UV).
// A single bilinear tap at 6-12x decimation aliases fine texture into noise that flickers
// frame to frame; the box average matches the area-resampled offline reference.
constexpr const char* scale_fragment = R"(#version 300 es
precision highp float;
uniform sampler2D source;
uniform vec4 content_rect;
uniform vec4 eye_rect;
uniform vec2 eye_size;
uniform vec2 footprint;
in highp vec2 uv;
out vec4 result;
vec3 tap(vec2 p) {
    p=clamp(p,vec2(0.5)/eye_size,vec2(1.0)-vec2(0.5)/eye_size);
    return texture(source,eye_rect.xy+p*eye_rect.zw).rgb;
}
void main() {
    vec2 p = (uv-content_rect.xy)/content_rect.zw;
    if (any(lessThan(p,vec2(0.0))) || any(greaterThan(p,vec2(1.0)))) { result=vec4(0.0,0.0,0.0,1.0); return; }
    if (max(footprint.x*eye_size.x, footprint.y*eye_size.y) < 1.5) { result=vec4(tap(p),1.0); return; }
    vec3 sum=vec3(0.0);
    for (int j=0;j<4;++j) for (int i=0;i<4;++i) sum+=tap(p+(vec2(float(i),float(j))+0.5)*footprint*0.25-footprint*0.5);
    result=vec4(sum/16.0,1.0);
})";
// Same footprint average on the decoder's own image (YUV through samplerExternalOES); uv_scale
// maps the visible frame into a buffer that may be padded.
constexpr const char* scale_oes_fragment = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
uniform samplerExternalOES source;
uniform vec4 content_rect;
uniform vec4 eye_rect;
uniform vec2 eye_size;
uniform vec2 footprint;
uniform vec2 uv_scale;
in highp vec2 uv;
out vec4 result;
vec3 tap(vec2 p) {
    p=clamp(p,vec2(0.5)/eye_size,vec2(1.0)-vec2(0.5)/eye_size);
    return texture(source,(eye_rect.xy+p*eye_rect.zw)*uv_scale).rgb;
}
void main() {
    vec2 p = (uv-content_rect.xy)/content_rect.zw;
    if (any(lessThan(p,vec2(0.0))) || any(greaterThan(p,vec2(1.0)))) { result=vec4(0.0,0.0,0.0,1.0); return; }
    if (max(footprint.x*eye_size.x, footprint.y*eye_size.y) < 1.5) { result=vec4(tap(p),1.0); return; }
    vec3 sum=vec3(0.0);
    for (int j=0;j<4;++j) for (int i=0;i<4;++i) sum+=tap(p+(vec2(float(i),float(j))+0.5)*footprint*0.25-footprint*0.5);
    result=vec4(sum/16.0,1.0);
})";
constexpr const char* copy_2d_fragment = R"(#version 300 es
precision highp float;
uniform sampler2D source;
in highp vec2 uv; out vec4 result;
void main() { result = vec4(texture(source, uv).rgb, 1.0); }
)";
// Canonical decoder rows, unlike the Android SurfaceTexture transform above.
constexpr const char* freeze_oes_fragment = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
uniform samplerExternalOES source;
uniform vec2 uv_scale;
in highp vec2 uv; out vec4 result;
void main() { result = vec4(texture(source, uv * uv_scale).rgb, 1.0); }
)";
// Realtime 2D->3D stereo, ported from PTMediaServer's soft_shift (offline/two_dvr_gpu.py): forward
// warp with a z-buffer, disocclusion holes filled from the inverse warp, a background-side rim
// cleanup, a seam blend that never smears the occluder, and the in-body sliver cleanup.
// Everything that depends only on the near map (z-buffer winners, holes, rim, blend gate, sliver
// redirects) is built by compute into `map` when the map changes (~10 Hz); every video frame then
// costs one light fragment pass. map texel: x = source x offset, y = z-buffer near (-1 hole),
// z = blend gate (2 = none), w = sliver redirect offset (0 = none).
constexpr const char* warp_common = R"(#version 310 es
precision highp float; precision highp int;
layout(std430, binding = 0) buffer Keys { highp uint keys[]; };
uniform highp sampler2D near_map; // R8 pair mask; the left half is read
uniform ivec2 size;               // eye width/height
uniform ivec2 model;              // model width/height
uniform vec4 content;             // model = content.xy + eye_uv * content.zw
uniform vec2 shift;               // x: half the maximum parallax in px, y: screen-plane near
float tap(int x, int y) { return texelFetch(near_map, ivec2(x, y), 0).r; }
// PTMediaServer _near_at: bilinear between model centres inside the content; with snap, the
// toggle sharpen picks the nearer of the local horizontal min/max so contours become hard edges.
float near_at(int x, int y, bool snap) {
    vec2 lo = ceil(content.xy * vec2(model) - 0.5);
    vec2 hi = max(lo, floor((content.xy + content.zw) * vec2(model) - 0.5));
    vec2 p = clamp((content.xy + (vec2(x, y) + 0.5) / vec2(size) * content.zw) * vec2(model) - 0.5, lo, hi);
    ivec2 a = ivec2(floor(p)); ivec2 b = min(a + 1, ivec2(hi)); vec2 f = p - vec2(a);
    float n = mix(mix(tap(a.x, a.y), tap(b.x, a.y), f.x), mix(tap(a.x, b.y), tap(b.x, b.y), f.x), f.y);
    if (!snap) return n;
    int win = max(1, int(ceil(6.0 * content.z * float(model.x) / float(size.x))));
    float l = n, h = n;
    for (int d = -win; d <= win; ++d) {
        int xx = clamp(a.x + d, int(lo.x), int(hi.x));
        float u = tap(xx, a.y), v = tap(xx, b.y);
        l = min(l, min(u, v)); h = max(h, max(u, v));
    }
    return (n - l) >= (h - n) ? h : l;
}
uint key_at(int x, int y) { return keys[y * 2 * size.x + x]; }
float near_of(uint k) { return k == 0u ? -1.0 : float((k >> 12) - 1u) / 524287.0; }
)";
constexpr const char* warp_clear = R"(
layout(local_size_x = 256) in;
uniform int count;
void main() { int i = int(gl_GlobalInvocationID.x); if (i < count) keys[i] = 0u; }
)";
// fw_zbuf + fw_color in one pass: the key packs priority (near) above the source column, so the
// atomic maximum is both the z-test and the winner.
constexpr const char* warp_scatter = R"(
layout(local_size_x = 8, local_size_y = 8) in;
void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= size.x || p.y >= size.y) return;
    float n = near_at(p.x, p.y, true);
    uint key = ((uint(n * 524287.0 + 0.5) + 1u) << 12) | uint(p.x);
    for (int eye = 0; eye < 2; ++eye) {
        float sgn = eye == 0 ? 1.0 : -1.0;
        int tx = int(floor(float(p.x) + (n - shift.y) * shift.x * sgn + 0.5));
        if (tx >= 0 && tx < size.x) atomicMax(keys[p.y * 2 * size.x + eye * size.x + tx], key);
    }
}
)";
constexpr const char* warp_classify = R"(
layout(local_size_x = 8, local_size_y = 8) in;
layout(rgba16f, binding = 0) writeonly uniform highp image2D map;
uniform int rim;     // background-side rim cleanup width (fw_hole_from_inv)
uniform int fg_win;  // sliver window (fw_fg_bad_local)
void main() {
    ivec2 o = ivec2(gl_GlobalInvocationID.xy);
    int W = size.x;
    if (o.x >= 2 * W || o.y >= size.y) return;
    int eye = o.x / W, ex = o.x - eye * W, lo = eye * W, hi = lo + W;
    uint k = key_at(o.x, o.y);
    float z = near_of(k);
    float src = float(k & 4095u);
    bool inv = k == 0u;
    if (!inv && rim > 0 && z < 0.5) {
        int dir = eye == 0 ? 1 : -1; // toward the gap
        for (int s = 1; s <= rim; ++s) {
            int nx = o.x + dir * s;
            if (nx < lo || nx >= hi) break;
            if (key_at(nx, o.y) == 0u) { inv = true; break; }
        }
    }
    if (inv) {
        float n = near_at(ex, o.y, false);
        src = clamp(float(ex) + (eye == 0 ? -1.0 : 1.0) * (n - shift.y) * shift.x, 0.0, float(W - 1));
    }
    float gate = 2.0;
    if (k == 0u) {
        float nmin = 2.0, nmax = -1.0;
        for (int dy = -2; dy <= 2; ++dy) {
            int ny = clamp(o.y + dy, 0, size.y - 1);
            for (int dx = -3; dx <= 3; ++dx) {
                int nx = o.x + dx;
                if (nx < lo || nx >= hi) continue;
                uint nk = key_at(nx, ny);
                if (nk != 0u) { float nr = near_of(nk); nmin = min(nmin, nr); nmax = max(nmax, nr); }
            }
        }
        if (nmax - nmin > 0.30) gate = 0.5 * (nmin + nmax);
    }
    float pick = 0.0;
    if (fg_win > 0 && !(k != 0u && z >= 0.5)) {
        int l = -1, r = -1;
        for (int s = 1; s <= fg_win; ++s) {
            int nx = o.x - s; if (nx < lo) break;
            uint nk = key_at(nx, o.y);
            if (nk != 0u && near_of(nk) >= 0.5) { l = nx; break; }
        }
        if (l >= 0) for (int s = 1; s <= fg_win; ++s) {
            int nx = o.x + s; if (nx >= hi) break;
            uint nk = key_at(nx, o.y);
            if (nk != 0u && near_of(nk) >= 0.5) { r = nx; break; }
        }
        if (l >= 0 && r >= 0) pick = float(((o.x - l) <= (r - o.x) ? l : r) - o.x);
    }
    imageStore(map, o, vec4(src - float(ex), z, gate, pick));
}
)";
// Per frame, one pass: every output texel takes its source colour (winner column, or the inverse
// warp); holes get fw_blend (7x5, the occluder excluded across a depth step) and fw_fg_bad_local
// slivers the colour of their nearest enclosing foreground. Neighbours are resolved through the
// map too, so no intermediate image is written.
constexpr const char* warp_frame_body = R"(
uniform highp sampler2D map;
uniform vec2 uv_scale;
uniform ivec2 size;
out vec4 result;
vec3 colour(ivec2 o, vec4 m) {
    int ex = o.x >= size.x ? o.x - size.x : o.x;
    return texture(source, vec2((float(ex) + m.x + 0.5) / float(size.x), (float(o.y) + 0.5) / float(size.y)) * uv_scale).rgb;
}
void main() {
    ivec2 o = ivec2(gl_FragCoord.xy);
    vec4 m = texelFetch(map, o, 0);
    if (m.w != 0.0) {
        ivec2 q = o + ivec2(int(m.w), 0);
        result = vec4(colour(q, texelFetch(map, q, 0)), 1.0);
        return;
    }
    vec3 c = colour(o, m);
    if (m.y >= 0.0) { result = vec4(c, 1.0); return; }
    int lo = o.x >= size.x ? size.x : 0, hi = lo + size.x;
    vec3 sum = vec3(0.0); float n = 0.0;
    for (int dy = -2; dy <= 2; ++dy) {
        int ny = clamp(o.y + dy, 0, size.y - 1);
        for (int dx = -3; dx <= 3; ++dx) {
            int nx = o.x + dx;
            if (nx < lo || nx >= hi) continue;
            vec4 nm = texelFetch(map, ivec2(nx, ny), 0);
            if (nm.y >= 0.0 && nm.y > m.z) continue;
            sum += colour(ivec2(nx, ny), nm); n += 1.0;
        }
    }
    vec3 blur = n > 0.0 ? sum / n : c;
    result = vec4(c * 0.65 + blur * 0.35, 1.0);
})";
constexpr const char* warp_frame_2d = R"(#version 300 es
precision highp float; precision highp int;
uniform sampler2D source;
)";
constexpr const char* warp_frame_oes = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float; precision highp int;
uniform samplerExternalOES source;
)";
GLuint shader(GLenum kind, const char* source) {
    const GLuint id = glCreateShader(kind);
    glShaderSource(id, 1, &source, nullptr); glCompileShader(id);
    GLint passed = 0; glGetShaderiv(id, GL_COMPILE_STATUS, &passed);
    if (!passed) {
        char log[1024]{}; glGetShaderInfoLog(id, sizeof(log), nullptr, log); glDeleteShader(id);
        throw std::runtime_error(std::string("Render bridge shader: ") + log);
    }
    return id;
}
GLuint program(const char* fragment) {
    const auto vs = shader(GL_VERTEX_SHADER, vertex);
    GLuint fs = 0;
    try { fs = shader(GL_FRAGMENT_SHADER, fragment); }
    catch (...) { glDeleteShader(vs); throw; }
    const auto id = glCreateProgram(); glAttachShader(id, vs); glAttachShader(id, fs); glLinkProgram(id);
    glDeleteShader(vs); glDeleteShader(fs);
    GLint passed = 0; glGetProgramiv(id, GL_LINK_STATUS, &passed);
    if (!passed) { glDeleteProgram(id); throw std::runtime_error("Render bridge program linking failed"); }
    return id;
}
GLuint compute_program(const char* body) {
    const std::string source = std::string(warp_common) + body;
    const auto cs = shader(GL_COMPUTE_SHADER, source.c_str());
    const auto id = glCreateProgram(); glAttachShader(id, cs); glLinkProgram(id); glDeleteShader(cs);
    GLint passed = 0; glGetProgramiv(id, GL_LINK_STATUS, &passed);
    if (!passed) { glDeleteProgram(id); throw std::runtime_error("Render bridge compute linking failed"); }
    return id;
}
GLuint warp_frame_program(const char* header) { return program((std::string(header) + warp_frame_body).c_str()); }
void image(GLuint& id, int width, int height, GLenum format = GL_RGBA8) {
    glGenTextures(1, &id); glBindTexture(GL_TEXTURE_2D, id);
    glTexStorage2D(GL_TEXTURE_2D, 1, format, width, height);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}
// Zero-copy: an RGBA8 AHardwareBuffer that GL renders/samples through an EGLImage and
// MNN OpenCL imports directly. CPU usage bits keep the layout linear for that import.
struct SharedImage {
    AHardwareBuffer* buffer = nullptr;
    EGLImageKHR image = EGL_NO_IMAGE_KHR;
    GLuint texture = 0;
};
struct EglImageApi {
    PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC client = nullptr;
    PFNEGLCREATEIMAGEKHRPROC create = nullptr;
    PFNEGLDESTROYIMAGEKHRPROC destroy = nullptr;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC target = nullptr;
    EglImageApi() {
        client = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(eglGetProcAddress("eglGetNativeClientBufferANDROID"));
        create = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
        destroy = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
        target = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    }
    bool available() const { return client && create && destroy && target; }
};
const EglImageApi& egl_image() { static const EglImageApi api; return api; }
// GPU time of the 2D->3D passes (EXT_disjoint_timer_query), for stats only.
struct TimerApi {
    PFNGLGENQUERIESEXTPROC gen = nullptr;
    PFNGLBEGINQUERYEXTPROC begin = nullptr;
    PFNGLENDQUERYEXTPROC end = nullptr;
    PFNGLGETQUERYOBJECTUIVEXTPROC get = nullptr;
    PFNGLGETQUERYOBJECTUI64VEXTPROC get64 = nullptr;
    TimerApi() {
        const auto* extensions = reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));
        if (!extensions || !std::strstr(extensions, "GL_EXT_disjoint_timer_query")) return;
        gen = reinterpret_cast<PFNGLGENQUERIESEXTPROC>(eglGetProcAddress("glGenQueriesEXT"));
        begin = reinterpret_cast<PFNGLBEGINQUERYEXTPROC>(eglGetProcAddress("glBeginQueryEXT"));
        end = reinterpret_cast<PFNGLENDQUERYEXTPROC>(eglGetProcAddress("glEndQueryEXT"));
        get = reinterpret_cast<PFNGLGETQUERYOBJECTUIVEXTPROC>(eglGetProcAddress("glGetQueryObjectuivEXT"));
        get64 = reinterpret_cast<PFNGLGETQUERYOBJECTUI64VEXTPROC>(eglGetProcAddress("glGetQueryObjectui64vEXT"));
    }
    bool available() const { return gen && begin && end && get && get64; }
};
const TimerApi& timers() { static const TimerApi api; return api; }
// One query in flight per measured stage; a stage is skipped while its last result is pending.
struct GpuTimer {
    GLuint query = 0;
    bool pending = false, active = false;
    double ms = 0; uint64_t samples = 0;
    void collect() {
        const auto& api = timers();
        if (!pending) return;
        GLuint ready = 0; api.get(query, GL_QUERY_RESULT_AVAILABLE_EXT, &ready);
        if (!ready) return;
        GLuint64 ns = 0; api.get64(query, GL_QUERY_RESULT_EXT, &ns);
        pending = false;
        GLint disjoint = 0; glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);
        if (disjoint) return;
        ms = samples ? ms * 0.9 + ns / 1e6 * 0.1 : ns / 1e6; samples++;
    }
    void start() {
        const auto& api = timers();
        if (!api.available()) return;
        collect();
        if (pending) return;
        if (!query) api.gen(1, &query);
        api.begin(GL_TIME_ELAPSED_EXT, query); active = true;
    }
    void stop() { if (active) { timers().end(GL_TIME_ELAPSED_EXT); active = false; pending = true; } }
};
SharedImage make_shared_image(int width, int height, uint64_t usage) {
    check_gl("Before zero-copy image allocation");
    // Scout outputs can be allocated by zeroCopyBuffers(), outside a capture's
    // State guard. Never leave a private texture bound in Godot's active unit.
    State state;
    const auto& api = egl_image();
    if (!api.available()) throw std::runtime_error("EGLImage/AHardwareBuffer interop unavailable");
    SharedImage result;
    AHardwareBuffer_Desc desc{};
    desc.width = static_cast<uint32_t>(width); desc.height = static_cast<uint32_t>(height); desc.layers = 1;
    desc.format = AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM; desc.usage = usage;
    if (AHardwareBuffer_allocate(&desc, &result.buffer) != 0 || !result.buffer)
        throw std::runtime_error("Zero-copy AHardwareBuffer allocation failed");
    const EGLint attributes[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
    result.image = api.create(eglGetCurrentDisplay(), EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID,
                              api.client(result.buffer), attributes);
    if (result.image == EGL_NO_IMAGE_KHR) { AHardwareBuffer_release(result.buffer); throw std::runtime_error("Zero-copy EGLImage creation failed"); }
    try {
        glGenTextures(1, &result.texture); glBindTexture(GL_TEXTURE_2D, result.texture);
        check_gl("Zero-copy texture name binding");
        api.target(GL_TEXTURE_2D, static_cast<GLeglImageOES>(result.image));
        check_gl("Zero-copy EGLImage binding");
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        check_gl("Zero-copy texture parameters");
    } catch (...) {
        if (result.texture) glDeleteTextures(1, &result.texture);
        api.destroy(eglGetCurrentDisplay(), result.image);
        AHardwareBuffer_release(result.buffer);
        throw;
    }
    return result;
}
void destroy_shared_image(SharedImage& image) {
    if (image.texture) glDeleteTextures(1, &image.texture);
    if (image.image != EGL_NO_IMAGE_KHR) egl_image().destroy(eglGetCurrentDisplay(), image.image);
    if (image.buffer) AHardwareBuffer_release(image.buffer);
    image = {};
}
constexpr uint64_t kInputUsage = AHARDWAREBUFFER_USAGE_GPU_FRAMEBUFFER | AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE |
                                 AHARDWAREBUFFER_USAGE_CPU_READ_RARELY;
constexpr uint64_t kOutputUsage = AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | AHARDWAREBUFFER_USAGE_CPU_READ_RARELY |
                                  AHARDWAREBUFFER_USAGE_CPU_WRITE_RARELY;
enum class Phase { free, copying, held, retiring };
struct Slot {
    GLuint color = 0, alpha = 0;
    // Borrowed color: the producer's own immutable texture, kept leased by the owner until this
    // slot retires, instead of a full-resolution copy into `color` (allocated only when copying).
    GLuint borrowed = 0;
    GLuint source() const { return borrowed ? borrowed : color; }
    // Decoder image (MPV direct mode): an external OES texture over the MediaCodec buffer the
    // owner keeps leased; Godot samples the same EGLImage. Released when the slot is free.
    EGLImageKHR decoder_image = EGL_NO_IMAGE_KHR;
    GLuint decoder_texture = 0;
    std::array<float, 2> uv_scale{{1.f, 1.f}};
    std::array<GLuint, 2> pbo{{0, 0}};
    std::array<GLuint, 2> scout_pbo{{0, 0}}; // ROI: full-eye input staged from the same color
    bool scout_staged = false;
    std::array<SharedImage, 2> zc_in, zc_out, zc_scout_in; // zero-copy, allocated on first use
    GLsync fence = nullptr, alpha_fence = nullptr;
    bool alpha_valid = false;
    std::vector<unsigned char> near; // last uploaded mask bytes (2D->3D: the near map)
    GLuint warp = 0;                 // 2D->3D stereo pair (2W x H) of this color
    bool opaque_cached = false, opaque_pending = false;
    Phase phase = Phase::free;
    jlong token = 0;
};
struct Bridge final {
    const EGLContext context = eglGetCurrentContext();
    const std::thread::id thread = std::this_thread::get_id();
    const int width, height, input_width, input_height;
    // 0 mono, 1 side by side (left half first), 2 top-bottom (top half first; canonical row 0 is top).
    const int layout;
    bool abandoned = false;
    GLuint oes = 0, copy = 0, copy_2d = 0, scale = 0, scale_oes = 0, freeze_oes = 0, vao = 0, fbo = 0, small = 0;
    // Display, retiring, inference, pending and staging can overlap; with borrowed colors a slot is
    // only the model inputs and the R8 mask, so five cost little. 2D->3D keeps each slot until its
    // stereo pair is rendered: two more slots keep 60 fps sources from running out.
    std::array<Slot, 7> slots;
    uint64_t copies = 0, opaque_copies = 0, opaque_uploads = 0, alpha_uploads = 0;
    uint64_t input_stages = 0, copy_pending_polls = 0, retire_pending_polls = 0, slot_exhaustions = 0;
    std::array<float, 4> content_rect{{0, 0, 1, 1}};
    bool zero_copy = false;
    bool borrow = false; // capture_texture keeps the producer texture instead of copying it
    uint64_t borrows = 0, decoder_captures = 0;
    std::array<SharedImage, 2> zc_scout_out; // one scout runs at a time; read on the CPU right after
    uint64_t zero_copy_commits = 0;
    // 2D->3D stereo (mono sources only): see warp_common.
    GLuint warp_keys = 0, warp_map = 0;
    GLuint warp_clear_prog = 0, warp_scatter_prog = 0, warp_classify_prog = 0, warp_frame_2d_prog = 0, warp_frame_oes_prog = 0;
    bool warp_failed = false;
    std::vector<unsigned char> map_near; // near map the current `warp_map` was built from
    float map_half = -1.f, map_convergence = -1.f;
    uint64_t warp_frames = 0, warp_maps = 0;
    GpuTimer map_timer, frame_timer;
    Bridge(int w, int h, int iw, int ih, int l) : width(w), height(h), input_width(iw), input_height(ih), layout(l) {}
    float eye_width() const { return width / (layout == 1 ? 2.f : 1.f); }
    float eye_height() const { return height / (layout == 2 ? 2.f : 1.f); }
    void eye_rect(GLuint prog, int eye) const {
        if (layout == 1) glUniform4f(glGetUniformLocation(prog, "eye_rect"), eye * 0.5f, 0.f, 0.5f, 1.f);
        else if (layout == 2) glUniform4f(glGetUniformLocation(prog, "eye_rect"), 0.f, eye * 0.5f, 1.f, 0.5f);
        else glUniform4f(glGetUniformLocation(prog, "eye_rect"), 0.f, 0.f, 1.f, 1.f);
    }
    void current() const {
        if (context == EGL_NO_CONTEXT || context != eglGetCurrentContext() || thread != std::this_thread::get_id())
            throw std::runtime_error("Render bridge requires its owner GL thread/context");
    }
    void allocate() {
        current(); State state;
        GLint maximum = 0; glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maximum);
        if (width > maximum || height > maximum) throw std::runtime_error("Source exceeds GL texture limit");
        copy = program(copy_fragment); copy_2d = program(copy_2d_fragment); scale = program(scale_fragment);
        glGenVertexArrays(1, &vao); glGenFramebuffers(1, &fbo); glGenTextures(1, &oes);
        glBindTexture(GL_TEXTURE_EXTERNAL_OES, oes);
        glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        image(small, input_width, input_height);
        const GLsizeiptr bytes = static_cast<GLsizeiptr>(input_width) * input_height * 4;
        for (auto& slot : slots) {
            glGenBuffers(2, slot.pbo.data());
            for (auto pbo : slot.pbo) { glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo); glBufferData(GL_PIXEL_PACK_BUFFER, bytes, nullptr, GL_STREAM_READ); }
        }
        const float source_aspect = eye_width() / eye_height();
        const float input_aspect = static_cast<float>(input_width) / input_height;
        if (source_aspect > input_aspect) { content_rect[3] = input_aspect / source_aspect; content_rect[1] = (1.f-content_rect[3])*0.5f; }
        else { content_rect[2] = source_aspect / input_aspect; content_rect[0] = (1.f-content_rect[2])*0.5f; }
        if (glGetError() != GL_NO_ERROR) throw std::runtime_error("Render bridge allocation GL error");
    }
    ~Bridge() {
        if (abandoned || context != eglGetCurrentContext() || thread != std::this_thread::get_id()) return; // Dead context: names must never be deleted in a new one.
        for (auto& slot : slots) {
            if (slot.fence) glDeleteSync(slot.fence);
            if (slot.alpha_fence) glDeleteSync(slot.alpha_fence);
            glDeleteBuffers(2, slot.pbo.data()); glDeleteTextures(1, &slot.color); glDeleteTextures(1, &slot.alpha);
            if (slot.warp) glDeleteTextures(1, &slot.warp);
            if (slot.scout_pbo[0]) glDeleteBuffers(2, slot.scout_pbo.data());
            for (auto* set : {&slot.zc_in, &slot.zc_out, &slot.zc_scout_in}) for (auto& image : *set) destroy_shared_image(image);
            release_decoder(slot);
        }
        for (auto& image : zc_scout_out) destroy_shared_image(image);
        glDeleteTextures(1, &small); glDeleteTextures(1, &oes); glDeleteFramebuffers(1, &fbo); glDeleteVertexArrays(1, &vao);
        if (copy) glDeleteProgram(copy);
        if (copy_2d) glDeleteProgram(copy_2d);
        if (scale) glDeleteProgram(scale);
        if (scale_oes) glDeleteProgram(scale_oes);
        if (freeze_oes) glDeleteProgram(freeze_oes);
        if (warp_keys) glDeleteBuffers(1, &warp_keys);
        if (warp_map) glDeleteTextures(1, &warp_map);
        for (GLuint prog : {warp_clear_prog, warp_scatter_prog, warp_classify_prog, warp_frame_2d_prog, warp_frame_oes_prog})
            if (prog) glDeleteProgram(prog);
    }
    static void release_decoder(Slot& slot) {
        if (slot.decoder_texture) glDeleteTextures(1, &slot.decoder_texture);
        if (slot.decoder_image != EGL_NO_IMAGE_KHR) egl_image().destroy(eglGetCurrentDisplay(), slot.decoder_image);
        slot.decoder_texture = 0; slot.decoder_image = EGL_NO_IMAGE_KHR; slot.uv_scale = {{1.f, 1.f}};
    }
    void target(GLuint texture, int w, int h) {
        glBindFramebuffer(GL_FRAMEBUFFER, fbo); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) throw std::runtime_error("Render bridge framebuffer incomplete");
        glViewport(0, 0, w, h); glBindVertexArray(vao);
    }
    bool poll(Slot& slot) {
        if (!slot.fence) return slot.phase == Phase::held;
        const auto result = glClientWaitSync(slot.fence, 0, 0);
        if (result == GL_WAIT_FAILED) throw std::runtime_error("Render bridge fence failed");
        if (result != GL_ALREADY_SIGNALED && result != GL_CONDITION_SATISFIED) {
            if (slot.phase == Phase::copying) copy_pending_polls++;
            else if (slot.phase == Phase::retiring) retire_pending_polls++;
            return false;
        }
        glDeleteSync(slot.fence); slot.fence = nullptr;
        slot.phase = slot.phase == Phase::copying ? Phase::held : Phase::free;
        if (slot.phase == Phase::free) release_decoder(slot);
        if (slot.phase == Phase::held && slot.opaque_pending) slot.alpha_valid = true;
        return slot.phase == Phase::held;
    }
    Slot& find(jlong token) {
        for (auto& slot : slots) if (token > 0 && slot.token == token && slot.phase != Phase::free) return slot;
        throw std::runtime_error("Render bridge lease stale/unknown");
    }
    jlong capture(const GLfloat* transform, jlong token) {
        current(); State state;
        Slot* free = nullptr;
        // retired() is the owner's acknowledgement of the release fence. A
        // signalled fence alone must not let capture overwrite its old token
        // while the caller still keeps that token in its retirement set.
        for (auto& slot : slots) { if (slot.phase == Phase::free && !free) free = &slot; }
        if (!free) return 0;
        free->alpha_valid = false;
        free->opaque_pending = false;
        free->borrowed = 0;
        if (!free->color) image(free->color, width, height);
        target(free->color, width, height); glUseProgram(copy); glBindTexture(GL_TEXTURE_EXTERNAL_OES, oes);
        glUniform1i(glGetUniformLocation(copy, "source"), 0); glUniformMatrix4fv(glGetUniformLocation(copy, "transform"), 1, GL_FALSE, transform);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        return stage(*free, token);
    }
    jlong capture_texture(GLuint source, jlong token, bool inputs, bool opaque = false,
                          const float* window = nullptr, bool scout = false) {
        current(); State state;
        if (!source || !glIsTexture(source)) throw std::runtime_error("Shared MPV color texture unavailable");
        Slot* free = nullptr;
        for (auto& slot : slots) {
            if (slot.phase == Phase::free && !free) free = &slot;
        }
        if (!free) { slot_exhaustions++; return 0; }
        free->alpha_valid = false;
        free->opaque_pending = opaque;
        if (borrow) {
            // The owner keeps the producer lease until this slot retires; staging samples it directly.
            free->borrowed = source; borrows++;
        } else {
            free->borrowed = 0;
            if (!free->color) image(free->color, width, height);
            target(free->color, width, height); glUseProgram(copy_2d);
            glBindTexture(GL_TEXTURE_2D, source); glUniform1i(glGetUniformLocation(copy_2d, "source"), 0);
            // The producer lease lasts until a consumer-context fence after this copy.
            // MPV FLIP_Y=0 already stores source top rows at GL y=0.
            glDrawArrays(GL_TRIANGLES, 0, 3);
            copies++;
        }
        if (opaque) {
            if (inputs) throw std::runtime_error("Opaque capture cannot stage inference inputs");
            if (!free->opaque_cached) {
                if (!free->alpha) image(free->alpha, input_width*2, input_height, GL_R8);
                std::vector<unsigned char> mask(static_cast<size_t>(input_width)*input_height*2, 255);
                glBindTexture(GL_TEXTURE_2D, free->alpha);
                glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, input_width*2, input_height, GL_RED, GL_UNSIGNED_BYTE, mask.data());
                free->opaque_cached = true; opaque_uploads++;
            }
            opaque_copies++;
        }
        free->scout_staged = false;
        if (scout) {
            if (!inputs || opaque) throw std::runtime_error("ROI scout requires staged inference inputs");
            if (!free->scout_pbo[0]) {
                glGenBuffers(2, free->scout_pbo.data());
                const GLsizeiptr bytes = static_cast<GLsizeiptr>(input_width) * input_height * 4;
                for (auto pbo : free->scout_pbo) { glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo); glBufferData(GL_PIXEL_PACK_BUFFER, bytes, nullptr, GL_STREAM_READ); }
            }
            if (zero_copy) stage_shared(*free, content_rect.data(), free->zc_scout_in);
            else stage_inputs(*free, content_rect.data(), free->scout_pbo);
            free->scout_staged = true;
        }
        return stage(*free, token, inputs, window ? window : content_rect.data());
    }
    // MPV direct mode: the pair shows the decoder's buffer (the owner keeps its MPV lease until this
    // slot retires); the model input is scaled straight from it, YUV sampled as RGB by the GPU.
    jlong capture_buffer(AHardwareBuffer* buffer, int buffer_width, int buffer_height, jlong token,
                         const float* window, bool scout) {
        current(); State state;
        if (!buffer || buffer_width < width || buffer_height < height) throw std::runtime_error("Decoder buffer invalid");
        const auto& api = egl_image();
        if (!api.available()) throw std::runtime_error("EGLImage/AHardwareBuffer interop unavailable");
        if (!scale_oes) scale_oes = program(scale_oes_fragment);
        Slot* free = nullptr;
        for (auto& slot : slots) if (slot.phase == Phase::free && !free) free = &slot;
        if (!free) { slot_exhaustions++; return 0; }
        release_decoder(*free);
        free->alpha_valid = false; free->opaque_pending = false; free->borrowed = 0;
        const EGLint attributes[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
        free->decoder_image = api.create(eglGetCurrentDisplay(), EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, api.client(buffer), attributes);
        if (free->decoder_image == EGL_NO_IMAGE_KHR) throw std::runtime_error("Decoder EGLImage creation failed");
        glGenTextures(1, &free->decoder_texture); glBindTexture(GL_TEXTURE_EXTERNAL_OES, free->decoder_texture);
        api.target(GL_TEXTURE_EXTERNAL_OES, static_cast<GLeglImageOES>(free->decoder_image));
        glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        free->uv_scale = {{static_cast<float>(width) / buffer_width, static_cast<float>(height) / buffer_height}};
        decoder_captures++;
        free->scout_staged = false;
        if (scout) {
            if (!free->scout_pbo[0]) {
                glGenBuffers(2, free->scout_pbo.data());
                const GLsizeiptr bytes = static_cast<GLsizeiptr>(input_width) * input_height * 4;
                for (auto pbo : free->scout_pbo) { glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo); glBufferData(GL_PIXEL_PACK_BUFFER, bytes, nullptr, GL_STREAM_READ); }
            }
            if (zero_copy) stage_shared(*free, content_rect.data(), free->zc_scout_in);
            else stage_inputs(*free, content_rect.data(), free->scout_pbo);
            free->scout_staged = true;
        }
        return stage(*free, token, true, window ? window : content_rect.data());
    }
    // rect maps eye UV into model UV: model = rect.xy + eye * rect.zw. The full-eye
    // letterbox has rect inside [0,1]; an ROI zoom window has rect.zw > 1.
    // Binds the slot's source image and returns the scale program with its common uniforms set.
    GLuint bind_scale(Slot& slot, const float* rect) {
        const GLuint prog = slot.decoder_texture ? scale_oes : scale;
        glUseProgram(prog);
        if (slot.decoder_texture) {
            glBindTexture(GL_TEXTURE_EXTERNAL_OES, slot.decoder_texture);
            glUniform2f(glGetUniformLocation(prog, "uv_scale"), slot.uv_scale[0], slot.uv_scale[1]);
        } else glBindTexture(GL_TEXTURE_2D, slot.source());
        glUniform1i(glGetUniformLocation(prog, "source"), 0); glUniform4fv(glGetUniformLocation(prog, "content_rect"), 1, rect);
        glUniform2f(glGetUniformLocation(prog, "eye_size"), eye_width(), eye_height());
        glUniform2f(glGetUniformLocation(prog, "footprint"), 1.f / input_width / rect[2], 1.f / input_height / rect[3]);
        return prog;
    }
    void stage_inputs(Slot& slot, const float* rect, const std::array<GLuint, 2>& pbos) {
        input_stages++;
        target(small, input_width, input_height);
        const GLuint prog = bind_scale(slot, rect);
        for (int eye = 0; eye < 2; ++eye) {
            eye_rect(prog, eye);
            glDrawArrays(GL_TRIANGLES, 0, 3); glBindBuffer(GL_PIXEL_PACK_BUFFER, pbos[eye]);
            // Only the model-size render target is ever read back. RGBA rows are 4-byte aligned.
            glReadPixels(0, 0, input_width, input_height, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        }
    }
    void ensure_shared(std::array<SharedImage, 2>& images, uint64_t usage) {
        for (auto& image : images) if (!image.buffer) image = make_shared_image(input_width, input_height, usage);
    }
    // Zero-copy staging: render each eye's model input straight into its AHardwareBuffer.
    void stage_shared(Slot& slot, const float* rect, std::array<SharedImage, 2>& targets) {
        ensure_shared(targets, kInputUsage);
        input_stages++;
        for (int eye = 0; eye < 2; ++eye) {
            target(targets[eye].texture, input_width, input_height);
            const GLuint prog = bind_scale(slot, rect);
            eye_rect(prog, eye);
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
    }
    // Zero-copy Alpha: MNN wrote round(alpha*255) into R of each eye's buffer; pack both eyes
    // into the slot's R8 mask on the GPU, fenced exactly like a CPU upload.
    void commit_zero_copy_alpha(jlong token) {
        current(); auto& slot = find(token);
        if (!zero_copy || !slot.zc_out[0].buffer || slot.phase != Phase::held || slot.alpha_fence || slot.alpha_valid)
            throw std::runtime_error("Zero-copy Alpha commit requires a held color with no existing mask");
        State state;
        if (!slot.alpha) image(slot.alpha, input_width*2, input_height, GL_R8);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, slot.alpha, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) throw std::runtime_error("Zero-copy mask framebuffer incomplete");
        glBindVertexArray(vao); glUseProgram(copy_2d); glUniform1i(glGetUniformLocation(copy_2d, "source"), 0);
        for (int eye = 0; eye < 2; ++eye) {
            glViewport(eye * input_width, 0, input_width, input_height);
            glBindTexture(GL_TEXTURE_2D, slot.zc_out[eye].texture);
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
        slot.opaque_cached = false;
        if (glGetError() != GL_NO_ERROR) throw std::runtime_error("Zero-copy Alpha commit GL error");
        slot.alpha_fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (!slot.alpha_fence) throw std::runtime_error("Zero-copy Alpha fence unavailable");
        zero_copy_commits++; alpha_uploads++;
        glFlush();
    }
    jlong stage(Slot& slot, jlong token, bool inputs = true, const float* rect = nullptr) {
        if (inputs && zero_copy) { ensure_shared(slot.zc_out, kOutputUsage); stage_shared(slot, rect ? rect : content_rect.data(), slot.zc_in); }
        else if (inputs) stage_inputs(slot, rect ? rect : content_rect.data(), slot.pbo);
        if (glGetError() != GL_NO_ERROR) throw std::runtime_error("Render bridge copy/staging GL error");
        slot.fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (!slot.fence) throw std::runtime_error("Render bridge copy fence unavailable");
        slot.token = token; slot.phase = Phase::copying; glFlush();
        return token;
    }
    void upload_alpha(jlong token, const float* left, const float* right) {
        current(); auto& slot = find(token);
        if (slot.phase != Phase::held || slot.alpha_fence || slot.alpha_valid)
            throw std::runtime_error("Alpha upload requires an immutable color with no existing mask");
        const size_t plane = static_cast<size_t>(input_width) * input_height;
        const auto a = reinterpret_cast<uintptr_t>(left), b = reinterpret_cast<uintptr_t>(right);
        const size_t bytes = plane * sizeof(float);
        if ((a <= b && b-a < bytes) || (b < a && a-b < bytes)) throw std::runtime_error("Alpha inputs overlap");
        std::vector<unsigned char> packed(plane * 2);
        for (int eye = 0; eye < 2; ++eye) {
            const auto* input = eye == 0 ? left : right;
            for (int y = 0; y < input_height; ++y) for (int x = 0; x < input_width; ++x) {
                const float value = input[static_cast<size_t>(y)*input_width+x];
                if (!std::isfinite(value) || value < 0.f || value > 1.f)
                    throw std::runtime_error("Alpha must contain finite numeric values in [0,1]");
                packed[static_cast<size_t>(y)*input_width*2+eye*input_width+x] = static_cast<unsigned char>(std::lround(value*255.f));
            }
        }
        // Validate both eyes before modifying the slot. Rows are canonical top-left.
        State state;
        if (!slot.alpha) image(slot.alpha, input_width*2, input_height, GL_R8);
        glBindTexture(GL_TEXTURE_2D, slot.alpha);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, input_width*2, input_height, GL_RED, GL_UNSIGNED_BYTE, packed.data());
        slot.near = std::move(packed);
        slot.opaque_cached = false;
        if (glGetError() != GL_NO_ERROR) throw std::runtime_error("Alpha upload GL error");
        slot.alpha_fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (!slot.alpha_fence) throw std::runtime_error("Alpha upload fence unavailable");
        alpha_uploads++;
        glFlush();
    }
    // 2D->3D: renders the held color's stereo pair from its just-uploaded near map. shift is the
    // eye-width fraction of the full parallax, convergence the near value left on the screen plane.
    // Returns 0 when this GL or source cannot run it (the display keeps its shader parallax).
    GLuint warp(jlong token, float shift, float convergence) {
        current(); auto& slot = find(token);
        if (slot.phase != Phase::held || (!slot.alpha_fence && !slot.alpha_valid) || slot.near.empty())
            throw std::runtime_error("2D->3D warp requires a held color with a fresh near map");
        if (warp_failed || layout != 0 || width > 2560 || height > 2160) return 0;
        State state;
        GLint unit1_2d = 0, unit1_sampler = 0, ssbo = 0, ssbo0 = 0, image0 = 0;
        glActiveTexture(GL_TEXTURE1); glGetIntegerv(GL_TEXTURE_BINDING_2D, &unit1_2d); glGetIntegerv(GL_SAMPLER_BINDING, &unit1_sampler);
        glBindSampler(1, 0); glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_SHADER_STORAGE_BUFFER_BINDING, &ssbo); glGetIntegeri_v(GL_SHADER_STORAGE_BUFFER_BINDING, 0, &ssbo0);
        glGetIntegeri_v(GL_IMAGE_BINDING_NAME, 0, &image0);
        GLuint result = 0;
        try { result = render_warp(slot, shift, convergence); }
        catch (const std::exception& failure) {
            warp_failed = true;
            __android_log_print(ANDROID_LOG_WARN, "QuestRenderBridge", "2D->3D warp unavailable: %s", failure.what());
        }
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, static_cast<GLuint>(ssbo0)); glBindBuffer(GL_SHADER_STORAGE_BUFFER, static_cast<GLuint>(ssbo));
        if (!image0) glBindImageTexture(0, 0, 0, GL_FALSE, 0, GL_READ_ONLY, GL_RGBA8);
        glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(unit1_2d));
        glBindSampler(1, static_cast<GLuint>(unit1_sampler)); glActiveTexture(GL_TEXTURE0);
        while (glGetError() != GL_NO_ERROR) {}
        return result;
    }
    // Debug inspection: `setprop debug.vrpp.warp.dump N` writes the next pair (as PPM) to the app's
    // external files directory; each new N writes once more, 0 turns it off.
    std::string dumped;
    void dump_warp() { // reads the bound pair framebuffer
        char value[PROP_VALUE_MAX] = {};
        if (__system_property_get("debug.vrpp.warp.dump", value) <= 0 || std::strcmp(value, "0") == 0 || dumped == value) return;
        dumped = value;
        const int W2 = width * 2;
        std::vector<unsigned char> rgba(static_cast<size_t>(W2) * height * 4);
        glReadPixels(0, 0, W2, height, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
        const std::string path = std::string("/sdcard/Android/data/com.wapok.thru3d/files/warp_") + value + ".ppm";
        if (FILE* file = std::fopen(path.c_str(), "wb")) {
            std::fprintf(file, "P6\n%d %d\n255\n", W2, height);
            for (size_t i = 0; i < rgba.size(); i += 4) std::fwrite(&rgba[i], 1, 3, file);
            std::fclose(file);
        }
    }
    GLuint render_warp(Slot& slot, float shift, float convergence) {
        GLint major = 0, minor = 0; glGetIntegerv(GL_MAJOR_VERSION, &major); glGetIntegerv(GL_MINOR_VERSION, &minor);
        if (major * 10 + minor < 31) throw std::runtime_error("OpenGL ES 3.1 compute unavailable");
        const int W2 = width * 2;
        if (!warp_frame_oes_prog) {
            warp_clear_prog = compute_program(warp_clear); warp_scatter_prog = compute_program(warp_scatter);
            warp_classify_prog = compute_program(warp_classify);
            warp_frame_2d_prog = warp_frame_program(warp_frame_2d); warp_frame_oes_prog = warp_frame_program(warp_frame_oes);
            glGenBuffers(1, &warp_keys); glBindBuffer(GL_SHADER_STORAGE_BUFFER, warp_keys);
            glBufferData(GL_SHADER_STORAGE_BUFFER, static_cast<GLsizeiptr>(W2) * height * 4, nullptr, GL_DYNAMIC_COPY);
            image(warp_map, W2, height, GL_RGBA16F);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            if (glGetError() != GL_NO_ERROR) throw std::runtime_error("2D->3D warp allocation GL error");
        }
        // PTMediaServer _max_disparity_pixels: max(2, min(96, W * 0.035 * strength)); each eye moves half.
        const float half = shift > 0.f ? std::max(2.f, std::min(96.f, width * shift)) * 0.5f : 0.f;
        if (slot.near != map_near || half != map_half || convergence != map_convergence) {
            map_timer.start();
            const auto uniforms = [&](GLuint prog) {
                glUseProgram(prog);
                glUniform1i(glGetUniformLocation(prog, "near_map"), 0);
                glUniform2i(glGetUniformLocation(prog, "size"), width, height);
                glUniform2i(glGetUniformLocation(prog, "model"), input_width, input_height);
                glUniform4fv(glGetUniformLocation(prog, "content"), 1, content_rect.data());
                glUniform2f(glGetUniformLocation(prog, "shift"), half, convergence);
            };
            glBindTexture(GL_TEXTURE_2D, slot.alpha);
            glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, warp_keys);
            const int count = W2 * height;
            uniforms(warp_clear_prog); glUniform1i(glGetUniformLocation(warp_clear_prog, "count"), count);
            glDispatchCompute(static_cast<GLuint>((count + 255) / 256), 1, 1);
            glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
            uniforms(warp_scatter_prog);
            glDispatchCompute(static_cast<GLuint>((width + 7) / 8), static_cast<GLuint>((height + 7) / 8), 1);
            glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
            uniforms(warp_classify_prog);
            glUniform1i(glGetUniformLocation(warp_classify_prog, "rim"), std::max(2, static_cast<int>(std::lround(width / 120.0))));
            glUniform1i(glGetUniformLocation(warp_classify_prog, "fg_win"), std::max(2, static_cast<int>(std::lround(width / 240.0))));
            glBindImageTexture(0, warp_map, 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA16F);
            glDispatchCompute(static_cast<GLuint>((W2 + 7) / 8), static_cast<GLuint>((height + 7) / 8), 1);
            glMemoryBarrier(GL_TEXTURE_FETCH_BARRIER_BIT);
            map_timer.stop();
            if (glGetError() != GL_NO_ERROR) throw std::runtime_error("2D->3D warp map GL error");
            map_near = slot.near; map_half = half; map_convergence = convergence; warp_maps++;
        }
        if (!slot.warp) {
            image(slot.warp, W2, height);
            if (glGetError() != GL_NO_ERROR) throw std::runtime_error("2D->3D stereo allocation GL error");
        }
        frame_timer.start();
        target(slot.warp, W2, height);
        const GLuint prog = slot.decoder_texture ? warp_frame_oes_prog : warp_frame_2d_prog;
        glUseProgram(prog);
        if (slot.decoder_texture) {
            glBindTexture(GL_TEXTURE_EXTERNAL_OES, slot.decoder_texture);
            glUniform2f(glGetUniformLocation(prog, "uv_scale"), slot.uv_scale[0], slot.uv_scale[1]);
        } else {
            glBindTexture(GL_TEXTURE_2D, slot.source());
            glUniform2f(glGetUniformLocation(prog, "uv_scale"), 1.f, 1.f);
        }
        glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, warp_map); glActiveTexture(GL_TEXTURE0);
        glUniform1i(glGetUniformLocation(prog, "source"), 0); glUniform1i(glGetUniformLocation(prog, "map"), 1);
        glUniform2i(glGetUniformLocation(prog, "size"), width, height);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        frame_timer.stop();
        dump_warp();
        if (glGetError() != GL_NO_ERROR) throw std::runtime_error("2D->3D warp GL error");
        // The pair is ready when the warp is complete, not just the mask upload.
        if (slot.alpha_fence) glDeleteSync(slot.alpha_fence);
        slot.alpha_fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (!slot.alpha_fence) throw std::runtime_error("2D->3D warp fence unavailable");
        glFlush();
        warp_frames++;
        return slot.warp;
    }
    bool alpha_ready(Slot& slot) {
        if (slot.phase != Phase::held) return false;
        if (slot.alpha_valid) return true;
        if (!slot.alpha_fence) return false;
        const auto result = glClientWaitSync(slot.alpha_fence, 0, 0);
        if (result == GL_WAIT_FAILED) throw std::runtime_error("Alpha upload fence failed");
        if (result != GL_ALREADY_SIGNALED && result != GL_CONDITION_SATISFIED) return false;
        glDeleteSync(slot.alpha_fence); slot.alpha_fence = nullptr; slot.alpha_valid = true;
        return true;
    }
};
std::mutex registry_mutex;
std::unordered_map<jlong, std::unique_ptr<Bridge>> registry;
// Independent of processing sessions and decoder surfaces. Only one transition
// can be displayed; no resource growth when many seek requests are coalesced.
struct FrozenFrame final {
    const EGLContext context = eglGetCurrentContext();
    GLuint color = 0, alpha = 0;
    ~FrozenFrame() {
        if (context != eglGetCurrentContext()) return;
        glDeleteTextures(1, &color); glDeleteTextures(1, &alpha);
    }
};
std::unordered_map<jlong, std::unique_ptr<FrozenFrame>> frozen_frames;
jlong sequence = 0, token_sequence = 0;
Bridge& find(jlong handle) {
    const auto it = registry.find(handle);
    if (it == registry.end()) throw std::runtime_error("Render bridge closed/unknown handle");
    it->second->current(); return *it->second;
}
void error(JNIEnv* env, const char* message) {
    if (!env->ExceptionCheck()) { const auto type = env->FindClass("java/lang/IllegalStateException"); if (type) env->ThrowNew(type, message); }
}
void* direct_buffer(JNIEnv* env, jobject buffer, size_t bytes, bool writable) {
    if (!buffer || env->GetDirectBufferCapacity(buffer) != static_cast<jlong>(bytes))
        throw std::runtime_error("Render bridge exact-size direct CHW buffer required");
    auto* address = env->GetDirectBufferAddress(buffer);
    if (!address) throw std::runtime_error("Render bridge direct buffer address invalid");
    const auto type = env->GetObjectClass(buffer);
    const auto method = type ? env->GetMethodID(type, "isReadOnly", "()Z") : nullptr;
    const bool readonly = method && env->CallBooleanMethod(buffer, method) == JNI_TRUE;
    if (type) env->DeleteLocalRef(type);
    if (!method || env->ExceptionCheck() || (writable && readonly)) throw std::runtime_error("Render bridge direct output must be writable");
    return address;
}
float* float_buffer(JNIEnv* env, jobject buffer, size_t bytes, bool writable = true) {
    auto* address = static_cast<float*>(direct_buffer(env, buffer, bytes, writable));
    if (reinterpret_cast<uintptr_t>(address) % alignof(float) != 0)
        throw std::runtime_error("Render bridge float buffer alignment invalid");
    return address;
}

// Still photos use the very same compute/fragment passes as video, once per strength.
// An isolated worker context avoids doing inference, readback or PNG encoding on Godot's GL thread.
struct PhotoEgl final {
    EGLDisplay display = EGL_NO_DISPLAY, previous_display = eglGetCurrentDisplay();
    EGLContext context = EGL_NO_CONTEXT, previous_context = eglGetCurrentContext();
    EGLSurface surface = EGL_NO_SURFACE, previous_draw = eglGetCurrentSurface(EGL_DRAW), previous_read = eglGetCurrentSurface(EGL_READ);
    EGLenum previous_api = eglQueryAPI();
    PhotoEgl() {
        try {
            display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
            if (display == EGL_NO_DISPLAY || !eglInitialize(display, nullptr, nullptr)) throw std::runtime_error("Photo EGL unavailable");
            const EGLint config_attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
            EGLConfig config{}; EGLint count = 0;
            if (!eglChooseConfig(display, config_attributes, &config, 1, &count) || count != 1 || !eglBindAPI(EGL_OPENGL_ES_API))
                throw std::runtime_error("Photo EGL configuration unavailable");
            const EGLint surface_attributes[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
            const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
            surface = eglCreatePbufferSurface(display, config, surface_attributes);
            context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
            if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT || !eglMakeCurrent(display, surface, surface, context))
                throw std::runtime_error("Photo EGL context unavailable");
        } catch (...) { dispose(); throw; }
    }
    void dispose() {
        if (context != EGL_NO_CONTEXT && eglGetCurrentContext() == context) eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
        if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
        context = EGL_NO_CONTEXT; surface = EGL_NO_SURFACE;
        eglBindAPI(previous_api);
        if (previous_display != EGL_NO_DISPLAY) eglMakeCurrent(previous_display, previous_draw, previous_read, previous_context);
        // This process's EGL display is shared with Godot: never eglTerminate it here.
    }
    ~PhotoEgl() { dispose(); }
};

void photo_stereo(const unsigned char* rgba, int w, int h, const float* near, int mw, int mh,
                  const std::array<float, 4>& rect, float strength, unsigned char* output) {
    if (w < 1 || h < 1 || w > 4096 || h > 4096 || static_cast<int64_t>(w) * h > 8LL * 1024 * 1024 ||
        mw < 1 || mh < 1 || mw > 518 || mh > 518 || !std::isfinite(strength) || strength < 0.f || strength > 2.f)
        throw std::runtime_error("Photo stereo dimensions/strength invalid");
    for (float v : rect) if (!std::isfinite(v)) throw std::runtime_error("Photo stereo content invalid");
    if (rect[0] < 0 || rect[1] < 0 || rect[2] <= 0 || rect[3] <= 0 || rect[0]+rect[2] > 1.000001f || rect[1]+rect[3] > 1.000001f)
        throw std::runtime_error("Photo stereo content out of bounds");
    PhotoEgl egl;
    GLint maximum = 0; glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maximum);
    if (w * 2 > maximum || h > maximum) throw std::runtime_error("Photo stereo exceeds GPU texture limit");
    Bridge bridge(w, h, mw, mh, 0);
    // Only the still's own colour, mask and warp are allocated; no video slots/decoder/model inputs.
    glGenVertexArrays(1, &bridge.vao); glGenFramebuffers(1, &bridge.fbo);
    bridge.content_rect = rect;
    auto& slot = bridge.slots[0]; slot.token = 1; slot.phase = Phase::held;
    image(slot.color, w, h);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    std::vector<float> right(near, near + static_cast<size_t>(mw) * mh);
    bridge.upload_alpha(1, near, right.data());
    // Use render_warp directly: the video width cap is a realtime budget, not a still-photo cap.
    bridge.render_warp(slot, 0.035f * strength, 0.35f);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0); glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w * 2, h, GL_RGBA, GL_UNSIGNED_BYTE, output);
    check_gl("Photo stereo readback");
}
} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_photoStereo(JNIEnv* env, jclass, jobject rgba, jint w, jint h,
    jobject near, jint mw, jint mh, jfloatArray content, jfloat strength, jobject output) {
    try {
        // Validate dimensions before calculating buffer sizes or reading arrays.
        if (w < 1 || h < 1 || w > 4096 || h > 4096 || static_cast<int64_t>(w)*h > 8LL*1024*1024 ||
            mw < 1 || mh < 1 || mw > 518 || mh > 518 || !content || env->GetArrayLength(content) != 4)
            throw std::runtime_error("Photo stereo input invalid");
        const auto* color = static_cast<unsigned char*>(direct_buffer(env, rgba, static_cast<size_t>(w)*h*4, false));
        const auto* depth = float_buffer(env, near, static_cast<size_t>(mw)*mh*4, false);
        auto* result = static_cast<unsigned char*>(direct_buffer(env, output, static_cast<size_t>(w)*h*8, true));
        std::array<float, 4> rect{}; env->GetFloatArrayRegion(content, 0, 4, rect.data());
        if (env->ExceptionCheck()) return 0;
        const auto started = std::chrono::steady_clock::now();
        photo_stereo(color, w, h, depth, mw, mh, rect, strength, result);
        return std::max<jlong>(1, std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-started).count());
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_freezePair(JNIEnv* env, jclass, jlong id, jlong token, jboolean warped) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex);
        auto& b = find(id); auto& slot = b.find(token);
        if (slot.phase != Phase::held || !slot.alpha_valid || !frozen_frames.empty())
            throw std::runtime_error("Freeze requires one complete held display pair and no previous snapshot");
        const bool warp = warped == JNI_TRUE;
        if (warp && !slot.warp) throw std::runtime_error("Frozen stereo warp unavailable");
        const int width = b.width * (warp ? 2 : 1);
        const auto started = std::chrono::steady_clock::now();
        State state;
        auto frozen = std::make_unique<FrozenFrame>();
        image(frozen->color, width, b.height);
        image(frozen->alpha, b.input_width * 2, b.input_height, GL_R8);
        glBindFramebuffer(GL_FRAMEBUFFER, b.fbo); glBindVertexArray(b.vao); glActiveTexture(GL_TEXTURE0);
        auto copy = [&](GLuint source, GLenum target, GLuint destination, int w, int h, GLuint prog) {
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, destination, 0);
            if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
                throw std::runtime_error("Freeze framebuffer incomplete");
            glViewport(0, 0, w, h); glUseProgram(prog); glBindTexture(target, source);
            glUniform1i(glGetUniformLocation(prog, "source"), 0);
            if (target == GL_TEXTURE_EXTERNAL_OES)
                glUniform2f(glGetUniformLocation(prog, "uv_scale"), slot.uv_scale[0], slot.uv_scale[1]);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            check_gl("Freeze frame GPU copy");
        };
        if (!warp && slot.decoder_texture) {
            if (!b.freeze_oes) b.freeze_oes = program(freeze_oes_fragment);
            copy(slot.decoder_texture, GL_TEXTURE_EXTERNAL_OES, frozen->color, width, b.height, b.freeze_oes);
        } else copy(warp ? slot.warp : slot.source(), GL_TEXTURE_2D, frozen->color, width, b.height, b.copy_2d);
        copy(slot.alpha, GL_TEXTURE_2D, frozen->alpha, b.input_width * 2, b.input_height, b.copy_2d);
        // A seek may flush MediaCodec on a different context/thread as soon as
        // this callback returns. Complete this one transition copy before it.
        glFinish(); check_gl("Freeze frame GPU completion");
        if (sequence == std::numeric_limits<jlong>::max()) throw std::runtime_error("Frozen handle space exhausted");
        const jlong handle = ++sequence;
        const jlong values[] = {handle, frozen->color, frozen->alpha, width, b.height,
            std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - started).count()};
        auto result = env->NewLongArray(6);
        if (!result) return nullptr;
        env->SetLongArrayRegion(result, 0, 6, values);
        if (env->ExceptionCheck()) return nullptr;
        frozen_frames.emplace(handle, std::move(frozen));
        return result;
    } catch (const std::exception& e) { error(env, e.what()); return nullptr; }
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_releaseFrozen(JNIEnv*, jclass, jlong id) {
    std::lock_guard<std::mutex> guard(registry_mutex);
    // After the caller detached its wrappers/last draw, GL deletion preserves
    // in-flight GPU uses. A lost context's names must never be deleted in a new one.
    frozen_frames.erase(id);
}

extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_createLayout(JNIEnv* env, jclass, jint w, jint h, jint iw, jint ih, jint layout) {
    try {
        if (w < 1 || h < 1 || w > 8192 || h > 8192 || static_cast<int64_t>(w)*h > 8192LL*4320 ||
            iw < 1 || ih < 1 || iw > 512 || ih > 512 || layout < 0 || layout > 2 || (layout == 1 && w % 2 != 0) ||
            (layout == 2 && h % 2 != 0))
            throw std::runtime_error("Render bridge dimensions unsupported");
        std::lock_guard<std::mutex> guard(registry_mutex);
        if (registry.size() >= 2 || sequence == std::numeric_limits<jlong>::max()) throw std::runtime_error("Render bridge instance capacity exhausted");
        auto bridge = std::make_unique<Bridge>(w, h, iw, ih, layout); bridge->allocate();
        const auto id = ++sequence; registry.emplace(id, std::move(bridge)); return id;
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_oesTexture(JNIEnv* env, jclass, jlong id) {
    try { std::lock_guard<std::mutex> guard(registry_mutex); return find(id).oes; }
    catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_capture(JNIEnv* env, jclass, jlong id, jfloatArray matrix) {
    try {
        if (!matrix || env->GetArrayLength(matrix) != 16) throw std::runtime_error("Render bridge transform invalid");
        std::array<float, 16> transform; env->GetFloatArrayRegion(matrix, 0, 16, transform.data());
        if (env->ExceptionCheck()) return 0;
        for (float value : transform) if (!std::isfinite(value)) throw std::runtime_error("Render bridge transform nonfinite");
        std::lock_guard<std::mutex> guard(registry_mutex);
        if (token_sequence == std::numeric_limits<jlong>::max()) throw std::runtime_error("Render bridge lease space exhausted");
        return find(id).capture(transform.data(), ++token_sequence);
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_ready(JNIEnv* env, jclass, jlong id, jlong token) {
    try { std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id); return bridge.poll(bridge.find(token)) ? JNI_TRUE : JNI_FALSE; }
    catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_captureTexture(JNIEnv* env, jclass, jlong id, jint texture, jboolean inputs) {
    try {
        if (texture <= 0) throw std::runtime_error("Shared MPV texture name invalid");
        std::lock_guard<std::mutex> guard(registry_mutex);
        if (token_sequence == std::numeric_limits<jlong>::max()) throw std::runtime_error("Render bridge lease space exhausted");
        return find(id).capture_texture(static_cast<GLuint>(texture), ++token_sequence, inputs == JNI_TRUE);
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_captureTextureRoi(JNIEnv* env, jclass, jlong id, jint texture,
                                                                        jfloatArray rect, jboolean scout) {
    try {
        if (texture <= 0) throw std::runtime_error("Shared MPV texture name invalid");
        if (!rect || env->GetArrayLength(rect) != 4) throw std::runtime_error("ROI rect must have four values");
        std::array<float, 4> window; env->GetFloatArrayRegion(rect, 0, 4, window.data());
        if (env->ExceptionCheck()) return 0;
        for (float v : window) if (!std::isfinite(v)) throw std::runtime_error("ROI rect nonfinite");
        // Window in eye UV is [-xy/zw, (1-xy)/zw]; it must overlap the eye and zoom at most 8x.
        for (int axis = 0; axis < 2; ++axis) {
            const float scale = window[axis + 2], start = -window[axis] / scale, end = (1.f - window[axis]) / scale;
            if (!(scale > 0.f && scale <= 8.f && end > 0.f && start < 1.f)) throw std::runtime_error("ROI rect outside the eye");
        }
        std::lock_guard<std::mutex> guard(registry_mutex);
        if (token_sequence == std::numeric_limits<jlong>::max()) throw std::runtime_error("Render bridge lease space exhausted");
        return find(id).capture_texture(static_cast<GLuint>(texture), ++token_sequence, true, false, window.data(), scout == JNI_TRUE);
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_enableZeroCopy(JNIEnv* env, jclass, jlong id) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id);
        if (!egl_image().available()) return JNI_FALSE;
        bridge.zero_copy = true;
        return JNI_TRUE;
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_captureBufferRoi(JNIEnv* env, jclass, jlong id, jlong buffer,
    jint buffer_width, jint buffer_height, jfloatArray rect, jboolean scout) {
    try {
        if (!rect || env->GetArrayLength(rect) != 4) throw std::runtime_error("Decoder capture window invalid");
        std::array<float, 4> window; env->GetFloatArrayRegion(rect, 0, 4, window.data());
        if (env->ExceptionCheck()) return 0;
        for (float value : window) if (!std::isfinite(value)) throw std::runtime_error("Decoder capture window nonfinite");
        std::lock_guard<std::mutex> guard(registry_mutex);
        if (token_sequence == std::numeric_limits<jlong>::max()) throw std::runtime_error("Render bridge lease space exhausted");
        return find(id).capture_buffer(reinterpret_cast<AHardwareBuffer*>(static_cast<uintptr_t>(buffer)), buffer_width, buffer_height,
                                       ++token_sequence, window.data(), scout == JNI_TRUE);
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
// EGLImage of a held decoder-buffer slot (0 for copied/borrowed RGBA colors).
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_colorImage(JNIEnv* env, jclass, jlong id, jlong token) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& slot = find(id).find(token);
        if (slot.phase != Phase::held) throw std::runtime_error("Render bridge color not ready");
        return static_cast<jlong>(reinterpret_cast<uintptr_t>(slot.decoder_image));
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
// Borrowed color: captures keep the producer texture (no full-resolution copy). The caller must
// hold the producer lease until retired() reports the slot free.
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_enableBorrowedColor(JNIEnv* env, jclass, jlong id) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); find(id).borrow = true;
        return JNI_TRUE;
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
// {input L, input R, alpha L, alpha R} AHardwareBuffer handles of a held slot (or its scout set).
extern "C" JNIEXPORT jlongArray JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_zeroCopyBuffers(JNIEnv* env, jclass, jlong id, jlong token, jboolean scout) {
    try {
        std::array<jlong, 4> handles{};
        {
            std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id); auto& slot = bridge.find(token);
            bridge.current();
            if (slot.phase != Phase::held || !bridge.zero_copy) throw std::runtime_error("Zero-copy buffers need a held color");
            if (scout && !slot.scout_staged) throw std::runtime_error("No ROI scout input was staged for this color");
            if (scout) bridge.ensure_shared(bridge.zc_scout_out, kOutputUsage);
            const auto& input = scout ? slot.zc_scout_in : slot.zc_in;
            const auto& output = scout ? bridge.zc_scout_out : slot.zc_out;
            for (int eye = 0; eye < 2; ++eye)
                if (!input[eye].buffer || !output[eye].buffer) throw std::runtime_error("Zero-copy buffers missing");
            // The inference worker may still use these after this bridge closes (session revision):
            // each handle carries its own reference, released with releaseBuffers().
            for (int eye = 0; eye < 2; ++eye) {
                AHardwareBuffer_acquire(input[eye].buffer); AHardwareBuffer_acquire(output[eye].buffer);
                handles[eye] = static_cast<jlong>(reinterpret_cast<uintptr_t>(input[eye].buffer));
                handles[eye + 2] = static_cast<jlong>(reinterpret_cast<uintptr_t>(output[eye].buffer));
            }
        }
        auto result = env->NewLongArray(4);
        if (result) env->SetLongArrayRegion(result, 0, 4, handles.data());
        return result;
    } catch (const std::exception& e) { error(env, e.what()); return nullptr; }
}
// Drops the references zeroCopyBuffers() handed out. Any thread; the bridge may be gone.
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_releaseBuffers(JNIEnv* env, jclass, jlongArray buffers) {
    if (!buffers) return;
    const auto count = env->GetArrayLength(buffers);
    std::vector<jlong> values(static_cast<size_t>(count));
    env->GetLongArrayRegion(buffers, 0, count, values.data());
    for (jlong value : values)
        if (value) AHardwareBuffer_release(reinterpret_cast<AHardwareBuffer*>(static_cast<uintptr_t>(value)));
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_commitZeroCopyAlpha(JNIEnv* env, jclass, jlong id, jlong token) {
    try { std::lock_guard<std::mutex> guard(registry_mutex); find(id).commit_zero_copy_alpha(token); return JNI_TRUE; }
    catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jfloatArray JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_fullInputRect(JNIEnv* env, jclass, jlong id) {
    try {
        std::array<float, 4> rect;
        { std::lock_guard<std::mutex> guard(registry_mutex); rect = find(id).content_rect; }
        auto result = env->NewFloatArray(4);
        if (result) env->SetFloatArrayRegion(result, 0, 4, rect.data());
        return result;
    } catch (const std::exception& e) { error(env, e.what()); return nullptr; }
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_texture(JNIEnv* env, jclass, jlong id, jlong token) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& slot = find(id).find(token);
        if (slot.phase != Phase::held) throw std::runtime_error("Render bridge color not ready");
        return slot.decoder_texture ? slot.decoder_texture : slot.source();
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_captureOpaqueTexture(JNIEnv* env, jclass, jlong id, jint texture) {
    try {
        if (texture <= 0) throw std::runtime_error("Shared MPV texture name invalid");
        std::lock_guard<std::mutex> guard(registry_mutex);
        if (token_sequence == std::numeric_limits<jlong>::max()) throw std::runtime_error("Render bridge lease space exhausted");
        return find(id).capture_texture(static_cast<GLuint>(texture), ++token_sequence, false, true);
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_stats(JNIEnv* env, jclass, jlong id) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& b = find(id);
        std::array<int, 4> phases{};
        for (const auto& s : b.slots) phases[static_cast<size_t>(s.phase)]++;
        auto json = "{\"copies\":" + std::to_string(b.copies) + ",\"opaque_copies\":" + std::to_string(b.opaque_copies) +
            ",\"opaque_initial_uploads\":" + std::to_string(b.opaque_uploads) + ",\"regular_alpha_uploads\":" + std::to_string(b.alpha_uploads) +
            ",\"input_stages\":" + std::to_string(b.input_stages) + ",\"copy_pending_polls\":" + std::to_string(b.copy_pending_polls) +
            ",\"retire_pending_polls\":" + std::to_string(b.retire_pending_polls) + ",\"slot_exhaustions\":" + std::to_string(b.slot_exhaustions) + ",\"borrowed_captures\":" + std::to_string(b.borrows) + ",\"decoder_captures\":" + std::to_string(b.decoder_captures) +
            ",\"zero_copy\":" + (b.zero_copy ? "true" : "false") + ",\"zero_copy_commits\":" + std::to_string(b.zero_copy_commits) +
            ",\"warp_frames\":" + std::to_string(b.warp_frames) + ",\"warp_maps\":" + std::to_string(b.warp_maps) +
            ",\"warp_half_shift_px\":" + std::to_string(b.map_half) +
            ",\"warp_failed\":" + (b.warp_failed ? "true" : "false") +
            ",\"warp_map_gpu_ms\":" + std::to_string(b.map_timer.ms) + ",\"warp_frame_gpu_ms\":" + std::to_string(b.frame_timer.ms) +
            ",\"free_slots\":" + std::to_string(phases[0]) + ",\"copying_slots\":" + std::to_string(phases[1]) +
            ",\"held_slots\":" + std::to_string(phases[2]) + ",\"retiring_slots\":" + std::to_string(phases[3]) + "}";
        return env->NewStringUTF(json.c_str());
    } catch (const std::exception& e) { error(env, e.what()); return nullptr; }
}
static jboolean read_inputs(JNIEnv* env, jlong id, jlong token, jobject left, jobject right, bool scout) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id); auto& slot = bridge.find(token);
        if (slot.phase != Phase::held) return JNI_FALSE;
        if (scout && !slot.scout_staged) throw std::runtime_error("No ROI scout input was staged for this color");
        const auto& pbos = scout ? slot.scout_pbo : slot.pbo;
        const size_t plane = static_cast<size_t>(bridge.input_width)*bridge.input_height;
        const size_t output_bytes = plane*3*sizeof(float);
        std::array<float*, 2> outputs{{float_buffer(env, left, output_bytes), float_buffer(env, right, output_bytes)}};
        const auto a = reinterpret_cast<uintptr_t>(outputs[0]), b = reinterpret_cast<uintptr_t>(outputs[1]);
        if ((a <= b && b-a < output_bytes) || (b < a && a-b < output_bytes)) throw std::runtime_error("Render bridge CHW outputs overlap");
        State state;
        for (int eye = 0; eye < 2; ++eye) {
            glBindBuffer(GL_PIXEL_PACK_BUFFER, pbos[eye]);
            const auto* rgba = static_cast<const unsigned char*>(glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, plane*4, GL_MAP_READ_BIT));
            if (!rgba) throw std::runtime_error("Render bridge PBO map failed");
            for (int channel = 0; channel < 3; ++channel) for (size_t i = 0; i < plane; ++i) outputs[eye][channel*plane+i] = rgba[i*4+channel]/255.f;
            if (!glUnmapBuffer(GL_PIXEL_PACK_BUFFER)) throw std::runtime_error("Render bridge PBO storage corrupted");
        }
        return JNI_TRUE;
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_readInputs(JNIEnv* env, jclass, jlong id, jlong token, jobject left, jobject right) {
    return read_inputs(env, id, token, left, right, false);
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_readScoutInputs(JNIEnv* env, jclass, jlong id, jlong token, jobject left, jobject right) {
    return read_inputs(env, id, token, left, right, true);
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_retire(JNIEnv* env, jclass, jlong id, jlong token) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& slot = find(id).find(token);
        if (slot.phase == Phase::retiring) return;
        if (slot.fence) glDeleteSync(slot.fence);
        if (slot.alpha_fence) { glDeleteSync(slot.alpha_fence); slot.alpha_fence = nullptr; }
        slot.alpha_valid = false;
        slot.fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (!slot.fence) throw std::runtime_error("Render bridge release fence unavailable");
        slot.phase = Phase::retiring; glFlush();
    } catch (const std::exception& e) { error(env, e.what()); }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_retired(JNIEnv* env, jclass, jlong id, jlong token) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id);
        for (auto& slot : bridge.slots) if (token > 0 && slot.token == token) {
            if (slot.phase == Phase::retiring) bridge.poll(slot);
            return slot.phase == Phase::free ? JNI_TRUE : JNI_FALSE;
        }
        throw std::runtime_error("Render bridge retirement token unknown");
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_uploadAlpha(JNIEnv* env, jclass, jlong id, jlong token, jobject left, jobject right) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id);
        const size_t bytes = static_cast<size_t>(bridge.input_width)*bridge.input_height*sizeof(float);
        const auto* l = float_buffer(env, left, bytes, false); const auto* r = float_buffer(env, right, bytes, false);
        bridge.upload_alpha(token, l, r); return JNI_TRUE;
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_warp(JNIEnv* env, jclass, jlong id, jlong token, jfloat shift, jfloat convergence) {
    try {
        if (!std::isfinite(shift) || !std::isfinite(convergence) || shift < 0.f || shift > 0.2f || convergence < 0.f || convergence > 1.f)
            throw std::runtime_error("2D->3D warp parameters invalid");
        std::lock_guard<std::mutex> guard(registry_mutex); return static_cast<jint>(find(id).warp(token, shift, convergence));
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_alphaReady(JNIEnv* env, jclass, jlong id, jlong token) {
    try { std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id); return bridge.alpha_ready(bridge.find(token)) ? JNI_TRUE : JNI_FALSE; }
    catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_alphaTexture(JNIEnv* env, jclass, jlong id, jlong token) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& slot = find(id).find(token);
        if (slot.phase != Phase::held || !slot.alpha_valid) throw std::runtime_error("Alpha texture not ready");
        return slot.alpha;
    } catch (const std::exception& e) { error(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_readAlpha(JNIEnv* env, jclass, jlong id, jlong token, jobject output) {
    try {
        std::lock_guard<std::mutex> guard(registry_mutex); auto& bridge = find(id); auto& slot = bridge.find(token);
        if (slot.phase != Phase::held || !slot.alpha_valid) return JNI_FALSE;
        const size_t pixels = static_cast<size_t>(bridge.input_width)*bridge.input_height*2;
        auto* destination = static_cast<unsigned char*>(direct_buffer(env, output, pixels, true));
        State state; bridge.target(slot.alpha, bridge.input_width*2, bridge.input_height);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        // ES3 guarantees RGBA/UNSIGNED_BYTE readback for normalized attachments.
        std::vector<unsigned char> rgba(pixels*4);
        glReadPixels(0, 0, bridge.input_width*2, bridge.input_height, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
        if (glGetError() != GL_NO_ERROR) throw std::runtime_error("Alpha readback GL error");
        for (size_t i = 0; i < pixels; ++i) destination[i] = rgba[i*4];
        return JNI_TRUE;
    } catch (const std::exception& e) { error(env, e.what()); return JNI_FALSE; }
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_close(JNIEnv*, jclass, jlong id) {
    std::lock_guard<std::mutex> guard(registry_mutex); registry.erase(id);
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_abandon(JNIEnv*, jclass, jlong id) {
    std::lock_guard<std::mutex> guard(registry_mutex);
    const auto it = registry.find(id);
    if (it != registry.end()) { it->second->abandoned = true; registry.erase(it); }
}
