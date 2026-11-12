// Copyright (c) 2026 Tietiezhi Tools contributors. MIT License.
// Loads into this test process only; never registers with HAL or starts I/O.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cassert>
#include <cstring>
#include <dlfcn.h>
#include <iostream>
#include <string>
#include <vector>

static AudioServerPlugInDriverRef driver;
static std::vector<unsigned char> Property(AudioObjectID object, AudioObjectPropertySelector selector,
                                           AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    AudioObjectPropertyAddress address{selector, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    assert((*driver)->GetPropertyDataSize(driver, object, 0, &address, 0, nullptr, &size) == noErr);
    std::vector<unsigned char> data(size);
    assert((*driver)->GetPropertyData(driver, object, 0, &address, 0, nullptr, size, &size, data.data()) == noErr);
    return data;
}
template<class T> static T Value(AudioObjectID object, AudioObjectPropertySelector selector,
                                AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    auto data = Property(object, selector, scope); assert(data.size() == sizeof(T));
    T value; std::memcpy(&value, data.data(), sizeof(T)); return value;
}
static std::string String(AudioObjectID object, AudioObjectPropertySelector selector) {
    CFStringRef value = Value<CFStringRef>(object, selector);
    char text[512]; assert(CFStringGetCString(value, text, sizeof(text), kCFStringEncodingUTF8));
    CFRelease(value); return text;
}
int main(int argc, char** argv) {
    assert(argc == 2);
    void* handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!handle) { std::cerr << dlerror() << '\n'; return 1; }
    using Factory = void* (*)(CFAllocatorRef, CFUUIDRef);
    auto factory = reinterpret_cast<Factory>(dlsym(handle, "TietiezhiMicrophoneFactory"));
    assert(factory);
    CFUUIDRef wrong = CFUUIDCreate(nullptr);
    assert(factory(nullptr, wrong) == nullptr); CFRelease(wrong);
    driver = static_cast<AudioServerPlugInDriverRef>(factory(nullptr, kAudioServerPlugInTypeUUID));
    assert(driver);
    auto bytes = Property(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList);
    assert(bytes.size() == sizeof(AudioObjectID) * 2);
    AudioObjectID ids[2]; std::memcpy(ids, bytes.data(), sizeof(ids));
    bool input = false, feed = false;
    for (auto id : ids) {
        const auto uid = String(id, kAudioDevicePropertyDeviceUID);
        CFStringRef qualifier = CFStringCreateWithCString(nullptr, uid.c_str(), kCFStringEncodingUTF8);
        AudioObjectPropertyAddress translate{kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioObjectID translated = kAudioObjectUnknown; UInt32 translatedSize = sizeof(translated);
        assert((*driver)->GetPropertyData(driver, kAudioObjectPlugInObject, 0, &translate,
            sizeof(qualifier), &qualifier, sizeof(translated), &translatedSize, &translated) == noErr);
        CFRelease(qualifier);
        assert(translated == id); // includes the hidden Feed, which visible-device enumeration omits
        assert(Value<Float64>(id, kAudioDevicePropertyNominalSampleRate) == 48000);
        assert(Value<UInt32>(id, kAudioDevicePropertyDeviceIsRunning) == 0);
        if (uid == "com.tietiezhi.tools.microphone.input.v1") {
            input = true;
            assert(String(id, kAudioObjectPropertyName) == "Tietiezhi Microphone");
            assert(Value<UInt32>(id, kAudioDevicePropertyIsHidden) == 0);
        } else if (uid == "com.tietiezhi.tools.microphone.feed.v1") {
            feed = true;
            assert(Value<UInt32>(id, kAudioDevicePropertyIsHidden) == 1);
            assert(Value<UInt32>(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0);
        } else { assert(false); }
        auto streamBytes = Property(id, kAudioDevicePropertyStreams);
        assert(streamBytes.size() == sizeof(AudioObjectID));
        AudioObjectID stream; std::memcpy(&stream, streamBytes.data(), sizeof(stream));
        const auto format = Value<AudioStreamBasicDescription>(stream, kAudioStreamPropertyPhysicalFormat);
        assert(format.mSampleRate == 48000 && format.mChannelsPerFrame == 1 && format.mBitsPerChannel == 32);
        assert(format.mFormatFlags & kAudioFormatFlagIsFloat);
    }
    assert(input && feed);
    std::cout << "Driver identity and stream-format tests passed (no HAL registration or I/O).\n";
    // The library owns process-lifetime singleton objects; don't dlclose under them.
}
