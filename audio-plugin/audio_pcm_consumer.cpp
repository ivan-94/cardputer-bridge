#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace {

struct Arguments {
    std::string device_name;
    UInt32 frames{0};
    std::string raw_path;
    std::string metrics_path;
};

struct CaptureContext {
    Float32* samples{nullptr};
    UInt32 capacity{0};
    std::atomic<UInt32> written{0};
    std::atomic<UInt64> first_input_host_time{0};
};

bool RequestMicrophoneAccess() {
    @autoreleasepool {
        const AVAuthorizationStatus current =
            [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        if (current == AVAuthorizationStatusAuthorized) {
            return true;
        }
        if (current == AVAuthorizationStatusDenied
            || current == AVAuthorizationStatusRestricted) {
            return false;
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp activateIgnoringOtherApps:YES];
        NSWindow* permissionWindow = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 420, 140)
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        permissionWindow.title = @"Cardputer Audio Verifier";
        NSTextField* message = [NSTextField
            labelWithString:@"正在等待 macOS 麦克风权限…"];
        message.frame = NSMakeRect(30, 50, 360, 30);
        message.alignment = NSTextAlignmentCenter;
        [permissionWindow.contentView addSubview:message];
        [permissionWindow center];
        [permissionWindow makeKeyAndOrderFront:nil];
        auto decision = std::make_shared<std::atomic<int>>(-1);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                                completionHandler:^(BOOL allowed) {
            decision->store(allowed ? 1 : 0, std::memory_order_release);
        }];
        while (decision->load(std::memory_order_acquire) < 0) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
        }
        [permissionWindow orderOut:nil];
        return decision->load(std::memory_order_acquire) == 1;
    }
}

std::optional<Arguments> ParseArguments(int argc, char** argv) {
    if (argc != 9) {
        return std::nullopt;
    }
    Arguments arguments;
    for (int index = 1; index < argc; index += 2) {
        const std::string key = argv[index];
        const std::string value = argv[index + 1];
        if (key == "--capture-name") {
            arguments.device_name = value;
        } else if (key == "--frames") {
            try {
                const unsigned long parsed = std::stoul(value);
                if (parsed == 0 || parsed > 10'000'000) {
                    return std::nullopt;
                }
                arguments.frames = static_cast<UInt32>(parsed);
            } catch (...) {
                return std::nullopt;
            }
        } else if (key == "--raw") {
            arguments.raw_path = value;
        } else if (key == "--metrics") {
            arguments.metrics_path = value;
        } else {
            return std::nullopt;
        }
    }
    if (arguments.device_name.empty() || arguments.frames == 0
        || arguments.raw_path.empty() || arguments.metrics_path.empty()) {
        return std::nullopt;
    }
    return arguments;
}

std::string ReadStringProperty(
    AudioObjectID object,
    AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address{
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFStringRef value = nullptr;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, &value) != noErr
        || value == nullptr) {
        return {};
    }
    char buffer[1024]{};
    const Boolean converted = CFStringGetCString(
        value,
        buffer,
        sizeof(buffer),
        kCFStringEncodingUTF8);
    CFRelease(value);
    return converted ? std::string(buffer) : std::string();
}

UInt32 ReadInputChannels(AudioDeviceID device) {
    AudioObjectPropertyAddress address{
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr
        || size < sizeof(AudioBufferList)) {
        return 0;
    }
    std::vector<std::byte> storage(size);
    auto* buffers = reinterpret_cast<AudioBufferList*>(storage.data());
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, buffers) != noErr) {
        return 0;
    }
    UInt32 channels = 0;
    for (UInt32 index = 0; index < buffers->mNumberBuffers; ++index) {
        channels += buffers->mBuffers[index].mNumberChannels;
    }
    return channels;
}

std::optional<AudioDeviceID> FindInputDevice(const std::string& required_name) {
    AudioObjectPropertyAddress address{
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(
            kAudioObjectSystemObject,
            &address,
            0,
            nullptr,
            &size) != noErr
        || size == 0) {
        return std::nullopt;
    }
    std::vector<AudioDeviceID> devices(size / sizeof(AudioDeviceID));
    if (AudioObjectGetPropertyData(
            kAudioObjectSystemObject,
            &address,
            0,
            nullptr,
            &size,
            devices.data()) != noErr) {
        return std::nullopt;
    }
    for (const AudioDeviceID device : devices) {
        if (ReadStringProperty(device, kAudioObjectPropertyName) == required_name
            && ReadInputChannels(device) > 0) {
            return device;
        }
    }
    return std::nullopt;
}

std::optional<AudioStreamBasicDescription> ReadInputFormat(AudioDeviceID device) {
    AudioObjectPropertyAddress address{
        kAudioDevicePropertyStreamFormat,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMain,
    };
    AudioStreamBasicDescription format{};
    UInt32 size = sizeof(format);
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &format) != noErr) {
        return std::nullopt;
    }
    return format;
}

