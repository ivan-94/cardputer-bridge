#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>

#include "AudioBridgeSharedMemory.hpp"
#include "AudioBridgeFDBroker.hpp"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <optional>
#include <unistd.h>

namespace {

std::atomic<ULONG> gReferenceCount{0};
std::atomic<UInt64> gIOClientCount{0};
std::atomic<UInt64> gAnchorHostTime{0};
std::atomic<UInt64> gTimestampNumber{0};
std::atomic<Boolean> gInputStreamActive{true};
cardputer_bridge::audio_ipc::Consumer gAudioConsumer;
cardputer_bridge::audio_ipc::FDBrokerServer gFDBroker;
AudioServerPlugInHostRef gHost = nullptr;
std::atomic<Float64> gHostTicksPerFrame{0};

constexpr UInt32 kZeroTimestampPeriod = 16384;

bool IsIsolatedTestMode() noexcept {
    const char* value = std::getenv("CARDPUTER_BRIDGE_AUDIO_TEST_MODE");
    return value != nullptr && std::strcmp(value, "1") == 0;
}

enum : AudioObjectID {
    kObjectIDPlugIn = kAudioObjectPlugInObject,
    kObjectIDDevice = 2,
    kObjectIDInputStream = 3,
};

template <typename T>
OSStatus WriteValue(
    UInt32 inDataSize,
    UInt32* outDataSize,
    void* outData,
    const T& value) {
    if (outDataSize == nullptr || outData == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    if (inDataSize < sizeof(T)) {
        return kAudioHardwareBadPropertySizeError;
    }
    std::memcpy(outData, &value, sizeof(T));
    *outDataSize = sizeof(T);
    return noErr;
}

template <typename T>
OSStatus WriteList(
    UInt32 inDataSize,
    UInt32* outDataSize,
    void* outData,
    const T* values,
    UInt32 valueCount) {
    if (outDataSize == nullptr || outData == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    UInt32 writableCount = inDataSize / sizeof(T);
    if (writableCount > valueCount) {
        writableCount = valueCount;
    }
    if (writableCount > 0) {
        std::memcpy(outData, values, writableCount * sizeof(T));
    }
    *outDataSize = writableCount * sizeof(T);
    return noErr;
}

AudioStreamBasicDescription InputFormat() {
    AudioStreamBasicDescription format{};
    format.mSampleRate = 48000.0;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat
        | kAudioFormatFlagsNativeEndian
        | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = sizeof(Float32);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(Float32);
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 32;
    return format;
}

AudioStreamRangedDescription InputRangedFormat() {
    AudioStreamRangedDescription ranged{};
    ranged.mFormat = InputFormat();
    ranged.mSampleRateRange.mMinimum = 48000.0;
    ranged.mSampleRateRange.mMaximum = 48000.0;
    return ranged;
}

OSStatus WriteEmpty(UInt32* outDataSize) {
    if (outDataSize == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    *outDataSize = 0;
    return noErr;
}

bool HasPlugInSelector(AudioObjectPropertySelector selector) {
    switch (selector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
    }
}

bool HasDeviceSelector(const AudioObjectPropertyAddress& address) {
    switch (address.mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyStreams:
            return true;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyStreamConfiguration:
        case kAudioDevicePropertyStreamFormat:
            return address.mScope == kAudioObjectPropertyScopeInput;
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            return address.mScope == kAudioObjectPropertyScopeInput
                || address.mScope == kAudioObjectPropertyScopeOutput;
        default:
            return false;
    }
}

bool HasStreamSelector(AudioObjectPropertySelector selector) {
    switch (selector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyName:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

Float64 HostTicksPerFrame() {
    mach_timebase_info_data_t timebase{};
    mach_timebase_info(&timebase);
    const Float64 ticksPerSecond = 1.0e9
        * static_cast<Float64>(timebase.denom)
        / static_cast<Float64>(timebase.numer);
    return ticksPerSecond / 48000.0;
}

HRESULT QueryInterface(void*, REFIID requestedInterface, LPVOID* outInterface);
ULONG AddRef(void*);
ULONG Release(void*);
OSStatus Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
OSStatus CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef,
                      const AudioServerPlugInClientInfo*, AudioObjectID*);
OSStatus DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
OSStatus AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID,
                         const AudioServerPlugInClientInfo*);
OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID,
                            const AudioServerPlugInClientInfo*);
OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID,
                                          UInt64, void*);
OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID,
                                        UInt64, void*);
Boolean HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t,
                    const AudioObjectPropertyAddress*);
