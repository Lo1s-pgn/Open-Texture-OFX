#ifndef OT_TF_FN
#define OT_TF_FN inline
#endif

OT_TF_FN float exp10_compat(float x) { return exp2(x * 3.3219280948873626f); }

OT_TF_FN float decode_davinci_intermediate(float e) {
    return e <= 0.02740668f ? e / 10.44426855f : exp2(e / 0.07329248f - 7.0f) - 0.0075f;
}

OT_TF_FN float decode_filmlight_tlog(float e) {
    return e < 0.075f ? (e - 0.075f) / 16.184376489665897f
                      : exp((e - 0.5520126568606655f) / 0.09232902596577353f) - 0.0057048244042473785f;
}

OT_TF_FN float decode_acescct(float e) {
    const float th1 = 0.155251141552511f;
    return e <= th1 ? (e - 0.0729055341958355f) / 10.5402377416545f : exp2(e * 17.52f - 9.72f);
}

OT_TF_FN float decode_arri_logc3(float e) {
    return e < 5.367655f * 0.010591f + 0.092809f ? (e - 0.092809f) / 5.367655f
                                                    : (exp10_compat((e - 0.385537f) / 0.247190f) - 0.052272f) / 5.555556f;
}

OT_TF_FN float decode_arri_logc4(float e) {
    return e < -0.7774983977293537f ? e * 0.3033266726886969f - 0.7774983977293537f
                                      : (exp2(14.0f * (e - 0.09286412512218964f) / 0.9071358748778103f + 6.0f) - 64.0f) /
                                            2231.8263090676883f;
}

OT_TF_FN float decode_red_log3g10(float e) {
    return e < 0.0f ? (e / 15.1927f) - 0.01f : (exp10_compat(e / 0.224282f) - 1.0f) / 155.975327f - 0.01f;
}

OT_TF_FN float decode_panasonic_vlog(float e) {
    return e < 0.181f ? (e - 0.125f) / 5.6f : exp10_compat((e - 0.598206f) / 0.241514f) - 0.00873f;
}

OT_TF_FN float decode_sony_slog3(float e) {
    const float k1 = 171.2102946929f / 1023.0f;
    return e < k1 ? (e * 1023.0f - 95.0f) * 0.01125f / (171.2102946929f - 95.0f)
                  : (exp10_compat(((e * 1023.0f - 420.0f) / 261.5f)) * (0.18f + 0.01f) - 0.01f);
}

OT_TF_FN float decode_fujifilm_flog2(float e) {
    return e < 0.100686685370811f ? (e - 0.092864f) / 8.799461f
                                  : (exp10_compat((e - 0.384316f) / 0.245281f) / 5.555556f - 0.064829f / 5.555556f);
}

OT_TF_FN float encode_filmlight_tlog(float l) {
    const float k = 16.184376489665897f;
    const float cutE = 0.075f;
    const float B = 0.5520126568606655f;
    const float A = 0.09232902596577353f;
    const float c = 0.0057048244042473785f;
    if (l <= 0.0f)
        return cutE + k * l;
    return B + A * log(fmax(l + c, 1e-30f));
}

OT_TF_FN float encode_davinci_intermediate(float lin) {
    const float DI_A = 0.0075f;
    const float DI_B = 7.0f;
    const float DI_C = 0.07329248f;
    const float DI_M = 10.44426855f;
    const float DI_LIN_CUT = 0.00262409f;
    return (lin > DI_LIN_CUT) ? (log2(lin + DI_A) + DI_B) * DI_C : lin * DI_M;
}

OT_TF_FN float encode_arri_logc3(float lin) {
    return lin > 0.010591f ? 0.24719f * log10(5.555556f * lin + 0.052272f) + 0.385537f : 5.367655f * lin + 0.092809f;
}

OT_TF_FN float encode_acescct(float rgb) {
    return (rgb > 0.0078125f) ? (log(rgb) / log(2.0f) + 9.72f) / 17.52f : 10.5402377416545f * rgb + 0.0729055341958355f;
}

OT_TF_FN float encode_arri_logc4(float l) {
    const float eSplit = -0.7774983977293537f;
    const float m = 0.3033266726886969f;
    const float offs = 0.7774983977293537f;
    const float eLin = (l + offs) / m;
    if (eLin < eSplit - 1e-6f)
        return eLin;
    const float e0 = 0.09286412512218964f;
    const float d = 0.9071358748778103f;
    const float big = 2231.8263090676883f;
    return e0 + d * ((log2(fmax(l * big + 64.0f, 1e-30f)) - 6.0f) / 14.0f);
}

OT_TF_FN float encode_red_log3g10(float l) {
    const float kk = 0.224282f;
    const float mm = 155.975327f;
    if (l <= -0.01f)
        return (l + 0.01f) * 15.1927f;
    return kk * log10(fmax((l + 0.01f) * mm + 1.0f, 1e-30f));
}

OT_TF_FN float encode_panasonic_vlog(float l) {
    const float cutL = (0.181f - 0.125f) / 5.6f;
    if (l <= cutL)
        return l * 5.6f + 0.125f;
    return 0.598206f + 0.241514f * log10(fmax(l + 0.00873f, 1e-30f));
}

OT_TF_FN float encode_sony_slog3(float l) {
    const float threshE = 171.2102946929f / 1023.0f;
    const float Lj = decode_sony_slog3(threshE - 1.0e-7f);
    if (l <= Lj)
        return ((l / 0.01125f * (171.2102946929f - 95.0f)) + 95.0f) / 1023.0f;
    return (261.5f * log10(fmax((l + 0.01f) / 0.19f, 1e-30f)) + 420.0f) / 1023.0f;
}

OT_TF_FN float encode_fujifilm_flog2(float l) {
    const float eCut = 0.100686685370811f;
    const float kF = 8.799461f;
    const float e0 = 0.092864f;
    const float Lcut = (eCut - e0) / kF;
    if (l <= Lcut)
        return l * kF + e0;
    const float c = 0.064829f / 5.555556f;
    return 0.384316f + 0.245281f * log10(fmax((l + c) * 5.555556f, 1e-30f));
}

OT_TF_FN float whitepoint_for_transfer(int tf) {
    if (tf == 0)
        return 1.0f;
    if (tf == 1)
        return 100.0f;
    if (tf == 2 || tf == 5 || tf == 6 || tf == 7 || tf == 8 || tf == 9)
        return 100.0f;
    if (tf == 3)
        return 222.86f;
    if (tf == 4)
        return 55.08f;
    return 100.0f;
}
