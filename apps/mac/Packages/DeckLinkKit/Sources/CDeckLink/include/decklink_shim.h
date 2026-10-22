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

/// The card's frame clock and what reached the wire, cumulative for one
/// open — the 2026-10-11 booth TV feed doubled and skipped frames on motion
/// and nothing in the log could say where. The app paces its mirror by the
/// completions (the card's own clock) and logs the rest.
typedef struct {
    /// Frames the card finished playing, and when the newest finished on
    /// the host clock (seconds, CACurrentMediaTime's timebase).
    uint64_t completions;
    double lastCompletionHostTime;
    /// Frames the app latched, and the latch count the newest completion
    /// copied onto the wire.
    uint64_t latched;
    uint64_t shownLatch;
    /// Completions that found no new latch (the wire showed a frame twice),
    /// and latches overwritten before any completion copied them (the wire
    /// never showed them).
    uint64_t repeats;
    uint64_t skips;
    /// Frames the card reports it displayed late or dropped.
    uint64_t late;
    uint64_t dropped;
    /// Times the schedule fell behind the card's clock and jumped ahead.
    uint64_t jumps;
} DLKOutputTiming;

typedef enum {
    DLKCompletionOnTime = 0,
    DLKCompletionLate = 1,
    DLKCompletionDropped = 2,
    DLKCompletionFlushed = 3,
} DLKCompletionResult;

/// One completion's accounting, applied by the completion callback as it
/// copies the latest latch onto the wire. Pure, so the rules test without
/// a card.
void dlk_tally_completion(
    DLKOutputTiming *timing, double hostTime, DLKCompletionResult result,
    bool jumped);

/// The open output's counters so far.
DLKOutputTiming dlk_output_timing(DLKOutput *output);

void dlk_output_close(DLKOutput *output);

#ifdef __cplusplus
}
#endif

#endif
