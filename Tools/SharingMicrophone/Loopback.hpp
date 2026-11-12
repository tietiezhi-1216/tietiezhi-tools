// Copyright (c) 2026 Tietiezhi Tools contributors. MIT License.
#pragma once
#include <array>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

// One mixed feed writer, independent input readers. No locks or allocation on I/O threads.
// Atomic tagged samples prevent data races and stale reads during wraparound.
class MicrophoneLoopback {
public:
    static constexpr uint64_t Capacity = 16384;
    struct Reader { uint64_t cursor = 0; bool initialized = false; };
    MicrophoneLoopback() {
        static_assert(std::atomic<uint64_t>::is_always_lock_free);
        for (auto& slot : slots_) slot.store(UINT64_MAX, std::memory_order_relaxed);
    }
    void Write(const float* samples, uint32_t count) {
        auto end = end_.load(std::memory_order_relaxed);
        for (uint32_t i = 0; i < count; ++i) {
            float value = std::isfinite(samples[i]) ? std::clamp(samples[i], -1.0f, 1.0f) : 0.0f;
            uint32_t bits; std::memcpy(&bits, &value, sizeof(bits));
            const auto index = end + i;
            slots_[index % Capacity].store((uint64_t(uint32_t(index)) << 32) | bits, std::memory_order_relaxed);
        }
        end_.store(end + count, std::memory_order_release);
    }
    // Called after the feed's I/O has stopped. Neither old nor newly attached
    // readers may hear samples from the previous microphone session.
    void Discard() { floor_.store(end_.load(std::memory_order_acquire), std::memory_order_release); }
    void Read(Reader& reader, float* samples, uint32_t count) const {
        const auto end = end_.load(std::memory_order_acquire);
        const auto floor = floor_.load(std::memory_order_acquire);
        if (!reader.initialized || reader.cursor < floor || reader.cursor > end || end - reader.cursor > 4096) {
            reader.cursor = std::max(floor, end > count ? end - count : 0);
            reader.initialized = true;
        }
        for (uint32_t i = 0; i < count; ++i) {
            samples[i] = 0;
            if (reader.cursor >= end) continue;
            const auto index = reader.cursor++;
            const auto tagged = slots_[index % Capacity].load(std::memory_order_relaxed);
            if (uint32_t(tagged >> 32) != uint32_t(index)) continue;
            const uint32_t bits = uint32_t(tagged);
            std::memcpy(&samples[i], &bits, sizeof(bits));
        }
    }
private:
    std::array<std::atomic<uint64_t>, Capacity> slots_;
    std::atomic<uint64_t> end_{0};
    std::atomic<uint64_t> floor_{0};
};