OSStatus IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t,
                            const AudioObjectPropertyAddress*, Boolean*);
OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t,
                             const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
OSStatus GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t,
                         const AudioObjectPropertyAddress*, UInt32, const void*, UInt32,
                         UInt32*, void*);
OSStatus SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t,
                         const AudioObjectPropertyAddress*, UInt32, const void*, UInt32,
                         const void*);
OSStatus StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
OSStatus StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32,
                          Float64*, UInt64*, UInt64*);
OSStatus WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32,
                           Boolean*, Boolean*);
OSStatus BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32,
                          UInt32, const AudioServerPlugInIOCycleInfo*);
OSStatus DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32,
                       UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
OSStatus EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32,
                        UInt32, const AudioServerPlugInIOCycleInfo*);

AudioServerPlugInDriverInterface gDriverInterface = {
    nullptr,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation,
};

AudioServerPlugInDriverInterface* gDriverInterfacePointer = &gDriverInterface;

HRESULT QueryInterface(void*, REFIID requestedInterface, LPVOID* outInterface) {
    if (outInterface == nullptr) {
        return E_POINTER;
    }
    *outInterface = nullptr;

    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(
        kCFAllocatorDefault, requestedInterface);
    const bool supported = CFEqual(requestedUUID, IUnknownUUID)
        || CFEqual(requestedUUID, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requestedUUID);

    if (!supported) {
        return E_NOINTERFACE;
    }

    *outInterface = &gDriverInterfacePointer;
    AddRef(nullptr);
    return S_OK;
}

ULONG AddRef(void*) {
    ULONG current = gReferenceCount.load(std::memory_order_acquire);
    while (current < std::numeric_limits<ULONG>::max()) {
        if (gReferenceCount.compare_exchange_weak(
                current,
                current + 1,
                std::memory_order_acq_rel)) {
            return current + 1;
        }
    }
    return current;
}

ULONG Release(void*) {
    ULONG current = gReferenceCount.load(std::memory_order_acquire);
    while (current > 0) {
        if (gReferenceCount.compare_exchange_weak(
                current,
                current - 1,
                std::memory_order_acq_rel)) {
            return current - 1;
        }
    }
    return 0;
}

OSStatus Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef inHost) {
    gHost = inHost;
    const char* brokerSocketPath = cardputer_bridge::audio_ipc::ResolveBrokerSocketPath();
    if (IsIsolatedTestMode() && brokerSocketPath == nullptr) {
        return noErr;
    }
    if (brokerSocketPath == nullptr) {
        return kAudioHardwareUnspecifiedError;
    }
    const bool started = IsIsolatedTestMode()
        ? gFDBroker.Start(brokerSocketPath, geteuid())
        : gFDBroker.Start(brokerSocketPath, cardputer_bridge::audio_ipc::ConsoleUserUID);
    if (!started) {
        return kAudioHardwareUnspecifiedError;
    }
    return noErr;
}
OSStatus CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef,
                      const AudioServerPlugInClientInfo*, AudioObjectID*) {
    return kAudioHardwareUnsupportedOperationError;
}
OSStatus DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID) {
    return kAudioHardwareUnsupportedOperationError;
}
OSStatus AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID,
                         const AudioServerPlugInClientInfo* info) {
    (void)info;
    return noErr;
}
OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID,
                            const AudioServerPlugInClientInfo* info) {
    (void)info;
    return noErr;
}
OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID,
                                          UInt64, void*) { return noErr; }
OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID,
                                        UInt64, void*) { return noErr; }
