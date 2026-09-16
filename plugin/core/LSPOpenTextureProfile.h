#pragma once

#include "LSPOpenTextureLog.h"

#include <chrono>
#include <cstdlib>
#include <sstream>
#include <string>

namespace LSPOpenTextureProfile {

inline bool enabled() {
    const char* env = std::getenv("OPEN_TEXTURE_PROFILE");
    return env != nullptr && env[0] == '1';
}

class StageTimer {
public:
    explicit StageTimer(const char* label)
        : label_(label)
        , active_(enabled())
        , t0_(active_ ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{}) {}

    ~StageTimer() {
        if (!active_)
            return;
        const auto t1 = std::chrono::steady_clock::now();
        const double ms = std::chrono::duration<double, std::milli>(t1 - t0_).count();
        std::ostringstream o;
        o << "profile stage=" << label_ << " ms=" << ms;
        LSPOpenTextureLog::writeInfoLine(o.str());
    }

    StageTimer(const StageTimer&) = delete;
    StageTimer& operator=(const StageTimer&) = delete;

private:
    const char* label_;
    bool active_;
    std::chrono::steady_clock::time_point t0_;
};

class FrameScope {
public:
    FrameScope()
        : active_(enabled())
        , t0_(active_ ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{}) {}

    ~FrameScope() {
        if (!active_)
            return;
        const auto t1 = std::chrono::steady_clock::now();
        const double ms = std::chrono::duration<double, std::milli>(t1 - t0_).count();
        std::ostringstream o;
        o << "profile stage=total ms=" << ms;
        LSPOpenTextureLog::writeInfoLine(o.str());
    }

    FrameScope(const FrameScope&) = delete;
    FrameScope& operator=(const FrameScope&) = delete;

private:
    bool active_;
    std::chrono::steady_clock::time_point t0_;
};

}

#define OPEN_TEXTURE_PROFILE_STAGE(label) LSPOpenTextureProfile::StageTimer _openTextureProfileStage_##__LINE__(label)
#define OPEN_TEXTURE_PROFILE_FRAME() LSPOpenTextureProfile::FrameScope _openTextureProfileFrameScope
