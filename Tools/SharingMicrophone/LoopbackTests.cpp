// Copyright (c) 2026 Tietiezhi Tools contributors. MIT License.
#include "Loopback.hpp"
#include <cassert>
#include <iostream>
#include <limits>
#include <thread>
#include <vector>

int main() {
    MicrophoneLoopback ring;
    MicrophoneLoopback::Reader a, b;
    float out[4] = {1, 1, 1, 1};
    ring.Read(a, out, 4);
    for (float s : out) assert(s == 0);
    const float in[4] = {0.25f, -0.5f, 4.0f, std::numeric_limits<float>::quiet_NaN()};
    ring.Write(in, 4);
    ring.Read(a, out, 4);
    assert(out[0] == .25f && out[1] == -.5f && out[2] == 1 && out[3] == 0);
    ring.Read(b, out, 4); // independent clients receive the same audio
    assert(out[0] == .25f && out[1] == -.5f);
    ring.Read(a, out, 4); // never replay old microphone samples
    for (float s : out) assert(s == 0);
    std::vector<float> many(40000, .75f);
    ring.Write(many.data(), uint32_t(many.size()));
    ring.Read(a, out, 4); // lagging readers resume live instead of accumulating delay
    for (float s : out) assert(s == .75f);
    std::thread writer([&] { for (int i = 0; i < 5000; ++i) ring.Write(in, 4); });
    for (int i = 0; i < 5000; ++i) {
        ring.Read(a, out, 4);
        for (float s : out) assert(std::isfinite(s) && s >= -1 && s <= 1);
    }
    writer.join();
    ring.Discard();
    MicrophoneLoopback::Reader newlyAttached;
    ring.Read(newlyAttached, out, 4);
    for (float s : out) assert(s == 0); // a new client must not replay the last session
    ring.Read(a, out, 4);
    for (float s : out) assert(s == 0);
    ring.Write(in, 4);
    ring.Read(newlyAttached, out, 4);
    assert(out[0] == .25f && out[1] == -.5f);
    std::cout << "Microphone loopback tests passed (no driver installation).\n";
}
