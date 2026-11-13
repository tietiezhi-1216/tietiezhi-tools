// Copyright (c) 2026 Tietiezhi Tools contributors. MIT License.
// Uses libASPL (MIT / Apple sample-code licenses), not Oink source code.
#include "Loopback.hpp"
#include <aspl/Driver.hpp>
#include <CoreAudio/AudioServerPlugIn.h>

namespace {
constexpr const char* InputUID = "com.untitled.app.microphone.input.v1";
constexpr const char* FeedUID = "com.untitled.app.microphone.feed.v1";

struct MicrophoneClient : aspl::Client {
    using aspl::Client::Client;
    MicrophoneLoopback::Reader reader;
};
class InputHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler {
public:
    explicit InputHandler(std::shared_ptr<MicrophoneLoopback> ring) : ring_(std::move(ring)) {}
    std::shared_ptr<aspl::Client> OnAddClient(const aspl::ClientInfo& info) override {
        return std::make_shared<MicrophoneClient>(info);
    }
    void OnReadClientInput(const std::shared_ptr<aspl::Client>& client, const std::shared_ptr<aspl::Stream>&,
                          Float64, Float64, void* bytes, UInt32 size) override {
        ring_->Read(static_cast<MicrophoneClient&>(*client).reader, static_cast<float*>(bytes), size / sizeof(float));
    }
private:
    std::shared_ptr<MicrophoneLoopback> ring_;
};
class FeedHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler {
public:
    explicit FeedHandler(std::shared_ptr<MicrophoneLoopback> ring) : ring_(std::move(ring)) {}
    OSStatus OnStartIO() override { ring_->Discard(); return noErr; }
    void OnStopIO() override { ring_->Discard(); }
    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>&, Float64, Float64, const void* bytes, UInt32 size) override {
        ring_->Write(static_cast<const float*>(bytes), size / sizeof(float));
    }
private:
    std::shared_ptr<MicrophoneLoopback> ring_;
};
class HiddenFeed : public aspl::Device {
public:
    using aspl::Device::Device;
    bool GetIsHidden() const override { return true; }
};
std::shared_ptr<aspl::Driver> MakeDriver() {
    auto context = std::make_shared<aspl::Context>();
    auto ring = std::make_shared<MicrophoneLoopback>();
    aspl::DeviceParameters params;
    params.Name = "Untitled Microphone";
    params.Manufacturer = "Untitled";
    params.DeviceUID = InputUID;
    params.ModelUID = "com.untitled.app.microphone.v1";
    params.ConfigurationApplicationBundleID = "com.untitled.app";
    params.SampleRate = 48000; params.ChannelCount = 1;
    params.CanBeDefaultForSystemSounds = false;
    auto input = std::make_shared<aspl::Device>(context, params);
    auto inputHandler = std::make_shared<InputHandler>(ring);
    input->SetControlHandler(inputHandler); input->SetIOHandler(inputHandler);
    aspl::StreamParameters stream;
    stream.Direction = aspl::Direction::Input;
    stream.Format = {48000, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
                     4, 1, 4, 1, 32, 0};
    input->AddStreamAsync(stream);
    params.Name = "Untitled Microphone Feed"; params.DeviceUID = FeedUID;
    params.CanBeDefault = false;
    auto feed = std::make_shared<HiddenFeed>(context, params);
    auto feedHandler = std::make_shared<FeedHandler>(ring);
    feed->SetControlHandler(feedHandler); feed->SetIOHandler(feedHandler);
    stream.Direction = aspl::Direction::Output;
    feed->AddStreamAsync(stream);
    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(input); plugin->AddDevice(feed);
    return std::make_shared<aspl::Driver>(context, plugin);
}
}
extern "C" __attribute__((visibility("default"))) void* UntitledMicrophoneFactory(CFAllocatorRef, CFUUIDRef type) {
    if (!CFEqual(type, kAudioServerPlugInTypeUUID)) return nullptr;
    static auto driver = MakeDriver();
    return driver->GetReference();
}
