#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void* CardputerAudioProducerRef;

CardputerAudioProducerRef CardputerAudioProducerCreate(void);
void CardputerAudioProducerDestroy(CardputerAudioProducerRef producer);
bool CardputerAudioSystemInputIsPublished(void);
bool CardputerAudioProducerOpen(CardputerAudioProducerRef producer);
bool CardputerAudioProducerWritePCM16(
    CardputerAudioProducerRef producer,
    const uint8_t* bytes,
    size_t byteCount);
bool CardputerAudioProducerWriteFloat32(
    CardputerAudioProducerRef producer,
    const float* samples,
    size_t frameCount);
bool CardputerAudioProducerRefreshLease(CardputerAudioProducerRef producer);
void CardputerAudioProducerStop(CardputerAudioProducerRef producer);

#ifdef __cplusplus
}
#endif
