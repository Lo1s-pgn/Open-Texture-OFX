#ifndef LSP_OPEN_TEXTURE_TRANSFERS_H
#define LSP_OPEN_TEXTURE_TRANSFERS_H

#include <cmath>

namespace LSPOpenTextureTransfers {

using std::exp2;
using std::exp;
using std::log;
using std::log2;
using std::log10;
using std::fmax;
using std::fmin;
using std::pow;

#include "LSPOpenTextureTransfers.inc"

struct RGBf {
    float r;
    float g;
    float b;
};

inline RGBf to_scene_linear(RGBf enc, int tf) {
    if (tf == 0)
        return enc;
    if (tf == 1)
        return {decode_davinci_intermediate(enc.r), decode_davinci_intermediate(enc.g), decode_davinci_intermediate(enc.b)};
    if (tf == 2)
        return {decode_filmlight_tlog(enc.r), decode_filmlight_tlog(enc.g), decode_filmlight_tlog(enc.b)};
    if (tf == 3)
        return {decode_acescct(enc.r), decode_acescct(enc.g), decode_acescct(enc.b)};
    if (tf == 4)
        return {decode_arri_logc3(enc.r), decode_arri_logc3(enc.g), decode_arri_logc3(enc.b)};
    if (tf == 5)
        return {decode_arri_logc4(enc.r), decode_arri_logc4(enc.g), decode_arri_logc4(enc.b)};
    if (tf == 6)
        return {decode_red_log3g10(enc.r), decode_red_log3g10(enc.g), decode_red_log3g10(enc.b)};
    if (tf == 7)
        return {decode_panasonic_vlog(enc.r), decode_panasonic_vlog(enc.g), decode_panasonic_vlog(enc.b)};
    if (tf == 8)
        return {decode_sony_slog3(enc.r), decode_sony_slog3(enc.g), decode_sony_slog3(enc.b)};
    if (tf == 9)
        return {decode_fujifilm_flog2(enc.r), decode_fujifilm_flog2(enc.g), decode_fujifilm_flog2(enc.b)};
    return enc;
}

inline RGBf from_scene_linear(RGBf lin, int tf) {
    if (tf == 0)
        return lin;
    if (tf == 1)
        return {encode_davinci_intermediate(lin.r), encode_davinci_intermediate(lin.g), encode_davinci_intermediate(lin.b)};
    if (tf == 2)
        return {encode_filmlight_tlog(lin.r), encode_filmlight_tlog(lin.g), encode_filmlight_tlog(lin.b)};
    if (tf == 3)
        return {encode_acescct(lin.r), encode_acescct(lin.g), encode_acescct(lin.b)};
    if (tf == 4)
        return {encode_arri_logc3(lin.r), encode_arri_logc3(lin.g), encode_arri_logc3(lin.b)};
    if (tf == 5)
        return {encode_arri_logc4(lin.r), encode_arri_logc4(lin.g), encode_arri_logc4(lin.b)};
    if (tf == 6)
        return {encode_red_log3g10(lin.r), encode_red_log3g10(lin.g), encode_red_log3g10(lin.b)};
    if (tf == 7)
        return {encode_panasonic_vlog(lin.r), encode_panasonic_vlog(lin.g), encode_panasonic_vlog(lin.b)};
    if (tf == 8)
        return {encode_sony_slog3(lin.r), encode_sony_slog3(lin.g), encode_sony_slog3(lin.b)};
    if (tf == 9)
        return {encode_fujifilm_flog2(lin.r), encode_fujifilm_flog2(lin.g), encode_fujifilm_flog2(lin.b)};
    return lin;
}

inline void clamp_choice_index(int* ioTf) {
    if (*ioTf < 0)
        *ioTf = 0;
    if (*ioTf > 9)
        *ioTf = 9;
}

}

#endif
