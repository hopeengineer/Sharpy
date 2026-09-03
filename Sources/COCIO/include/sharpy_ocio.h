// Flat C surface over OpenColorIO's GPU path, so Swift can obtain a Metal Shading Language
// transform without touching C++ directly.
//
// Colour management is not a nicety here: the difference between a log camera file shown raw and
// the same file through its correct input transform is the difference between "washed out" and
// "graded". OCIO 2.5 ships the ACES configs built in (`ocio://default`), so nothing external has
// to be located, shipped, or version-matched at runtime.

#ifndef SHARPY_OCIO_H
#define SHARPY_OCIO_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One LUT the generated shader expects to be bound. `edgelen != 0` means a 3D LUT
/// (edgelen³ RGB samples); otherwise it is a 1D/2D LUT of width × height.
typedef struct {
    const char *textureName;
    const char *samplerName;
    unsigned width;
    unsigned height;
    unsigned edgelen;        // 0 for 1D/2D, N for an N³ 3D LUT
    int channels;            // 1 = red only, 3 = RGB
    int nearest;             // 1 = point sampling required, 0 = linear
    const float *values;     // width*height*channels, or edgelen³*3
    size_t valueCount;
} SharpyOCIOTexture;

typedef struct SharpyOCIOShaderImpl SharpyOCIOShader;

/// Build a GPU transform from `srcColorSpace` to `dstColorSpace` in `configName`
/// (e.g. "ocio://default"). Returns NULL and sets *errorOut (caller frees with
/// sharpy_ocio_string_free) on failure.
SharpyOCIOShader *sharpy_ocio_create(const char *configName,
                                     const char *srcColorSpace,
                                     const char *dstColorSpace,
                                     const char *functionName,
                                     char **errorOut);

/// The generated MSL. Valid until the shader is destroyed.
const char *sharpy_ocio_shader_text(const SharpyOCIOShader *shader);

int sharpy_ocio_texture_count(const SharpyOCIOShader *shader);
/// Fills `out` for texture `index`. Returns 1 on success.
int sharpy_ocio_texture(const SharpyOCIOShader *shader, int index, SharpyOCIOTexture *out);

void sharpy_ocio_destroy(SharpyOCIOShader *shader);

/// Newline-separated colour space names in a config. Caller frees with sharpy_ocio_string_free.
char *sharpy_ocio_list_colorspaces(const char *configName, char **errorOut);

/// OCIO's own version string.
const char *sharpy_ocio_version(void);

void sharpy_ocio_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif
