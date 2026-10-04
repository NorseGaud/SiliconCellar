/*
 * BRINK writes GLSL 1.30 shaders. The Mac OpenGL driver gives the game a 2.1 context, which compiles GLSL 1.20 only.
 * brink.exe loads this DLL and calls export ordinal 1 in place of glShaderSourceARB.
 * The DLL rewrites `#version 130` sources to GLSL 1.20 with GL_EXT_gpu_shader4 and GL_ARB_shader_texture_lod.
 *
 * DLL:  i686-w64-mingw32-gcc -O2 -shared -s -static-libgcc -Wl,--kill-at -Wl,--no-insert-timestamp -Wl,--disable-auto-image-base \
 *           -o brinkglsl.dll scripts/brink-glsl.c -lopengl32
 *       touch -t 202001010000.00 brinkglsl.dll
 *       COPYFILE_DISABLE=1 tar -cJf Sources/SiliconCellarCore/Fixes/Brink/brinkglsl.tar.xz brinkglsl.dll
 * Test: clang -DBRINK_GLSL_MAC_TEST -framework OpenGL -o brink-glsl-test scripts/brink-glsl.c
 *       ./brink-glsl-test <shaderdump folder>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct text {
    char *data;
    size_t length;
    size_t capacity;
};

static int append(struct text *text, const char *bytes, size_t count)
{
    if (text->length + count + 1 > text->capacity) {
        size_t capacity = (text->length + count + 1) * 2;
        char *data = realloc(text->data, capacity);
        if (!data) return 0;
        text->data = data;
        text->capacity = capacity;
    }
    memcpy(text->data + text->length, bytes, count);
    text->length += count;
    text->data[text->length] = 0;
    return 1;
}

static int append_string(struct text *text, const char *string)
{
    return append(text, string, strlen(string));
}

static const char header[] =
    "#version 120\n"
    "#extension GL_EXT_gpu_shader4 : enable\n"
    "#extension GL_ARB_shader_texture_lod : enable\n"
    "#extension GL_ARB_texture_rectangle : enable\n";

static const char common_prelude[] =
    "vec4 texture(sampler2D s, vec2 c) { return texture2D(s, c); }\n"
    "vec4 texture(sampler2DRect s, vec2 c) { return texture2DRect(s, c); }\n"
    "vec4 texture(sampler3D s, vec3 c) { return texture3D(s, c); }\n"
    "vec4 texture(samplerCube s, vec3 c) { return textureCube(s, c); }\n"
    "float texture(sampler2DShadow s, vec3 c) { return shadow2D(s, c).r; }\n"
    "vec4 textureProj(sampler2D s, vec3 c) { return texture2DProj(s, c); }\n"
    "vec4 textureProj(sampler2D s, vec4 c) { return texture2DProj(s, c); }\n"
    "float textureProj(sampler2DShadow s, vec4 c) { return shadow2DProj(s, c).r; }\n"
    "vec4 textureLod(sampler2D s, vec2 c, float l) { return texture2DLod(s, c, l); }\n"
    "vec4 textureLod(samplerCube s, vec3 c, float l) { return textureCubeLod(s, c, l); }\n"
    "vec4 textureProjLod(sampler2D s, vec3 c, float l) { return texture2DProjLod(s, c, l); }\n"
    "vec4 textureProjLod(sampler2D s, vec4 c, float l) { return texture2DProjLod(s, c, l); }\n"
    "vec4 textureGrad(sampler2D s, vec2 c, vec2 x, vec2 y) { return texture2DGrad(s, c, x, y); }\n"
    "vec4 textureGrad(samplerCube s, vec3 c, vec3 x, vec3 y) { return textureCubeGrad(s, c, x, y); }\n"
    "vec4 textureLodOffset(sampler2D s, vec2 c, float l, ivec2 o) {\n"
    "    ivec2 size = textureSize2D(s, int(l));\n"
    "    return texture2DLod(s, c + vec2(float(o.x), float(o.y)) / vec2(float(size.x), float(size.y)), l);\n"
    "}\n"
    "ivec2 textureSize(sampler2D s, int l) { return textureSize2D(s, l); }\n"
    "vec4 texelFetch(sampler2D s, ivec2 c, int l) { return texelFetch2D(s, c, l); }\n"
    "float trunc(float x) { return truncate(x); }\n"
    "vec2 trunc(vec2 x) { return truncate(x); }\n"
    "vec3 trunc(vec3 x) { return truncate(x); }\n"
    "vec4 trunc(vec4 x) { return truncate(x); }\n";

/* Only fragment shaders may pass a level-of-detail bias. */
static const char fragment_prelude[] =
    "vec4 texture(sampler2D s, vec2 c, float b) { return texture2D(s, c, b); }\n"
    "vec4 texture(samplerCube s, vec3 c, float b) { return textureCube(s, c, b); }\n";

