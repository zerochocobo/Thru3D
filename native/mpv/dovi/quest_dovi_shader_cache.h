/* No per-frame coefficients are embedded in shader text. The array elements
 * use ordinary cached MPV uniforms; local arrays keep libplacebo's GLSL intact
 * without extending the renderer's uniform-buffer ABI. */
static bool quest_pl_uniform(struct gl_shader_cache *sc, const char *name,
                             const struct pl_var *var, const float *data)
{
    if (var->type == PL_VAR_SINT && var->dim_v == 1 && var->dim_m == 1) {
        gl_sc_uniform_i(sc, (char *)name, *(const int *)data);
        return true;
    }
    if (var->type != PL_VAR_FLOAT || var->dim_v < 1 || var->dim_v > 4 ||
        var->dim_m < 1 || var->dim_m > 3 ||
        (var->dim_m > 1 && var->dim_m != var->dim_v))
        return false;
    struct sc_uniform *u = find_uniform(sc, bstr0(name));
    u->input.type = RA_VARTYPE_FLOAT;
    u->input.dim_v = var->dim_v;
    u->input.dim_m = var->dim_m;
    u->glsl_type = pl_var_glsl_type_name(*var);
    gl_sc_uniform_dynamic(sc);
    update_uniform_params(sc, u);
    memcpy(u->v.f, data, var->dim_v * var->dim_m * sizeof(float));
    return true;
}

bool gl_sc_quest_pl_shader(struct gl_shader_cache *sc,
                          const struct pl_shader_res *res)
{
    if (res->input != PL_SHADER_SIG_COLOR || res->output != PL_SHADER_SIG_COLOR ||
        res->num_descriptors || res->num_constants || res->num_vertex_attribs)
        return false;
    const char *function = strstr(res->glsl, res->name);
    const char *body = function ? strchr(function, '{') : NULL;
    if (!body)
        return false;
    bstr arrays = {0};
    for (int n = 0; n < res->num_variables; n++) {
        const struct pl_shader_var *v = &res->variables[n];
        const struct pl_var *var = &v->var;
        int count = MPMAX(1, var->dim_a);
        if (count > 64 || (var->type != PL_VAR_FLOAT && var->type != PL_VAR_SINT))
            goto fail;
        const char *type = pl_var_glsl_type_name(*var);
        if (count > 1)
            bstr_xappend_asprintf(sc, &arrays, "%s %s[%d] = %s[%d](", type,
                                 var->name, count, type, count);
        for (int a = 0; a < count; a++) {
            char *name = count > 1 ? ta_asprintf(sc, "%s_q%d", var->name, a)
                                   : ta_strdup(sc, var->name);
            const float *data = (const float *)v->data + a * var->dim_v * var->dim_m;
            if (!quest_pl_uniform(sc, name, var, data)) {
                ta_free(name);
                goto fail;
            }
            if (count > 1)
                bstr_xappend_asprintf(sc, &arrays, "%s%s", a ? "," : "", name);
            ta_free(name);
        }
        if (count > 1)
            bstr_xappend(sc, &arrays, bstr0(");\n"));
    }
    gl_sc_haddf(sc, "%.*s\n%.*s\n%s", (int)(body + 1 - res->glsl), res->glsl,
                BSTR_P(arrays), body + 1);
    gl_sc_addf(sc, "color = %s(color);\n", res->name);
    ta_free(arrays.start);
    return true;
fail:
    ta_free(arrays.start);
    return false;
}

void gl_sc_quest_raw_yuv(struct gl_shader_cache *sc, const char *name)
{
    gl_sc_enable_extension(sc, "GL_EXT_YUV_target");
    for (int n = 0; n < sc->num_uniforms; n++) {
        struct sc_uniform *u = &sc->uniforms[n];
        if (strcmp(u->input.name, name) == 0 && u->input.type == RA_VARTYPE_TEX) {
            u->glsl_type = "highp __samplerExternal2DY2YEXT";
            return;
        }
    }
}
