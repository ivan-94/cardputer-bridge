#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/CoreAudio.h>
#include <dlfcn.h>
#include <unistd.h>

#include "AudioBridgeSharedMemory.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <array>
#include <thread>
#include <vector>

namespace {

using Factory = void* (*)(CFAllocatorRef, CFUUIDRef);

struct LoadedDriver {
    void* handle{nullptr};
    AudioServerPlugInDriverRef driver{nullptr};
};

OSStatus TestPropertiesChanged(
    AudioServerPlugInHostRef,
    AudioObjectID,
    UInt32,
    const AudioObjectPropertyAddress*) {
    return noErr;
}

OSStatus TestCopyFromStorage(
    AudioServerPlugInHostRef,
    CFStringRef,
    CFPropertyListRef* outData) {
    if (outData != nullptr) {
        *outData = nullptr;
    }
    return noErr;
}

OSStatus TestWriteToStorage(AudioServerPlugInHostRef, CFStringRef, CFPropertyListRef) {
    return noErr;
}

OSStatus TestDeleteFromStorage(AudioServerPlugInHostRef, CFStringRef) {
    return noErr;
}

OSStatus TestRequestConfigurationChange(
    AudioServerPlugInHostRef,
    AudioObjectID,
    UInt64,
    void*) {
    return noErr;
}

AudioServerPlugInHostInterface gTestHost{
    TestPropertiesChanged,
    TestCopyFromStorage,
    TestWriteToStorage,
    TestDeleteFromStorage,
    TestRequestConfigurationChange,
};

LoadedDriver Load(const char* executable) {
    LoadedDriver loaded;
    loaded.handle = dlopen(executable, RTLD_NOW | RTLD_LOCAL);
    if (loaded.handle == nullptr) {
        std::fprintf(stderr, "dlopen: %s\n", dlerror());
        return loaded;
    }
    auto factory = reinterpret_cast<Factory>(
        dlsym(loaded.handle, "CardputerBridgeAudioFactory"));
    if (factory == nullptr) {
        std::fprintf(stderr, "factory symbol missing\n");
        return loaded;
    }
    loaded.driver = static_cast<AudioServerPlugInDriverRef>(
        factory(kCFAllocatorDefault, kAudioServerPlugInTypeUUID));
    return loaded;
}

bool GetProperty(
    AudioServerPlugInDriverRef driver,
    AudioObjectID object,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    UInt32 size,
    void* value) {
    AudioObjectPropertyAddress address{
        selector,
        scope,
        kAudioObjectPropertyElementMain,
    };
    if (!(*driver)->HasProperty(driver, object, getpid(), &address)) {
        std::fprintf(stderr, "missing property selector=%u object=%u\n", selector, object);
        return false;
    }
    UInt32 written = 0;
    const OSStatus status = (*driver)->GetPropertyData(
        driver,
        object,
        getpid(),
        &address,
        0,
        nullptr,
        size,
        &written,
        value);
    if (status != noErr || written != size) {
        std::fprintf(
            stderr,
            "property read failed selector=%u object=%u status=%d written=%u expected=%u\n",
            selector,
            object,
            status,
            written,
            size);
        return false;
    }
    return true;
}

bool CFStringEquals(CFStringRef value, CFStringRef expected) {
    return value != nullptr && CFStringCompare(value, expected, 0) == kCFCompareEqualTo;
}

AudioObjectID DeviceID(AudioServerPlugInDriverRef driver) {
    AudioObjectID device = kAudioObjectUnknown;
    if (!GetProperty(
            driver,
            kAudioObjectPlugInObject,
            kAudioPlugInPropertyDeviceList,
            kAudioObjectPropertyScopeGlobal,
            sizeof(device),
            &device)) {
        return kAudioObjectUnknown;
    }
    return device;
}

bool GetPropertySize(
    AudioServerPlugInDriverRef driver,
    AudioObjectID object,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    UInt32* size) {
    AudioObjectPropertyAddress address{
        selector,
        scope,
        kAudioObjectPropertyElementMain,
    };
    const OSStatus status = (*driver)->GetPropertyDataSize(
        driver,
        object,
        getpid(),
        &address,
        0,
        nullptr,
        size);
    if (status != noErr) {
        std::fprintf(
            stderr,
            "property size failed selector=%u object=%u status=%d\n",
            selector,
            object,
            status);
        return false;
    }
    return true;
}

bool RequireReadableProperty(
    AudioServerPlugInDriverRef driver,
    AudioObjectID object,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address{
        selector,
        scope,
        kAudioObjectPropertyElementMain,
    };
    if (!(*driver)->HasProperty(driver, object, getpid(), &address)) {
        std::fprintf(stderr, "required property missing selector=%u object=%u\n", selector, object);
        return false;
    }
    UInt32 size = 0;
    if ((*driver)->GetPropertyDataSize(
            driver,
            object,
            getpid(),
            &address,
            0,
            nullptr,
            &size) != noErr) {
        return false;
    }
    if (size == 0) {
        return true;
    }
    std::vector<std::byte> storage(size);
    UInt32 written = 0;
    const OSStatus status = (*driver)->GetPropertyData(
        driver,
        object,
        getpid(),
        &address,
        0,
        nullptr,
        size,
        &written,
        storage.data());
    if (status != noErr || written > size) {
        std::fprintf(
            stderr,
            "required property unreadable selector=%u object=%u status=%d written=%u size=%u\n",
            selector,
            object,
            status,
            written,
            size);
        return false;
    }
    return true;
}

bool RequirePartialListRead(
    AudioServerPlugInDriverRef driver,
    AudioObjectID object,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    UInt32 itemSize,
    UInt32 expectedSize) {
    UInt32 advertisedSize = 0;
    if (!GetPropertySize(driver, object, selector, scope, &advertisedSize)
        || advertisedSize != expectedSize) {
        std::fprintf(
            stderr,
            "list size mismatch selector=%u object=%u actual=%u expected=%u\n",
            selector,
            object,
            advertisedSize,
            expectedSize);
        return false;
    }

    std::array<std::byte, sizeof(AudioStreamRangedDescription)> storage{};
    AudioObjectPropertyAddress address{
        selector,
        scope,
        kAudioObjectPropertyElementMain,
    };
    for (const UInt32 capacity : {0U, itemSize - 1}) {
        UInt32 written = UINT32_MAX;
        const OSStatus status = (*driver)->GetPropertyData(
            driver,
            object,
            getpid(),
            &address,
            0,
            nullptr,
            capacity,
            &written,
            storage.data());
        if (status != noErr || written != 0) {
            std::fprintf(
                stderr,
                "partial list read failed selector=%u object=%u capacity=%u status=%d written=%u\n",
                selector,
                object,
                capacity,
                status,
                written);
            return false;
        }
    }
    return true;
}

int VerifyHALPublicationScan(AudioServerPlugInDriverRef driver) {
    const AudioObjectID device = DeviceID(driver);
    if (device == kAudioObjectUnknown) {
        return 90;
    }
    AudioObjectID stream = kAudioObjectUnknown;
    if (!GetProperty(
            driver,
            device,
            kAudioDevicePropertyStreams,
            kAudioObjectPropertyScopeInput,
            sizeof(stream),
            &stream)
        || stream == kAudioObjectUnknown) {
        return 91;
    }

    struct ListExpectation {
        AudioObjectID object;
        AudioObjectPropertySelector selector;
        AudioObjectPropertyScope scope;
        UInt32 itemSize;
        UInt32 expectedSize;
    };
    const std::array<ListExpectation, 12> lists{{
        {kAudioObjectPlugInObject, kAudioObjectPropertyOwnedObjects,
         kAudioObjectPropertyScopeGlobal, sizeof(AudioObjectID), sizeof(AudioObjectID)},
        {kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList,
         kAudioObjectPropertyScopeGlobal, sizeof(AudioObjectID), sizeof(AudioObjectID)},
        {device, kAudioObjectPropertyOwnedObjects,
         kAudioObjectPropertyScopeGlobal, sizeof(AudioObjectID), sizeof(AudioObjectID)},
        {device, kAudioObjectPropertyOwnedObjects,
         kAudioObjectPropertyScopeInput, sizeof(AudioObjectID), sizeof(AudioObjectID)},
        {device, kAudioObjectPropertyOwnedObjects,
         kAudioObjectPropertyScopeOutput, sizeof(AudioObjectID), 0},
        {device, kAudioDevicePropertyStreams,
         kAudioObjectPropertyScopeGlobal, sizeof(AudioObjectID), sizeof(AudioObjectID)},
        {device, kAudioDevicePropertyStreams,
         kAudioObjectPropertyScopeInput, sizeof(AudioObjectID), sizeof(AudioObjectID)},
        {device, kAudioDevicePropertyStreams,
         kAudioObjectPropertyScopeOutput, sizeof(AudioObjectID), 0},
        {device, kAudioDevicePropertyRelatedDevices,
         kAudioObjectPropertyScopeGlobal, sizeof(AudioObjectID), sizeof(AudioObjectID)},
        {device, kAudioDevicePropertyAvailableNominalSampleRates,
         kAudioObjectPropertyScopeGlobal, sizeof(AudioValueRange), sizeof(AudioValueRange)},
        {stream, kAudioStreamPropertyAvailableVirtualFormats,
         kAudioObjectPropertyScopeGlobal, sizeof(AudioStreamRangedDescription),
         sizeof(AudioStreamRangedDescription)},
        {stream, kAudioStreamPropertyAvailablePhysicalFormats,
         kAudioObjectPropertyScopeGlobal, sizeof(AudioStreamRangedDescription),
         sizeof(AudioStreamRangedDescription)},
    }};
    for (const auto& list : lists) {
        if (!RequirePartialListRead(
                driver,
                list.object,
                list.selector,
                list.scope,
                list.itemSize,
                list.expectedSize)) {
            return 92;
        }
    }

    UInt32 outputSafetyOffset = UINT32_MAX;
    if (!GetProperty(
            driver,
            device,
            kAudioDevicePropertySafetyOffset,
            kAudioObjectPropertyScopeOutput,
            sizeof(outputSafetyOffset),
            &outputSafetyOffset)
        || outputSafetyOffset != 0) {
        std::fprintf(
            stderr,
            "HAL output-scope safety offset probe failed value=%u\n",
            outputSafetyOffset);
        return 93;
    }
    UInt32 outputLatency = UINT32_MAX;
    if (!GetProperty(
            driver,
            device,
            kAudioDevicePropertyLatency,
            kAudioObjectPropertyScopeOutput,
            sizeof(outputLatency),
            &outputLatency)
        || outputLatency != 0) {
        std::fprintf(
            stderr,
            "HAL output-scope latency probe failed value=%u\n",
            outputLatency);
        return 94;
    }

    std::puts("AUDIO_DRIVER_HAL_PUBLICATION_SCAN_PASS");
    return 0;
}

int VerifyPublication(AudioServerPlugInDriverRef driver) {
    const AudioObjectID device = DeviceID(driver);
    if (device == kAudioObjectUnknown) {
        return 10;
    }

    CFStringRef name = nullptr;
    if (!GetProperty(
            driver,
            device,
            kAudioObjectPropertyName,
            kAudioObjectPropertyScopeGlobal,
            sizeof(name),
            &name)
        || !CFStringEquals(name, CFSTR("Cardputer Microphone"))) {
        std::fprintf(stderr, "unexpected device name\n");
        return 11;
    }

    UInt32 alive = 0;
    if (!GetProperty(
            driver,
            device,
            kAudioDevicePropertyDeviceIsAlive,
            kAudioObjectPropertyScopeGlobal,
            sizeof(alive),
            &alive)
        || alive != 1) {
        return 12;
    }

    std::puts("AUDIO_DRIVER_PUBLICATION_PASS");
    return 0;
}

int VerifyFormat(AudioServerPlugInDriverRef driver) {
    const AudioObjectID device = DeviceID(driver);
    if (device == kAudioObjectUnknown) {
        return 20;
    }

    Float64 sampleRate = 0;
    if (!GetProperty(
            driver,
            device,
            kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal,
            sizeof(sampleRate),
            &sampleRate)
        || sampleRate != 48000.0) {
        return 21;
    }

    UInt32 inputStreamSize = 0;
    UInt32 outputStreamSize = 0;
    if (!GetPropertySize(
            driver,
            device,
            kAudioDevicePropertyStreams,
            kAudioObjectPropertyScopeInput,
            &inputStreamSize)
        || !GetPropertySize(
            driver,
            device,
            kAudioDevicePropertyStreams,
            kAudioObjectPropertyScopeOutput,
            &outputStreamSize)
        || inputStreamSize != sizeof(AudioObjectID)
        || outputStreamSize != 0) {
        std::fprintf(
            stderr,
            "unexpected stream sizes input=%u output=%u\n",
            inputStreamSize,
            outputStreamSize);
        return 22;
    }

    AudioObjectID stream = kAudioObjectUnknown;
    if (!GetProperty(
            driver,
            device,
            kAudioDevicePropertyStreams,
            kAudioObjectPropertyScopeInput,
            sizeof(stream),
            &stream)
        || stream == kAudioObjectUnknown) {
        return 23;
    }

    AudioStreamBasicDescription format{};
    if (!GetProperty(
            driver,
            stream,
            kAudioStreamPropertyVirtualFormat,
            kAudioObjectPropertyScopeGlobal,
            sizeof(format),
            &format)
        || format.mSampleRate != 48000.0
        || format.mFormatID != kAudioFormatLinearPCM
        || format.mChannelsPerFrame != 1
        || format.mBitsPerChannel != 32
        || format.mBytesPerFrame != sizeof(Float32)
        || (format.mFormatFlags & kAudioFormatFlagIsFloat) == 0) {
        std::fprintf(stderr, "unexpected stream format\n");
        return 24;
    }

    UInt32 direction = 0;
    UInt32 terminal = 0;
    if (!GetProperty(
            driver,
            stream,
            kAudioStreamPropertyDirection,
            kAudioObjectPropertyScopeGlobal,
            sizeof(direction),
            &direction)
        || !GetProperty(
            driver,
            stream,
            kAudioStreamPropertyTerminalType,
            kAudioObjectPropertyScopeGlobal,
            sizeof(terminal),
            &terminal)
        || direction != 1
        || terminal != kAudioStreamTerminalTypeMicrophone) {
        return 25;
    }

    std::puts("AUDIO_DRIVER_FORMAT_PASS");
    return 0;
}

int VerifySilence(AudioServerPlugInDriverRef driver) {
    const AudioObjectID device = DeviceID(driver);
    AudioObjectID stream = kAudioObjectUnknown;
    if (device == kAudioObjectUnknown
        || !GetProperty(
            driver,
            device,
            kAudioDevicePropertyStreams,
            kAudioObjectPropertyScopeInput,
            sizeof(stream),
            &stream)) {
        return 30;
    }

    if ((*driver)->StartIO(driver, device, 1) != noErr) {
        std::fprintf(stderr, "StartIO failed\n");
        return 31;
    }
    UInt32 running = 0;
    if (!GetProperty(
            driver,
            device,
            kAudioDevicePropertyDeviceIsRunning,
            kAudioObjectPropertyScopeGlobal,
            sizeof(running),
            &running)
        || running != 1) {
        std::fprintf(stderr, "StartIO must expose DeviceIsRunning=true\n");
        return 37;
    }

    Boolean willDo = false;
    Boolean inPlace = false;
    if ((*driver)->WillDoIOOperation(
            driver,
            device,
            1,
            kAudioServerPlugInIOOperationReadInput,
            &willDo,
            &inPlace) != noErr
        || !willDo
        || !inPlace) {
        return 32;
    }

    std::array<Float32, 128> samples;
    samples.fill(0.75F);
    AudioServerPlugInIOCycleInfo cycle{};
    if ((*driver)->DoIOOperation(
            driver,
            device,
            stream,
            1,
            kAudioServerPlugInIOOperationReadInput,
            static_cast<UInt32>(samples.size()),
            &cycle,
            samples.data(),
            nullptr) != noErr) {
        return 33;
    }
    for (const Float32 sample : samples) {
        if (sample != 0.0F) {
            std::fprintf(stderr, "inactive producer must render digital silence\n");
            return 34;
        }
    }

    Float64 sampleTime = -1;
    UInt64 hostTime = 0;
    UInt64 seed = 0;
    if ((*driver)->GetZeroTimeStamp(
            driver,
            device,
            1,
            &sampleTime,
            &hostTime,
            &seed) != noErr
        || sampleTime < 0
        || hostTime == 0
        || seed == 0) {
        return 35;
    }

    if ((*driver)->StopIO(driver, device, 1) != noErr) {
        return 36;
    }
    running = 1;
    if (!GetProperty(
            driver,
            device,
            kAudioDevicePropertyDeviceIsRunning,
            kAudioObjectPropertyScopeGlobal,
            sizeof(running),
            &running)
        || running != 0) {
        std::fprintf(stderr, "StopIO must expose DeviceIsRunning=false\n");
        return 38;
    }
    std::puts("AUDIO_DRIVER_SILENCE_PASS");
    return 0;
}

int VerifyPropertySurface(AudioServerPlugInDriverRef driver) {
    const AudioObjectID device = DeviceID(driver);
    AudioObjectID stream = kAudioObjectUnknown;
    if (device == kAudioObjectUnknown
        || !GetProperty(
            driver,
            device,
            kAudioDevicePropertyStreams,
            kAudioObjectPropertyScopeInput,
            sizeof(stream),
            &stream)) {
        return 40;
    }

    constexpr std::array<AudioObjectPropertySelector, 7> plugInSelectors{
        kAudioObjectPropertyBaseClass,
        kAudioObjectPropertyClass,
        kAudioObjectPropertyOwner,
        kAudioObjectPropertyManufacturer,
        kAudioObjectPropertyOwnedObjects,
        kAudioPlugInPropertyDeviceList,
        kAudioPlugInPropertyResourceBundle,
    };
    for (const auto selector : plugInSelectors) {
        if (!RequireReadableProperty(
                driver,
                kAudioObjectPlugInObject,
                selector,
                kAudioObjectPropertyScopeGlobal)) {
            return 41;
        }
    }

    constexpr std::array<AudioObjectPropertySelector, 18> deviceSelectors{
        kAudioObjectPropertyBaseClass,
        kAudioObjectPropertyClass,
        kAudioObjectPropertyOwner,
        kAudioObjectPropertyName,
        kAudioObjectPropertyManufacturer,
        kAudioObjectPropertyOwnedObjects,
        kAudioDevicePropertyDeviceUID,
        kAudioDevicePropertyModelUID,
        kAudioDevicePropertyTransportType,
        kAudioDevicePropertyRelatedDevices,
        kAudioDevicePropertyClockDomain,
        kAudioDevicePropertyDeviceIsAlive,
        kAudioDevicePropertyDeviceIsRunning,
        kAudioObjectPropertyControlList,
        kAudioDevicePropertyNominalSampleRate,
        kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioDevicePropertyIsHidden,
        kAudioDevicePropertyZeroTimeStampPeriod,
    };
    for (const auto selector : deviceSelectors) {
        if (!RequireReadableProperty(
                driver,
                device,
                selector,
                kAudioObjectPropertyScopeGlobal)) {
            return 42;
        }
    }
    if (!RequireReadableProperty(
            driver,
            device,
            kAudioDevicePropertyStreamConfiguration,
            kAudioObjectPropertyScopeInput)
        || !RequireReadableProperty(
            driver,
            device,
            kAudioDevicePropertyStreamFormat,
            kAudioObjectPropertyScopeInput)) {
        return 49;
    }
    UInt32 configurationSize = 0;
    if (!GetPropertySize(
            driver,
            device,
            kAudioDevicePropertyStreamConfiguration,
            kAudioObjectPropertyScopeInput,
            &configurationSize)
        || configurationSize < sizeof(AudioBufferList)) {
        return 50;
    }
    std::vector<std::byte> configurationStorage(configurationSize);
    UInt32 configurationWritten = 0;
    AudioObjectPropertyAddress configurationAddress{
        kAudioDevicePropertyStreamConfiguration,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain,
    };
    if ((*driver)->GetPropertyData(
            driver,
            device,
            getpid(),
            &configurationAddress,
            0,
            nullptr,
            configurationSize,
            &configurationWritten,
            configurationStorage.data()) != noErr
        || configurationWritten != configurationSize) {
        return 51;
    }
    const auto* configuration = reinterpret_cast<const AudioBufferList*>(
        configurationStorage.data());
    if (configuration->mNumberBuffers != 1
        || configuration->mBuffers[0].mNumberChannels != 1) {
        return 52;
    }
    constexpr std::array<AudioObjectPropertySelector, 12> streamSelectors{
        kAudioObjectPropertyBaseClass,
        kAudioObjectPropertyClass,
        kAudioObjectPropertyOwner,
        kAudioObjectPropertyOwnedObjects,
        kAudioObjectPropertyName,
        kAudioStreamPropertyIsActive,
        kAudioStreamPropertyDirection,
        kAudioStreamPropertyTerminalType,
        kAudioStreamPropertyStartingChannel,
        kAudioStreamPropertyLatency,
        kAudioStreamPropertyAvailableVirtualFormats,
        kAudioStreamPropertyAvailablePhysicalFormats,
    };
    for (const auto selector : streamSelectors) {
        if (!RequireReadableProperty(
                driver,
                stream,
                selector,
                kAudioObjectPropertyScopeGlobal)) {
            return 43;
        }
    }

    UInt32 inputOwnedSize = 0;
    UInt32 outputOwnedSize = 0;
    if (!GetPropertySize(
            driver,
            device,
            kAudioObjectPropertyOwnedObjects,
            kAudioObjectPropertyScopeInput,
            &inputOwnedSize)
        || !GetPropertySize(
            driver,
            device,
            kAudioObjectPropertyOwnedObjects,
            kAudioObjectPropertyScopeOutput,
            &outputOwnedSize)
        || inputOwnedSize != sizeof(AudioObjectID)
        || outputOwnedSize != 0) {
        return 44;
    }

    AudioObjectPropertyAddress activeAddress{
        kAudioStreamPropertyIsActive,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    Boolean activeSettable = false;
    if ((*driver)->IsPropertySettable(
            driver,
            stream,
            getpid(),
            &activeAddress,
            &activeSettable) != noErr
        || !activeSettable) {
        return 45;
    }
    const UInt32 inactive = 0;
    if ((*driver)->SetPropertyData(
            driver,
            stream,
            getpid(),
            &activeAddress,
            0,
            nullptr,
            sizeof(inactive),
            &inactive) != noErr) {
        return 46;
    }
    UInt32 observedActive = 1;
    if (!GetProperty(
            driver,
            stream,
            kAudioStreamPropertyIsActive,
            kAudioObjectPropertyScopeGlobal,
            sizeof(observedActive),
            &observedActive)
        || observedActive != 0) {
        return 47;
    }
    const UInt32 active = 1;
    if ((*driver)->SetPropertyData(
            driver,
            stream,
            getpid(),
            &activeAddress,
            0,
            nullptr,
            sizeof(active),
            &active) != noErr) {
        return 48;
    }

    std::puts("AUDIO_DRIVER_PROPERTY_SURFACE_PASS");
    return 0;
}

int VerifyPulseAndTailSilence(AudioServerPlugInDriverRef driver) {
    const AudioObjectID device = DeviceID(driver);
    AudioObjectID stream = kAudioObjectUnknown;
    if (device == kAudioObjectUnknown
        || !GetProperty(
            driver,
            device,
            kAudioDevicePropertyStreams,
            kAudioObjectPropertyScopeInput,
            sizeof(stream),
            &stream)
        || (*driver)->StartIO(driver, device, 2) != noErr) {
        return 50;
    }

    std::array<Float32, cardputer_bridge::audio_ipc::kTestPulseFrames> pulse{};
    AudioServerPlugInIOCycleInfo cycle{};
    Float32 peak = 0;
    const auto liveDeadline = std::chrono::steady_clock::now()
        + std::chrono::seconds(2);
    while (peak < 0.49F && std::chrono::steady_clock::now() < liveDeadline) {
        if ((*driver)->DoIOOperation(
                driver,
                device,
                stream,
                2,
                kAudioServerPlugInIOOperationReadInput,
                static_cast<UInt32>(pulse.size()),
                &cycle,
                pulse.data(),
                nullptr) != noErr) {
            return 51;
        }
        for (const Float32 sample : pulse) {
            peak = std::max(peak, std::abs(sample));
        }
        if (peak < 0.49F) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    }
    if (peak < 0.49F) {
        std::fprintf(stderr, "shared-memory pulse missing peak=%f\n", peak);
        return 52;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(750));
    std::array<Float32, 128> tail;
    tail.fill(0.75F);
    if ((*driver)->DoIOOperation(
            driver,
            device,
            stream,
            2,
            kAudioServerPlugInIOOperationReadInput,
            static_cast<UInt32>(tail.size()),
            &cycle,
            tail.data(),
            nullptr) != noErr) {
        return 53;
    }
    for (const Float32 sample : tail) {
        if (sample != 0.0F) {
            std::fprintf(stderr, "producer stop must render digital silence\n");
            return 54;
        }
    }
    if ((*driver)->StopIO(driver, device, 2) != noErr) {
        return 55;
    }
    std::puts("AUDIO_DRIVER_PULSE_AND_TAIL_SILENCE_PASS");
    return 0;
}

int VerifyExpiredLeaseSilence(AudioServerPlugInDriverRef driver) {
    const AudioObjectID device = DeviceID(driver);
    AudioObjectID stream = kAudioObjectUnknown;
    if (device == kAudioObjectUnknown
        || !GetProperty(
            driver,
            device,
            kAudioDevicePropertyStreams,
            kAudioObjectPropertyScopeInput,
            sizeof(stream),
            &stream)
        || (*driver)->StartIO(driver, device, 3) != noErr) {
        return 60;
    }
    std::array<Float32, 256> samples;
    samples.fill(0.75F);
    AudioServerPlugInIOCycleInfo cycle{};
    if ((*driver)->DoIOOperation(
            driver,
            device,
            stream,
            3,
            kAudioServerPlugInIOOperationReadInput,
            static_cast<UInt32>(samples.size()),
            &cycle,
            samples.data(),
            nullptr) != noErr) {
        return 61;
    }
    for (const Float32 sample : samples) {
        if (sample != 0.0F) {
            std::fprintf(stderr, "expired producer lease must render digital silence\n");
            return 62;
        }
    }
    if ((*driver)->StopIO(driver, device, 3) != noErr) {
        return 63;
    }
    std::puts("AUDIO_DRIVER_EXPIRED_LEASE_SILENCE_PASS");
    return 0;
}

int VerifyProducerRestart(AudioServerPlugInDriverRef driver) {
    const AudioObjectID device = DeviceID(driver);
    AudioObjectID stream = kAudioObjectUnknown;
    if (device == kAudioObjectUnknown
        || !GetProperty(
            driver,
            device,
            kAudioDevicePropertyStreams,
            kAudioObjectPropertyScopeInput,
            sizeof(stream),
            &stream)
        || (*driver)->StartIO(driver, device, 4) != noErr) {
        return 70;
    }
    AudioServerPlugInIOCycleInfo cycle{};
    std::array<Float32, cardputer_bridge::audio_ipc::kTestPulseFrames> first{};
    bool firstPulseObserved = false;
    const auto firstDeadline = std::chrono::steady_clock::now()
        + std::chrono::seconds(2);
    while (!firstPulseObserved && std::chrono::steady_clock::now() < firstDeadline) {
        if ((*driver)->DoIOOperation(
                driver,
                device,
                stream,
                4,
                kAudioServerPlugInIOOperationReadInput,
                static_cast<UInt32>(first.size()),
                &cycle,
                first.data(),
                nullptr) != noErr) {
            return 71;
        }
        firstPulseObserved = std::any_of(
            first.begin(),
            first.end(),
            [](Float32 sample) { return std::abs(sample) >= 0.49F; });
        if (!firstPulseObserved) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    }
    if (!firstPulseObserved) {
        return 71;
    }
    bool stoppedSilenceObserved = false;
    const auto silenceDeadline = std::chrono::steady_clock::now()
        + std::chrono::seconds(3);
    while (std::chrono::steady_clock::now() < silenceDeadline) {
        std::array<Float32, 256> transition{};
        if ((*driver)->DoIOOperation(
                driver,
                device,
                stream,
                4,
                kAudioServerPlugInIOOperationReadInput,
                static_cast<UInt32>(transition.size()),
                &cycle,
                transition.data(),
                nullptr) != noErr) {
            return 72;
        }
        if (std::all_of(transition.begin(), transition.end(), [](Float32 sample) {
                return sample == 0.0F;
            })) {
            stoppedSilenceObserved = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    if (!stoppedSilenceObserved) {
        std::fprintf(stderr, "running consumer did not observe stopped-producer silence\n");
        return 72;
    }
    std::puts("READY audio_driver_restart_waiting");
    std::fflush(stdout);

    bool restartedPulseObserved = false;
    const auto restartDeadline = std::chrono::steady_clock::now()
        + std::chrono::seconds(8);
    while (std::chrono::steady_clock::now() < restartDeadline) {
        std::array<Float32, 256> restarted{};
        if ((*driver)->DoIOOperation(
                driver,
                device,
                stream,
                4,
                kAudioServerPlugInIOOperationReadInput,
                static_cast<UInt32>(restarted.size()),
                &cycle,
                restarted.data(),
                nullptr) != noErr) {
            return 72;
        }
        if (std::abs(restarted.front()) >= 0.49F) {
            restartedPulseObserved = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    if (!restartedPulseObserved) {
        std::fprintf(stderr, "running consumer did not observe restarted producer\n");
        return 72;
    }
    if ((*driver)->StopIO(driver, device, 4) != noErr) {
        return 73;
    }
    std::puts("AUDIO_DRIVER_PRODUCER_RESTART_PASS");
    return 0;
}

bool WriteRawCapture(const char* path, const std::vector<Float32>& samples) {
    if (path == nullptr) {
        return true;
    }
    FILE* file = std::fopen(path, "wb");
    if (file == nullptr) {
        return false;
    }
    const std::size_t written = std::fwrite(
        samples.data(),
        sizeof(Float32),
        samples.size(),
        file);
    return std::fclose(file) == 0 && written == samples.size();
}

int VerifyFDBroker(AudioServerPlugInDriverRef driver, const char* capturePath) {
    if ((*driver)->Initialize(driver, &gTestHost) != noErr) {
        std::fprintf(stderr, "driver broker initialize failed\n");
        return 80;
    }
    const AudioObjectID device = DeviceID(driver);
    AudioObjectID stream = kAudioObjectUnknown;
    if (device == kAudioObjectUnknown
        || !GetProperty(
            driver,
            device,
            kAudioDevicePropertyStreams,
            kAudioObjectPropertyScopeInput,
            sizeof(stream),
            &stream)
        || (*driver)->StartIO(driver, device, 5) != noErr) {
        return 81;
    }
    AudioServerPlugInIOCycleInfo cycle{};
    std::array<Float32, 256> initial;
    std::vector<Float32> capture;
    initial.fill(0.75F);
    if ((*driver)->DoIOOperation(
            driver,
            device,
            stream,
            5,
            kAudioServerPlugInIOOperationReadInput,
            static_cast<UInt32>(initial.size()),
            &cycle,
            initial.data(),
            nullptr) != noErr
        || std::any_of(initial.begin(), initial.end(), [](Float32 sample) {
            return sample != 0.0F;
        })) {
        return 82;
    }
    capture.insert(capture.end(), initial.begin(), initial.end());
    std::puts("READY audio_driver_fd_broker");
    std::fflush(stdout);
    bool pulseObserved = false;
    const auto pulseDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (std::chrono::steady_clock::now() < pulseDeadline) {
        std::array<Float32, 256> samples{};
        if ((*driver)->DoIOOperation(
                driver,
                device,
                stream,
                5,
                kAudioServerPlugInIOOperationReadInput,
                static_cast<UInt32>(samples.size()),
                &cycle,
                samples.data(),
                nullptr) != noErr) {
            return 83;
        }
        capture.insert(capture.end(), samples.begin(), samples.end());
        if (std::any_of(samples.begin(), samples.end(), [](Float32 sample) {
                return std::abs(sample) >= 0.49F;
            })) {
            pulseObserved = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (!pulseObserved) {
        std::fprintf(stderr, "driver broker pulse missing\n");
        return 84;
    }
    for (int chunk = 0; chunk < 48; ++chunk) {
        std::array<Float32, 256> samples{};
        if ((*driver)->DoIOOperation(
                driver,
                device,
                stream,
                5,
                kAudioServerPlugInIOOperationReadInput,
                static_cast<UInt32>(samples.size()),
                &cycle,
                samples.data(),
                nullptr) != noErr) {
            return 87;
        }
        capture.insert(capture.end(), samples.begin(), samples.end());
    }
    // Producer-first recovery can publish a fresh live-edge pulse after the
    // initial backlog was discarded. Allow that bounded test producer to end
    // before asserting the fail-closed tail.
    std::this_thread::sleep_for(std::chrono::milliseconds(650));
    std::array<Float32, 256> tail;
    tail.fill(0.75F);
    if ((*driver)->DoIOOperation(
            driver,
            device,
            stream,
            5,
            kAudioServerPlugInIOOperationReadInput,
            static_cast<UInt32>(tail.size()),
            &cycle,
            tail.data(),
            nullptr) != noErr
        || std::any_of(tail.begin(), tail.end(), [](Float32 sample) {
            return sample != 0.0F;
        })) {
        return 85;
    }
    capture.insert(capture.end(), tail.begin(), tail.end());
    if (!WriteRawCapture(capturePath, capture)) {
        std::fprintf(stderr, "unable to write driver broker PCM capture\n");
        return 88;
    }
    if ((*driver)->StopIO(driver, device, 5) != noErr) {
        return 86;
    }
    std::puts("AUDIO_DRIVER_FD_BROKER_PASS");
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 3 && argc != 4) {
        std::fprintf(
            stderr,
            "usage: driver_contract_probe <driver-executable> publication|hal-scan|format|silence|surface|pulse|expired|restart|broker\n");
        return 64;
    }
    LoadedDriver loaded = Load(argv[1]);
    if (loaded.driver == nullptr || *loaded.driver == nullptr) {
        std::fprintf(stderr, "factory returned no driver\n");
        return 2;
    }
    int result = 64;
    if (std::strcmp(argv[2], "publication") == 0) {
        result = VerifyPublication(loaded.driver);
    } else if (std::strcmp(argv[2], "hal-scan") == 0) {
        result = VerifyHALPublicationScan(loaded.driver);
    } else if (std::strcmp(argv[2], "format") == 0) {
        result = VerifyFormat(loaded.driver);
    } else if (std::strcmp(argv[2], "silence") == 0) {
        result = VerifySilence(loaded.driver);
    } else if (std::strcmp(argv[2], "surface") == 0) {
        result = VerifyPropertySurface(loaded.driver);
    } else if (std::strcmp(argv[2], "pulse") == 0) {
        result = VerifyPulseAndTailSilence(loaded.driver);
    } else if (std::strcmp(argv[2], "expired") == 0) {
        result = VerifyExpiredLeaseSilence(loaded.driver);
    } else if (std::strcmp(argv[2], "restart") == 0) {
        result = VerifyProducerRestart(loaded.driver);
    } else if (std::strcmp(argv[2], "broker") == 0) {
        result = VerifyFDBroker(loaded.driver, argc == 4 ? argv[3] : nullptr);
    } else {
        std::fprintf(stderr, "unknown probe mode: %s\n", argv[2]);
    }
    dlclose(loaded.handle);
    return result;
}