static int is_blank(char c)
{
    return c == ' ' || c == '\t' || c == '\r';
}

static const char *skip_blanks(const char *at, const char *end)
{
    while (at < end && is_blank(*at)) at++;
    return at;
}

/* Length of `word` when `at` starts with it as a whole word, otherwise 0. */
static size_t word_length(const char *at, const char *end, const char *word)
{
    size_t length = strlen(word);
    if ((size_t)(end - at) <= length || memcmp(at, word, length) != 0) return 0;
    return is_blank(at[length]) ? length : 0;
}

static const char *identifier_end(const char *at, const char *end)
{
    while (at < end && (*at == '_' || (*at >= '0' && *at <= '9') || (*at >= 'a' && *at <= 'z') || (*at >= 'A' && *at <= 'Z')))
        at++;
    return at;
}

/*
 * Rewrites one global `in` or `out` declaration. Vertex inputs become `attribute` and outputs become `varying`.
 * Fragment inputs become `varying`. One output becomes the next gl_FragData entry.
 * `out vec4 name[N]` becomes gl_FragData, so `name[i]` is draw buffer i.
 * Returns 0 when the line is not such a declaration.
 */
static int rewrite_declaration(struct text *out, const char *line, const char *end, int fragment, int *output_index)
{
    static const char *const interpolations[] = {"flat", "smooth", "noperspective", "centroid"};
    const char *at = skip_blanks(line, end);
    const char *interpolation = NULL;
    size_t interpolation_length = 0;
    size_t length;
    size_t i;

    for (i = 0; i < sizeof(interpolations) / sizeof(interpolations[0]) && !interpolation; i++) {
        if ((length = word_length(at, end, interpolations[i]))) {
            interpolation = at;
            interpolation_length = length;
            at = skip_blanks(at + length, end);
        }
    }
    if ((length = word_length(at, end, "in"))) {
        const char *rest = skip_blanks(at + length, end);
        if (fragment) {
            if (interpolation && !append(out, interpolation, interpolation_length + 1)) return -1;
            return append_string(out, "varying ") && append(out, rest, end - rest) ? 1 : -1;
        }
        return append_string(out, "attribute ") && append(out, rest, end - rest) ? 1 : -1;
    }
    if ((length = word_length(at, end, "out"))) {
        const char *rest = skip_blanks(at + length, end);
        if (fragment) {
            const char *type = rest;
            const char *type_end = identifier_end(type, end);
            const char *name = skip_blanks(type_end, end);
            const char *name_end = identifier_end(name, end);
            const char *after = skip_blanks(name_end, end);
            const char *suffix = "";
            char entry[96];
            int slots = 1;
            if (name == name_end) return 0;
            /* `out vec4 outcol[4]` is gl_FragData[0] .. gl_FragData[3]. */
            if (after < end && *after == '[') {
                slots = atoi(after + 1);
                if (slots < 1 || *output_index != 0) return 0;
                *output_index += slots;
                snprintf(entry, sizeof(entry), "#define %.*s gl_FragData", (int)(name_end - name), name);
                return append_string(out, entry) ? 1 : -1;
            }
            if (type_end - type == 4 && memcmp(type, "vec2", 4) == 0) suffix = ".xy";
            else if (type_end - type == 4 && memcmp(type, "vec3", 4) == 0) suffix = ".xyz";
            else if (type_end - type == 5 && memcmp(type, "float", 5) == 0) suffix = ".x";
            snprintf(entry, sizeof(entry), "#define %.*s gl_FragData[%d]%s", (int)(name_end - name), name, (*output_index)++, suffix);
            return append_string(out, entry) ? 1 : -1;
        }
        if (interpolation && !append(out, interpolation, interpolation_length + 1)) return -1;
        return append_string(out, "varying ") && append(out, rest, end - rest) ? 1 : -1;
    }
    return 0;
}

