#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <cstddef>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

namespace {

struct Device {
  AudioDeviceID id;
  std::string name;
  std::string uid;
  UInt32 input_channels;
  Float64 nominal_rate;
};

std::string JsonEscape(const std::string& value) {
  std::string escaped;
  for (const char character : value) {
    switch (character) {
      case '\\':
        escaped += "\\\\";
        break;
      case '"':
        escaped += "\\\"";
        break;
      case '\n':
        escaped += "\\n";
        break;
      case '\r':
        escaped += "\\r";
        break;
      case '\t':
        escaped += "\\t";
        break;
      default:
        escaped += character;
        break;
    }
  }
  return escaped;
}

std::string ReadStringProperty(AudioDeviceID device_id, AudioObjectPropertySelector selector) {
  AudioObjectPropertyAddress address = {
      selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  CFStringRef value = nullptr;
  UInt32 size = sizeof(value);
  if (AudioObjectGetPropertyData(device_id, &address, 0, nullptr, &size, &value) != noErr ||
      value == nullptr) {
    return {};
  }
  char buffer[1024] = {};
  const Boolean converted =
      CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8);
  CFRelease(value);
  return converted ? std::string(buffer) : std::string();
}

UInt32 ReadInputChannels(AudioDeviceID device_id) {
  AudioObjectPropertyAddress address = {kAudioDevicePropertyStreamConfiguration,
                                        kAudioDevicePropertyScopeInput,
                                        kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(device_id, &address, 0, nullptr, &size) != noErr ||
      size < sizeof(AudioBufferList)) {
    return 0;
  }
  std::vector<std::byte> storage(size);
  auto* buffers = reinterpret_cast<AudioBufferList*>(storage.data());
  if (AudioObjectGetPropertyData(device_id, &address, 0, nullptr, &size, buffers) != noErr) {
    return 0;
  }
  UInt32 channels = 0;
  for (UInt32 index = 0; index < buffers->mNumberBuffers; ++index) {
    channels += buffers->mBuffers[index].mNumberChannels;
  }
  return channels;
}

Float64 ReadNominalRate(AudioDeviceID device_id) {
  AudioObjectPropertyAddress address = {kAudioDevicePropertyNominalSampleRate,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
  Float64 rate = 0;
  UInt32 size = sizeof(rate);
  if (AudioObjectGetPropertyData(device_id, &address, 0, nullptr, &size, &rate) != noErr) {
    return 0;
  }
  return rate;
}

bool ReadDeviceIsRunning(AudioDeviceID device_id) {
  AudioObjectPropertyAddress address = {kAudioDevicePropertyDeviceIsRunning,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
  UInt32 running = 0;
  UInt32 size = sizeof(running);
  return AudioObjectGetPropertyData(device_id, &address, 0, nullptr, &size, &running) == noErr &&
         running != 0;
}

std::optional<std::vector<Device>> ReadDevices() {
  AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &size) !=
      noErr) {
    return std::nullopt;
  }
  std::vector<AudioDeviceID> ids(size / sizeof(AudioDeviceID));
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size,
                                 ids.data()) != noErr) {
    return std::nullopt;
  }
  std::vector<Device> devices;
  for (const AudioDeviceID id : ids) {
    devices.push_back(Device{id,
                             ReadStringProperty(id, kAudioObjectPropertyName),
                             ReadStringProperty(id, kAudioDevicePropertyDeviceUID),
                             ReadInputChannels(id),
                             ReadNominalRate(id)});
  }
  if (devices.empty()) {
    return std::nullopt;
  }
  return devices;
}

void PrintDevice(const Device& device) {
  std::cout << "{\"event\":\"audio_device\",\"id\":" << device.id << ",\"name\":\""
            << JsonEscape(device.name) << "\",\"uid\":\"" << JsonEscape(device.uid)
            << "\",\"input_channels\":" << device.input_channels << ",\"nominal_rate\":"
            << device.nominal_rate << "}\n";
}

}  // namespace

int main(int argc, char* argv[]) {
  const std::optional<std::vector<Device>> discovered_devices = ReadDevices();
  if (!discovered_devices.has_value()) {
    std::cerr << "{\"event\":\"audio_device_probe_error\",\"code\":\"enumeration_failed_or_empty\"}\n";
    return 1;
  }
  const std::vector<Device>& devices = *discovered_devices;
  if (argc == 2 && std::string(argv[1]) == "--list") {
    for (const Device& device : devices) {
      PrintDevice(device);
    }
    return 0;
  }
  if (argc == 3 && std::string(argv[1]) == "--require-input") {
    const std::string required_name = argv[2];
    for (const Device& device : devices) {
      if (device.name == required_name && device.input_channels > 0) {
        std::cout << "{\"event\":\"required_audio_input\",\"found\":true,\"name\":\""
                  << JsonEscape(required_name) << "\",\"input_channels\":"
                  << device.input_channels << ",\"nominal_rate\":" << device.nominal_rate
                  << "}\n";
        return 0;
      }
    }
    std::cout << "{\"event\":\"required_audio_input\",\"found\":false,\"name\":\""
              << JsonEscape(required_name) << "\"}\n";
    return 1;
  }
  if (argc == 3 && std::string(argv[1]) == "--require-running-input") {
    const std::string required_name = argv[2];
    for (const Device& device : devices) {
      if (device.name == required_name && device.input_channels > 0) {
        const bool running = ReadDeviceIsRunning(device.id);
        std::cout << "{\"event\":\"required_running_audio_input\",\"found\":true,\"running\":"
                  << (running ? "true" : "false") << ",\"name\":\""
                  << JsonEscape(required_name) << "\"}\n";
        return running ? 0 : 1;
      }
    }
    std::cout << "{\"event\":\"required_running_audio_input\",\"found\":false,\"running\":false,\"name\":\""
              << JsonEscape(required_name) << "\"}\n";
    return 1;
  }
  std::cerr << "usage: audio_device_probe --list | --require-input <name> | "
               "--require-running-input <name>\n";
  return 2;
}
