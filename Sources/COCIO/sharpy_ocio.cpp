#include "include/sharpy_ocio.h"

#include <OpenColorIO/OpenColorIO.h>
#include <cstring>
#include <string>
#include <vector>

namespace OCIO = OCIO_NAMESPACE;

namespace {

char *dupString(const std::string &s) {
    char *out = static_cast<char *>(std::malloc(s.size() + 1));
    if (out) std::memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

// A texture as OCIO described it, with its values copied so the lifetime is ours.
struct Tex {
    std::string textureName;
    std::string samplerName;
    unsigned width = 0;
    unsigned height = 0;
    unsigned edgelen = 0;
    int channels = 3;
    int nearest = 0;
    std::vector<float> values;
};

} // namespace

struct SharpyOCIOShaderImpl {
    OCIO::GpuShaderDescRcPtr desc;
    std::string text;
    std::vector<Tex> textures;
};

extern "C" {

SharpyOCIOShader *sharpy_ocio_create(const char *configName,
                                     const char *srcColorSpace,
                                     const char *dstColorSpace,
                                     const char *functionName,
                                     char **errorOut) {
    if (errorOut) *errorOut = nullptr;
    try {
        OCIO::ConstConfigRcPtr config = OCIO::Config::CreateFromBuiltinConfig(configName);
        OCIO::ConstProcessorRcPtr processor = config->getProcessor(srcColorSpace, dstColorSpace);
        // OPTIMIZATION_DEFAULT folds what it can; the rest becomes LUTs we upload.
        OCIO::ConstGPUProcessorRcPtr gpu = processor->getDefaultGPUProcessor();

        OCIO::GpuShaderDescRcPtr desc = OCIO::GpuShaderDesc::CreateShaderDesc();
        desc->setLanguage(OCIO::GPU_LANGUAGE_MSL_2_0);
        desc->setFunctionName(functionName ? functionName : "OCIOTransform");
        desc->setResourcePrefix("ocio_");
        gpu->extractGpuShaderInfo(desc);

        auto *impl = new SharpyOCIOShaderImpl();
        impl->desc = desc;
        impl->text = desc->getShaderText() ? desc->getShaderText() : "";

        const unsigned n1d = desc->getNumTextures();
        for (unsigned i = 0; i < n1d; ++i) {
            const char *tn = nullptr; const char *sn = nullptr;
            unsigned w = 0, h = 0;
            OCIO::GpuShaderDesc::TextureType channel = OCIO::GpuShaderDesc::TEXTURE_RGB_CHANNEL;
            OCIO::GpuShaderDesc::TextureDimensions dims = OCIO::GpuShaderDesc::TEXTURE_1D;
            OCIO::Interpolation interp = OCIO::INTERP_LINEAR;
            desc->getTexture(i, tn, sn, w, h, channel, dims, interp);

            const float *values = nullptr;
            desc->getTextureValues(i, values);

            Tex t;
            t.textureName = tn ? tn : "";
            t.samplerName = sn ? sn : "";
            t.width = w;
            t.height = h;
            t.edgelen = 0;
            t.channels = (channel == OCIO::GpuShaderDesc::TEXTURE_RED_CHANNEL) ? 1 : 3;
            t.nearest = (interp == OCIO::INTERP_NEAREST) ? 1 : 0;
            const size_t count = static_cast<size_t>(w) * (h ? h : 1) * static_cast<size_t>(t.channels);
            if (values) t.values.assign(values, values + count);
            impl->textures.push_back(std::move(t));
        }

        const unsigned n3d = desc->getNum3DTextures();
        for (unsigned i = 0; i < n3d; ++i) {
            const char *tn = nullptr; const char *sn = nullptr;
            unsigned edge = 0;
            OCIO::Interpolation interp = OCIO::INTERP_LINEAR;
            desc->get3DTexture(i, tn, sn, edge, interp);

            const float *values = nullptr;
            desc->get3DTextureValues(i, values);

            Tex t;
            t.textureName = tn ? tn : "";
            t.samplerName = sn ? sn : "";
            t.width = edge; t.height = edge; t.edgelen = edge;
            t.channels = 3;
            t.nearest = (interp == OCIO::INTERP_NEAREST) ? 1 : 0;
            const size_t count = static_cast<size_t>(edge) * edge * edge * 3;
            if (values) t.values.assign(values, values + count);
            impl->textures.push_back(std::move(t));
        }
        return impl;
    } catch (const std::exception &e) {
        if (errorOut) *errorOut = dupString(std::string(e.what()));
        return nullptr;
    } catch (...) {
        if (errorOut) *errorOut = dupString("unknown OpenColorIO error");
        return nullptr;
    }
}

const char *sharpy_ocio_shader_text(const SharpyOCIOShader *shader) {
    return shader ? shader->text.c_str() : nullptr;
}

int sharpy_ocio_texture_count(const SharpyOCIOShader *shader) {
    return shader ? static_cast<int>(shader->textures.size()) : 0;
}

int sharpy_ocio_texture(const SharpyOCIOShader *shader, int index, SharpyOCIOTexture *out) {
    if (!shader || !out || index < 0 || index >= static_cast<int>(shader->textures.size())) return 0;
    const Tex &t = shader->textures[static_cast<size_t>(index)];
    out->textureName = t.textureName.c_str();
    out->samplerName = t.samplerName.c_str();
    out->width = t.width;
    out->height = t.height;
    out->edgelen = t.edgelen;
    out->channels = t.channels;
    out->nearest = t.nearest;
    out->values = t.values.empty() ? nullptr : t.values.data();
    out->valueCount = t.values.size();
    return 1;
}

void sharpy_ocio_destroy(SharpyOCIOShader *shader) { delete shader; }

char *sharpy_ocio_list_colorspaces(const char *configName, char **errorOut) {
    if (errorOut) *errorOut = nullptr;
    try {
        OCIO::ConstConfigRcPtr config = OCIO::Config::CreateFromBuiltinConfig(configName);
        std::string all;
        const int n = config->getNumColorSpaces();
        for (int i = 0; i < n; ++i) {
            all += config->getColorSpaceNameByIndex(i);
            all += "\n";
        }
        return dupString(all);
    } catch (const std::exception &e) {
        if (errorOut) *errorOut = dupString(std::string(e.what()));
        return nullptr;
    }
}

const char *sharpy_ocio_version(void) { return OCIO::GetVersion(); }

void sharpy_ocio_string_free(char *s) { std::free(s); }

} // extern "C"