/* Tracks brace and parenthesis depth so only global declarations are rewritten. */
static void scan_depth(const char *at, const char *end, int *depth, int *in_comment)
{
    for (; at < end; at++) {
        if (*in_comment) {
            if (at + 1 < end && at[0] == '*' && at[1] == '/') {
                *in_comment = 0;
                at++;
            }
        } else if (at + 1 < end && at[0] == '/' && at[1] == '/') {
            return;
        } else if (at + 1 < end && at[0] == '/' && at[1] == '*') {
            *in_comment = 1;
            at++;
        } else if (*at == '{' || *at == '(') {
            (*depth)++;
        } else if (*at == '}' || *at == ')') {
            (*depth)--;
        }
    }
}

/* Desktop GLSL 1.20 reserves precision words and rejects them. */
static char *strip_precision(const char *source, size_t length)
{
    static const char *const words[] = {"highp", "mediump", "lowp"};
    const char *at = source;
    const char *end = source + length;
    struct text out = {0};
    size_t i;

    while (at < end) {
        int skipped = 0;
        if (at == source || !(* (at - 1) == '_' || (*(at - 1) >= '0' && *(at - 1) <= '9') ||
                              (*(at - 1) >= 'a' && *(at - 1) <= 'z') || (*(at - 1) >= 'A' && *(at - 1) <= 'Z'))) {
            for (i = 0; i < sizeof(words) / sizeof(words[0]); i++) {
                size_t word = word_length(at, end, words[i]);
                if (!word) continue;
                at += word;
                while (at < end && is_blank(*at)) at++;
                skipped = 1;
                break;
            }
        }
        if (skipped) continue;
        if (!append(&out, at, 1)) {
            free(out.data);
            return NULL;
        }
        at++;
    }
    return out.data;
}

/* Returns a new GLSL 1.20 source, or NULL when the source is not GLSL 1.30. */
static char *brink_glsl_translate(const char *source, size_t length, int fragment)
{
    static const char version[] = "#version 130";
    const char *end = source + length;
    const char *at = source;
    struct text out = {0};
    char *stripped = strip_precision(source, length);
    int depth = 0;
    int in_comment = 0;
    int output_index = 0;

    if (!stripped) return NULL;
    source = stripped;
    length = strlen(stripped);
    end = source + length;
    at = source;
    while (at < end && (is_blank(*at) || *at == '\n')) at++;
    if ((size_t)(end - at) < sizeof(version) - 1 || memcmp(at, version, sizeof(version) - 1) != 0) {
        free(stripped);
        return NULL;
    }
    at = memchr(at, '\n', end - at);
    at = at ? at + 1 : end;
    if (!append_string(&out, header)) goto failed;

    while (at < end) {
        const char *line_end = memchr(at, '\n', end - at);
        const char *next = line_end ? line_end + 1 : end;
        const char *first = skip_blanks(at, line_end ? line_end : end);
        if (first < end && *first != '#' && *first != '\n') break;
        if (!append(&out, at, next - at)) goto failed;
        at = next;
    }
    if (!append_string(&out, common_prelude)) goto failed;
    if (fragment && !append_string(&out, fragment_prelude)) goto failed;

    while (at < end) {
        const char *line_end = memchr(at, '\n', end - at);
        const char *content_end = line_end ? line_end : end;
        const char *next = line_end ? line_end + 1 : end;
        int rewritten = 0;
        if (depth == 0 && !in_comment) {
            rewritten = rewrite_declaration(&out, at, content_end, fragment, &output_index);
            if (rewritten < 0 || (rewritten && !append_string(&out, "\n"))) goto failed;
        }
        if (!rewritten) {
            if (!append(&out, at, next - at)) goto failed;
            scan_depth(at, content_end, &depth, &in_comment);
        }
        at = next;
    }
    free(stripped);
    return out.data;

failed:
    free(out.data);
    free(stripped);
    return NULL;
}

#ifdef _WIN32
#include <windows.h>

#define GL_FRAGMENT_SHADER 0x8B30
#define GL_OBJECT_SUBTYPE_ARB 0x8B4F

