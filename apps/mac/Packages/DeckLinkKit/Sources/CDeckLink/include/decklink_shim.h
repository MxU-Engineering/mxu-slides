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

    bool supportsCapture;

    int32_t maxAudioChannels;
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

typedef struct {

    uint64_t completions;
    double lastCompletionHostTime;

    uint64_t latched;
    uint64_t shownLatch;

    uint64_t repeats;
    uint64_t skips;

    uint64_t late;
    uint64_t dropped;

    uint64_t jumps;
} DLKOutputTiming;

typedef enum {
    DLKCompletionOnTime = 0,
    DLKCompletionLate = 1,
    DLKCompletionDropped = 2,
    DLKCompletionFlushed = 3,
} DLKCompletionResult;

void dlk_tally_completion(
    DLKOutputTiming *timing, double hostTime, DLKCompletionResult result,
    bool jumped);

DLKOutputTiming dlk_output_timing(DLKOutput *output);

void dlk_output_close(DLKOutput *output);

typedef struct DLKInput DLKInput;

typedef struct {
    const uint8_t *bytes;
    size_t rowBytes;
    int32_t width;
    int32_t height;

    bool interlaced;

    bool hasSignal;

    double hostTime;
    const int32_t *audio;
    int32_t audioFrames;
    int32_t audioChannels;
} DLKInputFrame;

typedef void (*DLKInputFrameHandler)(void *context, const DLKInputFrame *frame);

typedef void (*DLKInputFormatHandler)(
    void *context, const char *modeName, int32_t width, int32_t height,
    int64_t frameDuration, int64_t timeScale, bool interlaced);

DLKInput *dlk_input_open(
    int64_t persistentID, int32_t audioChannels,
    DLKInputFrameHandler onFrame, DLKInputFormatHandler onFormat,
    void *context, char *error, size_t errorLength);

void dlk_input_close(DLKInput *input);

void dlk_deinterlace_blend(
    const uint8_t *source, size_t sourceRowBytes,
    uint8_t *destination, size_t destinationRowBytes,
    size_t rowLength, int32_t height);

#ifdef __cplusplus
}
#endif

#endif
