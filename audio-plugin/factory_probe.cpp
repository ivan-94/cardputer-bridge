#include <CoreAudio/AudioServerPlugIn.h>
#include <dlfcn.h>

#include <cstdio>

using Factory = void* (*)(CFAllocatorRef, CFUUIDRef);

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: factory_probe <driver-executable>\n");
        return 64;
    }

    void* handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        std::fprintf(stderr, "dlopen: %s\n", dlerror());
        return 1;
    }

    auto factory = reinterpret_cast<Factory>(dlsym(handle, "CardputerBridgeAudioFactory"));
    if (factory == nullptr) {
        std::fprintf(stderr, "factory symbol missing\n");
        dlclose(handle);
        return 2;
    }

    auto driver = static_cast<AudioServerPlugInDriverRef>(
        factory(kCFAllocatorDefault, kAudioServerPlugInTypeUUID));
    if (driver == nullptr || *driver == nullptr) {
        std::fprintf(stderr, "factory returned no driver\n");
        dlclose(handle);
        return 3;
    }

    LPVOID queried = nullptr;
    const HRESULT result = (*driver)->QueryInterface(
        driver,
        CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID),
        &queried);
    if (result != S_OK || queried == nullptr) {
        std::fprintf(stderr, "QueryInterface failed: %d\n", result);
        dlclose(handle);
        return 4;
    }

    const ULONG remainingReferences = (*driver)->Release(driver);
    if (remainingReferences != 0) {
        std::fprintf(
            stderr,
            "Release must balance QueryInterface to zero, remaining=%u\n",
            remainingReferences);
        dlclose(handle);
        return 5;
    }
    std::puts("AUDIO_FACTORY_PROBE_PASS");
    dlclose(handle);
    return 0;
}