typedef void (APIENTRY *shader_source_function)(unsigned int, int, const char *const *, const int *);
typedef void (APIENTRY *object_parameter_function)(unsigned int, unsigned int, int *);

__declspec(dllexport) void APIENTRY BrinkShaderSource(unsigned int shader, int count, const char *const *strings, const int *lengths)
{
    static shader_source_function shader_source;
    static object_parameter_function object_parameter;
    size_t total = 0;
    size_t *sizes;
    char *joined;
    char *translated = NULL;
    int type = 0;
    int i;

    if (!shader_source) {
        shader_source = (shader_source_function)wglGetProcAddress("glShaderSourceARB");
        object_parameter = (object_parameter_function)wglGetProcAddress("glGetObjectParameterivARB");
    }
    if (!shader_source) return;
    sizes = malloc(sizeof(*sizes) * (count > 0 ? count : 1));
    for (i = 0; sizes && i < count; i++) {
        sizes[i] = lengths && lengths[i] >= 0 ? (size_t)lengths[i] : strlen(strings[i]);
        total += sizes[i];
    }
    joined = sizes ? malloc(total + 1) : NULL;
    if (joined) {
        size_t offset = 0;
        for (i = 0; i < count; i++) {
            memcpy(joined + offset, strings[i], sizes[i]);
            offset += sizes[i];
        }
        joined[total] = 0;
        if (object_parameter) object_parameter(shader, GL_OBJECT_SUBTYPE_ARB, &type);
        translated = brink_glsl_translate(joined, total, type == GL_FRAGMENT_SHADER);
    }
    if (translated) {
        const char *source = translated;
        shader_source(shader, 1, &source, NULL);
    } else {
        shader_source(shader, count, strings, lengths);
    }
    free(translated);
    free(joined);
    free(sizes);
}
#endif

#ifdef BRINK_GLSL_MAC_TEST
#define GL_SILENCE_DEPRECATION
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <fts.h>

static int compile_file(const char *path)
{
    int fragment = strstr(path, "_glslfs") != NULL;
    FILE *file = fopen(path, "rb");
    char *source;
    char *translated;
    long size;
    GLuint shader;
    GLint status = 0;
    char log[4096] = {0};

    if (!file) return 0;
    fseek(file, 0, SEEK_END);
    size = ftell(file);
    fseek(file, 0, SEEK_SET);
    source = malloc(size + 1);
    fread(source, 1, size, file);
    source[size] = 0;
    fclose(file);
    translated = brink_glsl_translate(source, size, fragment);
    if (!translated) {
        printf("NOT 1.30 %s\n", path);
        free(source);
        return 0;
    }
    shader = glCreateShader(fragment ? GL_FRAGMENT_SHADER : GL_VERTEX_SHADER);
    glShaderSource(shader, 1, (const GLchar **)&translated, NULL);
    glCompileShader(shader);
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (!status) {
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        printf("FAIL %s\n%s\n", path, log);
    }
    glDeleteShader(shader);
    free(translated);
    free(source);
    return status;
}

int main(int argc, char **argv)
{
    CGLPixelFormatAttribute attributes[] = {kCGLPFAAccelerated, 0};
    CGLPixelFormatObj format = NULL;
    CGLContextObj context = NULL;
    GLint formats = 0;
    char *roots[] = {argc > 1 ? argv[1] : ".", NULL};
    FTS *walk;
    FTSENT *entry;
    int passed = 0;
    int failed = 0;

    CGLChoosePixelFormat(attributes, &format, &formats);
    CGLCreateContext(format, NULL, &context);
    CGLSetCurrentContext(context);
    printf("%s, GLSL %s\n", glGetString(GL_VERSION), glGetString(GL_SHADING_LANGUAGE_VERSION));
    walk = fts_open(roots, FTS_PHYSICAL, NULL);
    while ((entry = fts_read(walk))) {
        if (entry->fts_info != FTS_F || !strstr(entry->fts_name, "_glsl")) continue;
        if (compile_file(entry->fts_path)) passed++;
        else failed++;
    }
    fts_close(walk);
    printf("compiled %d, failed %d\n", passed, failed);
    return failed ? 1 : 0;
}
#endif