OSStatus CaptureCallback(
    AudioDeviceID,
    const AudioTimeStamp*,
    const AudioBufferList* input,
    const AudioTimeStamp* inputTime,
    AudioBufferList*,
    const AudioTimeStamp*,
    void* contextPointer) {
    auto& context = *static_cast<CaptureContext*>(contextPointer);
    if (input == nullptr) {
        return noErr;
    }
    UInt32 destination = context.written.load(std::memory_order_relaxed);
    if (destination == 0 && inputTime != nullptr
        && (inputTime->mFlags & kAudioTimeStampHostTimeValid) != 0) {
        UInt64 unset = 0;
        context.first_input_host_time.compare_exchange_strong(
            unset,
            inputTime->mHostTime,
            std::memory_order_acq_rel);
    }
    for (UInt32 index = 0;
         index < input->mNumberBuffers && destination < context.capacity;
         ++index) {
        const AudioBuffer& buffer = input->mBuffers[index];
        if (buffer.mData == nullptr || buffer.mNumberChannels != 1) {
            continue;
        }
        const UInt32 available = buffer.mDataByteSize / sizeof(Float32);
        const UInt32 count = std::min(available, context.capacity - destination);
        std::memcpy(
            context.samples + destination,
            buffer.mData,
            count * sizeof(Float32));
        destination += count;
    }
    context.written.store(destination, std::memory_order_release);
    return noErr;
}

Float32 Peak(const std::vector<Float32>& samples, UInt32 begin, UInt32 end) {
    Float32 peak = 0;
    for (UInt32 index = begin; index < end; ++index) {
        peak = std::max(peak, std::abs(samples[index]));
    }
    return peak;
}

bool WriteEvidence(
    const Arguments& arguments,
    const std::vector<Float32>& samples,
    Float64 sampleRate,
    UInt64 firstInputHostTime) {
    std::ofstream raw(arguments.raw_path, std::ios::binary | std::ios::trunc);
    raw.write(
        reinterpret_cast<const char*>(samples.data()),
        static_cast<std::streamsize>(samples.size() * sizeof(Float32)));
    if (!raw) {
        return false;
    }
    const UInt32 activeEnd = arguments.frames * 2 / 3;
    const UInt32 tailBegin = arguments.frames * 5 / 6;
    std::ofstream metrics(arguments.metrics_path, std::ios::trunc);
    metrics << "{\n"
            << "  \"sample_rate\": " << sampleRate << ",\n"
            << "  \"channels\": 1,\n"
            << "  \"sample_format\": \"float32\",\n"
            << "  \"first_input_host_time\": " << firstInputHostTime << ",\n"
            << "  \"captured_frames\": " << arguments.frames << ",\n"
            << "  \"active_peak\": " << Peak(samples, 0, activeEnd) << ",\n"
            << "  \"tail_peak\": "
            << Peak(samples, tailBegin, arguments.frames) << "\n"
            << "}\n";
    return static_cast<bool>(metrics);
}

}  // namespace

int main(int argc, char** argv) {
    const std::optional<Arguments> arguments = ParseArguments(argc, argv);
    if (!arguments.has_value()) {
        std::cerr
            << "usage: audio_pcm_consumer --capture-name <name> --frames <count> "
               "--raw <capture.f32le> --metrics <metrics.json>\n";
        return 64;
    }

    const std::optional<AudioDeviceID> device = FindInputDevice(arguments->device_name);
    if (!device.has_value()) {
        std::cerr << "BLOCKED named input device not found: "
                  << arguments->device_name << "\n";
        return 2;
    }
    const std::optional<AudioStreamBasicDescription> format = ReadInputFormat(*device);
    if (!format.has_value()
        || format->mSampleRate < 8'000.0
        || format->mSampleRate > 192'000.0
        || format->mFormatID != kAudioFormatLinearPCM
        || (format->mFormatFlags & kAudioFormatFlagIsFloat) == 0
        || format->mChannelsPerFrame != 1
        || format->mBitsPerChannel != 32) {
        std::cerr << "FAIL named input has unexpected PCM format\n";
        return 1;
    }
    if (!RequestMicrophoneAccess()) {
        std::cerr << "BLOCKED microphone permission not granted\n";
        return 3;
    }

    std::vector<Float32> samples(arguments->frames, 0);
    CaptureContext context{samples.data(), arguments->frames};
    AudioDeviceIOProcID ioProc = nullptr;
    OSStatus status = AudioDeviceCreateIOProcID(
        *device,
        CaptureCallback,
        &context,
        &ioProc);
    if (status != noErr) {
        std::cerr << "FAIL AudioDeviceCreateIOProcID status=" << status << "\n";
        return 1;
    }
    status = AudioDeviceStart(*device, ioProc);
    if (status != noErr) {
        AudioDeviceDestroyIOProcID(*device, ioProc);
        std::cerr << "FAIL AudioDeviceStart status=" << status << "\n";
        return 1;
    }

    const auto deadline = std::chrono::steady_clock::now()
        + std::chrono::seconds(
            static_cast<int>(arguments->frames / 48000) + 3);
    while (context.written.load(std::memory_order_acquire) < arguments->frames
           && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    AudioDeviceStop(*device, ioProc);
    AudioDeviceDestroyIOProcID(*device, ioProc);

    const UInt32 captured = context.written.load(std::memory_order_acquire);
    if (captured != arguments->frames) {
        std::cerr << "FAIL capture timeout frames=" << captured << " expected="
                  << arguments->frames << "\n";
        return 1;
    }
    if (!WriteEvidence(
            *arguments,
            samples,
            format->mSampleRate,
            context.first_input_host_time.load(std::memory_order_acquire))) {
        std::cerr << "FAIL evidence write failed\n";
        return 1;
    }
    std::cout << "PASS captured_pcm frames=" << captured
              << " raw=" << arguments->raw_path
              << " metrics=" << arguments->metrics_path << "\n";
    return 0;
}
