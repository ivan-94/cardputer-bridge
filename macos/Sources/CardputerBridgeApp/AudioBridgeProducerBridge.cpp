#include "AudioBridgeProducerBridge.h"

#include "AudioBridgeFDBroker.hpp"
#include "AudioBridgeSharedMemory.hpp"

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <limits>
#include <new>
#include <vector>

using cardputer_bridge::audio_ipc::Producer;

extern "C" CardputerAudioProducerRef CardputerAudioProducerCreate(void) {
    return new (std::nothrow) Producer();
}

extern "C" void CardputerAudioProducerDestroy(CardputerAudioProducerRef producer) {
    delete static_cast<Producer*>(producer);
}

extern "C" bool CardputerAudioSystemInputIsPublished(void) {
    AudioObjectPropertyAddress devicesAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 byteCount = 0;
    if (AudioObjectGetPropertyDataSize(
            kAudioObjectSystemObject,
            &devicesAddress,
            0,
            nullptr,
            &byteCount) != noErr
        || byteCount == 0
        || byteCount % sizeof(AudioDeviceID) != 0) {
        return false;
    }
    std::vector<AudioDeviceID> devices(byteCount / sizeof(AudioDeviceID));
    if (AudioObjectGetPropertyData(
            kAudioObjectSystemObject,
            &devicesAddress,
            0,
            nullptr,
            &byteCount,
            devices.data()) != noErr) {
        return false;
    }

    AudioObjectPropertyAddress uidAddress = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    for (const AudioDeviceID device : devices) {
        CFStringRef uid = nullptr;
        UInt32 uidSize = sizeof(uid);
        if (AudioObjectGetPropertyData(
                device,
                &uidAddress,
                0,
                nullptr,
                &uidSize,
                &uid) != noErr
            || uid == nullptr) {
            continue;
        }
        const bool matches = CFEqual(
            uid,
            CFSTR("io.nexu.cardputerbridge.microphone"));
        CFRelease(uid);
        if (matches) {
            return true;
        }
    }
    return false;
}

extern "C" bool CardputerAudioProducerOpen(CardputerAudioProducerRef producer) {
    if (producer == nullptr) {
        return false;
    }
    return static_cast<Producer*>(producer)->OpenBroker(
        cardputer_bridge::audio_ipc::ResolveBrokerSocketPath());
}

extern "C" bool CardputerAudioProducerWritePCM16(
    CardputerAudioProducerRef producer,
    const uint8_t* bytes,
    size_t byteCount) {
    if (producer == nullptr
        || byteCount > std::numeric_limits<UInt32>::max()) {
        return false;
    }
    return static_cast<Producer*>(producer)->WritePCM16Upsampled3x(
        bytes,
        static_cast<UInt32>(byteCount));
}

extern "C" bool CardputerAudioProducerWriteFloat32(
    CardputerAudioProducerRef producer,
    const float* samples,
    size_t frameCount) {
    if (producer == nullptr
        || frameCount > std::numeric_limits<UInt32>::max()) {
        return false;
    }
    return static_cast<Producer*>(producer)->WriteFloat32(
        samples,
        static_cast<UInt32>(frameCount));
}

extern "C" void CardputerAudioProducerStop(CardputerAudioProducerRef producer) {
    if (producer != nullptr) {
        static_cast<Producer*>(producer)->Stop();
    }
}