Boolean HasProperty(AudioServerPlugInDriverRef, AudioObjectID inObjectID, pid_t,
                    const AudioObjectPropertyAddress* inAddress) {
    if (inAddress == nullptr) {
        return false;
    }
    Boolean result = false;
    if (inObjectID == kObjectIDPlugIn) {
        result = HasPlugInSelector(inAddress->mSelector);
    } else if (inObjectID == kObjectIDDevice) {
        result = HasDeviceSelector(*inAddress);
    } else if (inObjectID == kObjectIDInputStream) {
        result = HasStreamSelector(inAddress->mSelector);
    }
    return result;
}
OSStatus IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                            pid_t inClientProcessID,
                            const AudioObjectPropertyAddress* inAddress,
                            Boolean* outIsSettable) {
    if (outIsSettable == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    *outIsSettable = inObjectID == kObjectIDInputStream
        && inAddress->mSelector == kAudioStreamPropertyIsActive;
    return noErr;
}
OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                             pid_t inClientProcessID,
                             const AudioObjectPropertyAddress* inAddress, UInt32,
                             const void*, UInt32* outDataSize) {
    if (outDataSize == nullptr || inAddress == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    if (inObjectID == kObjectIDPlugIn) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyManufacturer:
            case kAudioPlugInPropertyResourceBundle:
                *outDataSize = sizeof(CFStringRef);
                break;
            case kAudioPlugInPropertyBoxList:
                *outDataSize = 0;
                break;
            default:
                *outDataSize = sizeof(UInt32);
                break;
        }
        return noErr;
    }
    if (inObjectID == kObjectIDDevice) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
                *outDataSize = sizeof(CFStringRef);
                break;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams:
                *outDataSize = inAddress->mScope == kAudioObjectPropertyScopeOutput
                    ? 0
                    : sizeof(AudioObjectID);
                break;
            case kAudioObjectPropertyControlList:
                *outDataSize = 0;
                break;
            case kAudioDevicePropertyNominalSampleRate:
                *outDataSize = sizeof(Float64);
                break;
            case kAudioDevicePropertyAvailableNominalSampleRates:
                *outDataSize = sizeof(AudioValueRange);
                break;
            case kAudioDevicePropertyStreamConfiguration:
                *outDataSize = sizeof(AudioBufferList);
                break;
            case kAudioDevicePropertyStreamFormat:
                *outDataSize = sizeof(AudioStreamBasicDescription);
                break;
            default:
                *outDataSize = sizeof(UInt32);
                break;
        }
        return noErr;
    }
    if (inObjectID == kObjectIDInputStream) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyOwnedObjects:
                *outDataSize = 0;
                break;
            case kAudioObjectPropertyName:
                *outDataSize = sizeof(CFStringRef);
                break;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                *outDataSize = sizeof(AudioStreamBasicDescription);
                break;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                *outDataSize = sizeof(AudioStreamRangedDescription);
                break;
            default:
                *outDataSize = sizeof(UInt32);
                break;
        }
        return noErr;
    }
    return kAudioHardwareBadObjectError;
}
OSStatus GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                         pid_t inClientProcessID,
                         const AudioObjectPropertyAddress* inAddress,
                         UInt32 inQualifierDataSize, const void* inQualifierData,
                         UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (inAddress == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    if (inObjectID == kObjectIDPlugIn) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass: {
                const AudioClassID value = kAudioObjectClassID;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioObjectPropertyClass: {
                const AudioClassID value = kAudioPlugInClassID;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioObjectPropertyOwner: {
                const AudioObjectID value = kAudioObjectUnknown;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioObjectPropertyManufacturer: {
                const CFStringRef value = CFSTR("Nexu");
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList: {
                const AudioObjectID value = kObjectIDDevice;
                return WriteList(inDataSize, outDataSize, outData, &value, 1);
            }
            case kAudioPlugInPropertyBoxList:
                return WriteEmpty(outDataSize);
            case kAudioPlugInPropertyTranslateUIDToBox: {
                if (inQualifierDataSize != sizeof(CFStringRef)
                    || inQualifierData == nullptr) {
                    return kAudioHardwareBadPropertySizeError;
                }
                const AudioObjectID value = kAudioObjectUnknown;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                if (inQualifierDataSize != sizeof(CFStringRef)
                    || inQualifierData == nullptr) {
                    return kAudioHardwareBadPropertySizeError;
                }
                const CFStringRef uid = *static_cast<const CFStringRef*>(inQualifierData);
                const AudioObjectID value = uid != nullptr
                        && CFStringCompare(
                            uid,
                            CFSTR("io.nexu.cardputerbridge.microphone"),
                            0) == kCFCompareEqualTo
                    ? kObjectIDDevice
                    : kAudioObjectUnknown;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioPlugInPropertyResourceBundle: {
                const CFStringRef value = CFSTR("");
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }
    if (inObjectID == kObjectIDDevice) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass: {
                const AudioClassID value = kAudioObjectClassID;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioObjectPropertyClass: {
                const AudioClassID value = kAudioDeviceClassID;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioObjectPropertyOwner: {
                const AudioObjectID value = kObjectIDPlugIn;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioObjectPropertyName: {
                const CFStringRef value = CFSTR("Cardputer Microphone");
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioObjectPropertyManufacturer: {
                const CFStringRef value = CFSTR("Nexu");
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams: {
                if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                    return WriteEmpty(outDataSize);
                }
                const AudioObjectID value = kObjectIDInputStream;
                return WriteList(inDataSize, outDataSize, outData, &value, 1);
            }
            case kAudioDevicePropertyDeviceUID: {
                const CFStringRef value = CFSTR("io.nexu.cardputerbridge.microphone");
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioDevicePropertyModelUID: {
                const CFStringRef value = CFSTR("io.nexu.cardputerbridge.microphone.model");
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioDevicePropertyTransportType: {
                const UInt32 value = kAudioDeviceTransportTypeVirtual;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioDevicePropertyRelatedDevices: {
                const AudioObjectID value = kObjectIDDevice;
                return WriteList(inDataSize, outDataSize, outData, &value, 1);
            }
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyIsHidden: {
                const UInt32 value = 0;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: {
                const UInt32 value = 1;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioDevicePropertyDeviceIsRunning: {
                const UInt32 value = gIOClientCount.load(std::memory_order_acquire) > 0;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioObjectPropertyControlList:
                return WriteEmpty(outDataSize);
            case kAudioDevicePropertyNominalSampleRate: {
                const Float64 value = 48000.0;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                const AudioValueRange value{48000.0, 48000.0};
                return WriteList(inDataSize, outDataSize, outData, &value, 1);
            }
            case kAudioDevicePropertyZeroTimeStampPeriod: {
                const UInt32 value = kZeroTimestampPeriod;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioDevicePropertyStreamConfiguration: {
                AudioBufferList value{};
                value.mNumberBuffers = 1;
                value.mBuffers[0].mNumberChannels = 1;
                value.mBuffers[0].mDataByteSize = 0;
                value.mBuffers[0].mData = nullptr;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioDevicePropertyStreamFormat: {
                const AudioStreamBasicDescription value = InputFormat();
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }
    if (inObjectID == kObjectIDInputStream) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass: {
                const AudioClassID value = kAudioObjectClassID;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioObjectPropertyClass: {
                const AudioClassID value = kAudioStreamClassID;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioObjectPropertyOwner: {
                const AudioObjectID value = kObjectIDDevice;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioObjectPropertyOwnedObjects:
                return WriteEmpty(outDataSize);
            case kAudioObjectPropertyName: {
                const CFStringRef value = CFSTR("Cardputer Microphone Input");
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioStreamPropertyIsActive: {
                const UInt32 value = gInputStreamActive.load(std::memory_order_acquire);
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioStreamPropertyDirection: {
                const UInt32 value = 1;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioStreamPropertyTerminalType: {
                const UInt32 value = kAudioStreamTerminalTypeMicrophone;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioStreamPropertyStartingChannel: {
                const UInt32 value = 1;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioStreamPropertyLatency: {
                const UInt32 value = 0;
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: {
                const AudioStreamBasicDescription value = InputFormat();
                return WriteValue(inDataSize, outDataSize, outData, value);
            }
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                const AudioStreamRangedDescription value = InputRangedFormat();
                return WriteList(inDataSize, outDataSize, outData, &value, 1);
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }
    return kAudioHardwareBadObjectError;
}
OSStatus SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                         pid_t inClientProcessID,
                         const AudioObjectPropertyAddress* inAddress, UInt32, const void*,
                         UInt32 inDataSize, const void* inData) {
    if (inAddress == nullptr || inData == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    if (inObjectID != kObjectIDInputStream
        || inAddress->mSelector != kAudioStreamPropertyIsActive) {
        return kAudioHardwareUnsupportedOperationError;
    }
    if (inDataSize != sizeof(UInt32)) {
        return kAudioHardwareBadPropertySizeError;
    }
    const Boolean active = *static_cast<const UInt32*>(inData) != 0;
    const Boolean previous = gInputStreamActive.exchange(
        active,
        std::memory_order_acq_rel);
    if (previous != active && gHost != nullptr) {
        gHost->PropertiesChanged(gHost, inObjectID, 1, inAddress);
    }
    return noErr;
}
OSStatus StartIO(AudioServerPlugInDriverRef, AudioObjectID inDeviceObjectID, UInt32) {
    if (inDeviceObjectID != kObjectIDDevice) {
        return kAudioHardwareBadObjectError;
    }
    const UInt64 previous = gIOClientCount.fetch_add(1, std::memory_order_acq_rel);
    if (previous == 0) {
        const int brokerBuffer = gFDBroker.DuplicateBufferDescriptor();
        const bool attached = brokerBuffer >= 0
            ? gAudioConsumer.AttachDescriptor(brokerBuffer)
            : (IsIsolatedTestMode() && gAudioConsumer.Attach());
        if (!attached && !IsIsolatedTestMode()) {
            gIOClientCount.fetch_sub(1, std::memory_order_acq_rel);
            return kAudioHardwareUnspecifiedError;
        }
        gHostTicksPerFrame.store(HostTicksPerFrame(), std::memory_order_release);
        gTimestampNumber.store(0, std::memory_order_release);
        gAnchorHostTime.store(mach_absolute_time(), std::memory_order_release);
    }
    return noErr;
}
OSStatus StopIO(AudioServerPlugInDriverRef, AudioObjectID inDeviceObjectID, UInt32) {
    if (inDeviceObjectID != kObjectIDDevice) {
        return kAudioHardwareBadObjectError;
    }
    UInt64 current = gIOClientCount.load(std::memory_order_acquire);
    do {
        if (current == 0) {
            return kAudioHardwareIllegalOperationError;
        }
    } while (!gIOClientCount.compare_exchange_weak(
        current,
        current - 1,
        std::memory_order_acq_rel));
    if (current == 1) {
        gAudioConsumer.Detach();
    }
    return noErr;
}
OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID inDeviceObjectID,
                          UInt32, Float64* outSampleTime, UInt64* outHostTime,
                          UInt64* outSeed) {
    if (inDeviceObjectID != kObjectIDDevice) {
        return kAudioHardwareBadObjectError;
    }
    if (outSampleTime == nullptr || outHostTime == nullptr || outSeed == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    const UInt64 anchor = gAnchorHostTime.load(std::memory_order_acquire);
    if (anchor == 0) {
        return kAudioHardwareIllegalOperationError;
    }
    const Float64 ticksPerPeriod = gHostTicksPerFrame.load(std::memory_order_acquire)
        * kZeroTimestampPeriod;
    if (ticksPerPeriod <= 0) {
        return kAudioHardwareIllegalOperationError;
    }
    const UInt64 now = mach_absolute_time();
    const UInt64 observed = now > anchor
        ? static_cast<UInt64>((now - anchor) / ticksPerPeriod)
        : 0;
    UInt64 timestamp = gTimestampNumber.load(std::memory_order_acquire);
    while (timestamp < observed
           && !gTimestampNumber.compare_exchange_weak(
               timestamp,
               observed,
               std::memory_order_acq_rel)) {
    }
    timestamp = gTimestampNumber.load(std::memory_order_acquire);
    *outSampleTime = static_cast<Float64>(timestamp * kZeroTimestampPeriod);
    *outHostTime = anchor + static_cast<UInt64>(timestamp * ticksPerPeriod);
    *outSeed = 1;
    return noErr;
}
OSStatus WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID inDeviceObjectID,
                           UInt32, UInt32 inOperationID,
                           Boolean* outWillDo, Boolean* outWillDoInPlace) {
    if (outWillDo == nullptr || outWillDoInPlace == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    if (inDeviceObjectID != kObjectIDDevice) {
        return kAudioHardwareBadObjectError;
    }
    *outWillDo = inOperationID == kAudioServerPlugInIOOperationReadInput;
    *outWillDoInPlace = true;
    return noErr;
}
OSStatus BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32,
                          UInt32, const AudioServerPlugInIOCycleInfo*) { return noErr; }
OSStatus DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID inDeviceObjectID,
                       AudioObjectID inStreamObjectID, UInt32, UInt32 inOperationID,
                       UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo*,
                       void* ioMainBuffer, void*) {
    if (inDeviceObjectID != kObjectIDDevice
        || inStreamObjectID != kObjectIDInputStream) {
        return kAudioHardwareBadObjectError;
    }
    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        if (ioMainBuffer == nullptr) {
            return kAudioHardwareIllegalOperationError;
        }
        if (gInputStreamActive.load(std::memory_order_acquire)) {
            gAudioConsumer.Render(
                static_cast<Float32*>(ioMainBuffer),
                inIOBufferFrameSize);
        } else {
            std::memset(ioMainBuffer, 0, inIOBufferFrameSize * sizeof(Float32));
        }
    }
    return noErr;
}
OSStatus EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32,
                        UInt32, const AudioServerPlugInIOCycleInfo*) { return noErr; }

}  // namespace

extern "C" __attribute__((visibility("default")))
void* CardputerBridgeAudioFactory(CFAllocatorRef, CFUUIDRef requestedType) {
    if (requestedType == nullptr || !CFEqual(requestedType, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }
    return &gDriverInterfacePointer;
}
