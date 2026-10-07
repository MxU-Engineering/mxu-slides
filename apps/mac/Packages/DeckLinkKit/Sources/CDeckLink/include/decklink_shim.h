#ifndef DECKLINK_SHIM_H
#define DECKLINK_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char name[256];
    int64_t persistentID;
    bool supportsPlayback;
    bool supportsInternalKeying;
    bool supportsExternalKeying;
} DLKDeviceInfo;

bool dlk_runtime_available(void);

int64_t dlk_api_version(void);

int32_t dlk_copy_devices(DLKDeviceInfo *out, int32_t capacity);

typedef struct {

    char name[64];

    uint32_t modeID;
    int32_t width;
    int32_t height;

    int64_t frameDuration;
    int64_t timeScale;
    bool progressive;

    bool supportsKeying;
} DLKDisplayModeInfo;

int32_t dlk_copy_display_modes(
    int64_t persistentID, DLKDisplayModeInfo *out, int32_t capacity);

uint32_t dlk_configured_output_mode(int64_t persistentID);

bool dlk_reference_locked(int64_t persistentID);

uint32_t dlk_output_link_configuration(int64_t persistentID);

typedef struct DLKOutput DLKOutput;

typedef enum {
    DLKKeyingOff = 0,
    DLKKeyingInternal = 1,
    DLKKeyingExternal = 2,
} DLKKeying;

DLKOutput *dlk_output_open(
    int64_t persistentID, uint32_t modeID,
    DLKKeying keying, char *error, size_t errorLength);

bool dlk_output_display(
    DLKOutput *output, const uint8_t *bgra, size_t bytesPerRow);

void dlk_output_close(DLKOutput *output);

#ifdef __cplusplus
}
#endif

#endif
