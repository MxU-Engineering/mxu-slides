#include "decklink_shim.h"

#include <mach/mach_time.h>

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

#include "Vendor/DeckLinkAPI.h"

namespace {

template <typename T>
struct COMRef {
    T *pointer = nullptr;
    ~COMRef() {
        if (pointer) pointer->Release();
    }
    T **out() { return &pointer; }
    T *operator->() const { return pointer; }
    explicit operator bool() const { return pointer != nullptr; }
    T *take() {
        T *result = pointer;
        pointer = nullptr;
        return result;
    }
};

double hostSeconds() {
    static const mach_timebase_info_data_t timebase = [] {
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        return info;
    }();
    return (double)mach_absolute_time() * timebase.numer / timebase.denom /
           1e9;
}

void writeError(char *error, size_t errorLength, const std::string &message) {
    if (!error || errorLength == 0) return;
    strncpy(error, message.c_str(), errorLength - 1);
    error[errorLength - 1] = '\0';
}

void copyDisplayName(IDeckLink *device, char *out, size_t capacity) {
    out[0] = '\0';
    CFStringRef name = nullptr;
    if (device->GetDisplayName(&name) != S_OK || name == nullptr) return;
    CFStringGetCString(name, out, (CFIndex)capacity, kCFStringEncodingUTF8);
    CFRelease(name);
}

int64_t stableID(IDeckLinkProfileAttributes *attributes, int32_t index) {
    int64_t value = 0;
    if (attributes &&
        attributes->GetInt(BMDDeckLinkPersistentID, &value) == S_OK)
        return value;
    if (attributes &&
        attributes->GetInt(BMDDeckLinkTopologicalID, &value) == S_OK)
        return value;
    return (int64_t)index | (1LL << 62);
}

IDeckLink *findDevice(int64_t persistentID) {
    COMRef<IDeckLinkIterator> iterator;
    iterator.pointer = CreateDeckLinkIteratorInstance();
    if (!iterator) return nullptr;
    int32_t index = 0;
    IDeckLink *device = nullptr;
    while (iterator->Next(&device) == S_OK) {
        COMRef<IDeckLinkProfileAttributes> attributes;
        device->QueryInterface(
            IID_IDeckLinkProfileAttributes, (void **)attributes.out());
        if (stableID(attributes.pointer, index) == persistentID) return device;
        device->Release();
        index += 1;
    }
    return nullptr;
}

}

extern "C" {

bool dlk_runtime_available(void) {
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) return false;
    iterator->Release();
    return true;
}

int64_t dlk_api_version(void) {
    COMRef<IDeckLinkAPIInformation> info;
    info.pointer = CreateDeckLinkAPIInformationInstance();
    if (!info) return 0;
    int64_t version = 0;
    if (info->GetInt(BMDDeckLinkAPIVersion, &version) != S_OK) return 0;
    return version;
}

int32_t dlk_copy_devices(DLKDeviceInfo *out, int32_t capacity) {
    if (!out || capacity <= 0) return 0;
    COMRef<IDeckLinkIterator> iterator;
    iterator.pointer = CreateDeckLinkIteratorInstance();
    if (!iterator) return 0;

    int32_t written = 0;
    int32_t index = 0;
    IDeckLink *device = nullptr;
    while (written < capacity && iterator->Next(&device) == S_OK) {
        COMRef<IDeckLink> deviceRef;
        deviceRef.pointer = device;
        COMRef<IDeckLinkProfileAttributes> attributes;
        deviceRef->QueryInterface(
            IID_IDeckLinkProfileAttributes, (void **)attributes.out());

        DLKDeviceInfo &info = out[written];
        memset(&info, 0, sizeof(info));
        copyDisplayName(deviceRef.pointer, info.name, sizeof(info.name));
        info.persistentID = stableID(attributes.pointer, index);

        int64_t ioSupport = 0;
        if (attributes &&
            attributes->GetInt(BMDDeckLinkVideoIOSupport, &ioSupport) == S_OK) {
            info.supportsPlayback = (ioSupport & bmdDeviceSupportsPlayback) != 0;
            info.supportsCapture = (ioSupport & bmdDeviceSupportsCapture) != 0;
        }
        int64_t audioChannels = 0;
        if (attributes &&
            attributes->GetInt(BMDDeckLinkMaximumAudioChannels, &audioChannels) ==
                S_OK)
            info.maxAudioChannels = (int32_t)audioChannels;
        bool flag = false;
        if (attributes &&
            attributes->GetFlag(BMDDeckLinkSupportsInternalKeying, &flag) == S_OK)
            info.supportsInternalKeying = flag;
        flag = false;
        if (attributes &&
            attributes->GetFlag(BMDDeckLinkSupportsExternalKeying, &flag) == S_OK)
            info.supportsExternalKeying = flag;

        written += 1;
        index += 1;
    }
    return written;
}

int32_t dlk_copy_display_modes(
    int64_t persistentID, DLKDisplayModeInfo *out, int32_t capacity) {
    if (!out || capacity <= 0) return 0;
    COMRef<IDeckLink> device;
    device.pointer = findDevice(persistentID);
    if (!device) return 0;
    COMRef<IDeckLinkOutput> output;
    if (device->QueryInterface(IID_IDeckLinkOutput, (void **)output.out()) !=
            S_OK ||
        !output)
        return 0;
    COMRef<IDeckLinkDisplayModeIterator> modes;
    if (output->GetDisplayModeIterator(modes.out()) != S_OK || !modes) return 0;

    int32_t written = 0;
    IDeckLinkDisplayMode *candidate = nullptr;
    while (written < capacity && modes->Next(&candidate) == S_OK) {
        COMRef<IDeckLinkDisplayMode> candidateRef;
        candidateRef.pointer = candidate;
        BMDTimeValue duration = 0;
        BMDTimeScale scale = 0;
        if (candidateRef->GetFrameRate(&duration, &scale) != S_OK ||
            duration == 0)
            continue;

        bool supported = false;
        BMDDisplayMode actualMode = 0;
        if (output->DoesSupportVideoMode(
                bmdVideoConnectionUnspecified, candidateRef->GetDisplayMode(),
                bmdFormat8BitBGRA, bmdNoVideoOutputConversion,
                bmdSupportedVideoModeDefault, &actualMode, &supported) != S_OK ||
            !supported)
            continue;

        DLKDisplayModeInfo &info = out[written];
        memset(&info, 0, sizeof(info));
        info.name[0] = '\0';
        CFStringRef name = nullptr;
        if (candidateRef->GetName(&name) == S_OK && name != nullptr) {
            CFStringGetCString(name, info.name, (CFIndex)sizeof(info.name),
                               kCFStringEncodingUTF8);
            CFRelease(name);
        }
        info.modeID = candidateRef->GetDisplayMode();
        info.width = (int32_t)candidateRef->GetWidth();
        info.height = (int32_t)candidateRef->GetHeight();
        info.frameDuration = duration;
        info.timeScale = scale;
        info.progressive =
            candidateRef->GetFieldDominance() == bmdProgressiveFrame;
        bool keyable = false;
        info.supportsKeying =
            output->DoesSupportVideoMode(
                bmdVideoConnectionUnspecified, candidateRef->GetDisplayMode(),
                bmdFormat8BitBGRA, bmdNoVideoOutputConversion,
                bmdSupportedVideoModeKeying, &actualMode, &keyable) == S_OK &&
            keyable;
        written += 1;
    }
    return written;
}

bool dlk_reference_locked(int64_t persistentID) {
    COMRef<IDeckLink> device;
    device.pointer = findDevice(persistentID);
    if (!device) return false;
    COMRef<IDeckLinkStatus> deviceStatus;
    if (device->QueryInterface(
            IID_IDeckLinkStatus, (void **)deviceStatus.out()) != S_OK ||
        !deviceStatus)
        return false;
    bool locked = false;
    deviceStatus->GetFlag(bmdDeckLinkStatusReferenceSignalLocked, &locked);
    return locked;
}

uint32_t dlk_output_link_configuration(int64_t persistentID) {
    COMRef<IDeckLink> device;
    device.pointer = findDevice(persistentID);
    if (!device) return 0;
    COMRef<IDeckLinkConfiguration> configuration;
    if (device->QueryInterface(
            IID_IDeckLinkConfiguration, (void **)configuration.out()) != S_OK ||
        !configuration)
        return 0;
    int64_t link = 0;
    if (configuration->GetInt(
            bmdDeckLinkConfigSDIOutputLinkConfiguration, &link) != S_OK)
        return 0;
    return (uint32_t)link;
}

uint32_t dlk_configured_output_mode(int64_t persistentID) {
    COMRef<IDeckLink> device;
    device.pointer = findDevice(persistentID);
    if (!device) return 0;
    COMRef<IDeckLinkConfiguration> configuration;
    if (device->QueryInterface(
            IID_IDeckLinkConfiguration, (void **)configuration.out()) != S_OK ||
        !configuration)
        return 0;
    int64_t mode = 0;
    if (configuration->GetInt(
            bmdDeckLinkConfigDefaultVideoOutputMode, &mode) != S_OK)
        return 0;
    return (uint32_t)mode;
}

struct DLKOutput;

class DLKScheduleCallback : public IDeckLinkVideoOutputCallback {
public:
    explicit DLKScheduleCallback(DLKOutput *owner) : owner_(owner) {}
    HRESULT QueryInterface(REFIID, LPVOID *object) override {
        *object = nullptr;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++refs_; }
    ULONG Release() override {
        ULONG remaining = --refs_;
        if (remaining == 0) delete this;
        return remaining;
    }
    HRESULT ScheduledFrameCompleted(
        IDeckLinkVideoFrame *frame, BMDOutputFrameCompletionResult) override;
    HRESULT ScheduledPlaybackHasStopped() override { return S_OK; }

private:
    DLKOutput *owner_;
    ULONG refs_ = 1;
};

struct DLKOutput {
    IDeckLink *device = nullptr;
    IDeckLinkOutput *output = nullptr;
    IDeckLinkKeyer *keyer = nullptr;
    static const int kFrameCount = 4;
    IDeckLinkMutableVideoFrame *frames[kFrameCount] = {};

    IDeckLinkVideoBuffer *frameBuffers[kFrameCount] = {};
    DLKScheduleCallback *callback = nullptr;

    uint8_t *latest = nullptr;
    std::mutex mutex;
    BMDTimeValue streamTime = 0;
    BMDTimeValue frameDuration = 0;
    BMDTimeScale timeScale = 0;
    bool playing = false;

    bool keyerLevelReasserted = false;

    std::chrono::steady_clock::time_point lastCompletion =
        std::chrono::steady_clock::now();

    DLKOutputTiming timing = {};
    int32_t width = 0;
    int32_t height = 0;

    IDeckLinkVideoBuffer *bufferFor(IDeckLinkVideoFrame *frame) {
        for (int index = 0; index < kFrameCount; index += 1) {
            if (frames[index] == frame) return frameBuffers[index];
        }
        return nullptr;
    }
};

HRESULT DLKScheduleCallback::ScheduledFrameCompleted(
    IDeckLinkVideoFrame *frame, BMDOutputFrameCompletionResult result) {
    DLKOutput *output = owner_;
    if (!output) return S_OK;

    BMDTimeValue hardwareTime = 0;
    double playbackSpeed = 1.0;
    bool haveHardwareTime =
        output->output->GetScheduledStreamTime(
            output->timeScale, &hardwareTime, &playbackSpeed) == S_OK;
    bool reassertKeyerLevel = false;
    {
        std::lock_guard<std::mutex> guard(output->mutex);
        if (!output->keyerLevelReasserted) {
            output->keyerLevelReasserted = true;
            reassertKeyerLevel = output->keyer != nullptr;
        }
    }
    if (reassertKeyerLevel) {
        output->keyer->SetLevel(255);
        output->keyer->RampUp(0);
    }
    BMDTimeValue scheduleAt = 0;
    {

        std::lock_guard<std::mutex> guard(output->mutex);
        if (!output->playing) return S_OK;
        output->lastCompletion = std::chrono::steady_clock::now();
        bool jumped = haveHardwareTime &&
                      output->streamTime < hardwareTime + output->frameDuration;
        if (jumped) {
            output->streamTime = hardwareTime + 2 * output->frameDuration;
        }
        DLKCompletionResult tallied = DLKCompletionOnTime;
        switch (result) {
            case bmdOutputFrameDisplayedLate: tallied = DLKCompletionLate; break;
            case bmdOutputFrameDropped: tallied = DLKCompletionDropped; break;
            case bmdOutputFrameFlushed: tallied = DLKCompletionFlushed; break;
            default: break;
        }
        dlk_tally_completion(&output->timing, hostSeconds(), tallied, jumped);
        IDeckLinkVideoBuffer *buffer = output->bufferFor(frame);
        if (buffer && buffer->StartAccess(bmdBufferAccessWrite) == S_OK) {
            void *destination = nullptr;
            if (buffer->GetBytes(&destination) == S_OK && destination) {
                memcpy(destination, output->latest,
                       (size_t)output->width * 4 * output->height);
            }
            buffer->EndAccess(bmdBufferAccessWrite);
        }
        scheduleAt = output->streamTime;
        output->streamTime += output->frameDuration;
    }
    if (output->output->ScheduleVideoFrame(
            frame, scheduleAt, output->frameDuration, output->timeScale) !=
        S_OK) {

        std::lock_guard<std::mutex> guard(output->mutex);
        output->streamTime += output->frameDuration;
        output->output->ScheduleVideoFrame(
            frame, output->streamTime, output->frameDuration,
            output->timeScale);
        output->streamTime += output->frameDuration;
    }
    return S_OK;
}

DLKOutput *dlk_output_open(
    int64_t persistentID, uint32_t modeID,
    DLKKeying keying, char *error, size_t errorLength) {
    COMRef<IDeckLink> device;
    device.pointer = findDevice(persistentID);
    if (!device) {
        writeError(error, errorLength,
                   "DeckLink device not found (unplugged, or Desktop Video "
                   "not installed)");
        return nullptr;
    }

    COMRef<IDeckLinkOutput> output;
    if (device->QueryInterface(IID_IDeckLinkOutput, (void **)output.out()) !=
            S_OK ||
        !output) {
        writeError(error, errorLength, "device does not support playback");
        return nullptr;
    }

    COMRef<IDeckLinkDisplayModeIterator> modes;
    if (output->GetDisplayModeIterator(modes.out()) != S_OK || !modes) {
        writeError(error, errorLength, "display modes unavailable");
        return nullptr;
    }
    int32_t width = 0;
    int32_t height = 0;
    BMDDisplayMode chosenMode = 0;
    IDeckLinkDisplayMode *candidate = nullptr;
    while (modes->Next(&candidate) == S_OK) {
        COMRef<IDeckLinkDisplayMode> candidateRef;
        candidateRef.pointer = candidate;
        if (candidateRef->GetDisplayMode() != (BMDDisplayMode)modeID) continue;
        chosenMode = candidateRef->GetDisplayMode();
        width = (int32_t)candidateRef->GetWidth();
        height = (int32_t)candidateRef->GetHeight();
        break;
    }
    if (!chosenMode) {
        writeError(error, errorLength,
                   "display mode is not offered by this device");
        return nullptr;
    }

    bool supported = false;
    BMDDisplayMode actualMode = 0;
    if (output->DoesSupportVideoMode(
            bmdVideoConnectionUnspecified, chosenMode, bmdFormat8BitBGRA,
            bmdNoVideoOutputConversion,
            keying != DLKKeyingOff ? bmdSupportedVideoModeKeying
                                   : bmdSupportedVideoModeDefault,
            &actualMode, &supported) != S_OK ||
        !supported) {
        writeError(error, errorLength,
                   keying != DLKKeyingOff
                       ? "this display mode cannot carry a keyed output on "
                         "this device (check link grouping in Desktop Video "
                         "Setup)"
                       : "device cannot output BGRA at the requested mode");
        return nullptr;
    }

    if (output->EnableVideoOutput(chosenMode, bmdVideoOutputFlagDefault) !=
        S_OK) {
        writeError(error, errorLength,
                   "video output enable failed (output may be claimed by "
                   "another app)");
        return nullptr;
    }

    COMRef<IDeckLinkKeyer> keyer;
    if (keying != DLKKeyingOff) {
        if (device->QueryInterface(IID_IDeckLinkKeyer, (void **)keyer.out()) !=
                S_OK ||
            !keyer) {
            output->DisableVideoOutput();
            writeError(error, errorLength, "device does not support keying");
            return nullptr;
        }

        keyer->SetLevel(255);
        if (keyer->Enable(keying == DLKKeyingExternal) != S_OK) {
            output->DisableVideoOutput();
            writeError(error, errorLength,
                       keying == DLKKeyingExternal
                           ? "external key/fill not supported by this device"
                           : "internal keying not supported by this device");
            return nullptr;
        }
        keyer->SetLevel(255);
        keyer->RampUp(0);
    }

    BMDTimeValue frameDuration = 0;
    BMDTimeScale timeScale = 0;
    {
        COMRef<IDeckLinkDisplayModeIterator> timingModes;
        if (output->GetDisplayModeIterator(timingModes.out()) == S_OK &&
            timingModes) {
            IDeckLinkDisplayMode *candidate = nullptr;
            while (timingModes->Next(&candidate) == S_OK) {
                COMRef<IDeckLinkDisplayMode> candidateRef;
                candidateRef.pointer = candidate;
                if (candidateRef->GetDisplayMode() == chosenMode) {
                    candidateRef->GetFrameRate(&frameDuration, &timeScale);
                    break;
                }
            }
        }
    }
    if (frameDuration == 0 || timeScale == 0) {
        output->DisableVideoOutput();
        if (keyer) keyer->Disable();
        writeError(error, errorLength, "display mode timing unavailable");
        return nullptr;
    }

    DLKOutput *handle = new DLKOutput();
    handle->width = width;
    handle->height = height;
    handle->frameDuration = frameDuration;
    handle->timeScale = timeScale;
    handle->latest =
        (uint8_t *)calloc((size_t)width * 4 * height, 1);

    bool framesReady = handle->latest != nullptr;
    for (int index = 0; framesReady && index < DLKOutput::kFrameCount;
         index += 1) {
        if (output->CreateVideoFrame(
                width, height, width * 4, bmdFormat8BitBGRA,
                bmdFrameFlagDefault, &handle->frames[index]) != S_OK ||
            !handle->frames[index] ||
            handle->frames[index]->QueryInterface(
                IID_IDeckLinkVideoBuffer,
                (void **)&handle->frameBuffers[index]) != S_OK) {
            framesReady = false;
        }
    }
    if (!framesReady) {
        output->DisableVideoOutput();
        if (keyer) keyer->Disable();
        for (int index = 0; index < DLKOutput::kFrameCount; index += 1) {
            if (handle->frameBuffers[index]) handle->frameBuffers[index]->Release();
            if (handle->frames[index]) handle->frames[index]->Release();
        }
        free(handle->latest);
        delete handle;
        writeError(error, errorLength, "video frame allocation failed");
        return nullptr;
    }

    handle->callback = new DLKScheduleCallback(handle);
    output->SetScheduledFrameCompletionCallback(handle->callback);
    handle->playing = true;
    for (int index = 0; index < DLKOutput::kFrameCount; index += 1) {

        IDeckLinkVideoBuffer *buffer = handle->frameBuffers[index];
        if (buffer && buffer->StartAccess(bmdBufferAccessWrite) == S_OK) {
            void *destination = nullptr;
            if (buffer->GetBytes(&destination) == S_OK && destination) {
                memcpy(destination, handle->latest,
                       (size_t)width * 4 * height);
            }
            buffer->EndAccess(bmdBufferAccessWrite);
        }
        output->ScheduleVideoFrame(
            handle->frames[index], handle->streamTime, frameDuration, timeScale);
        handle->streamTime += frameDuration;
    }
    if (output->StartScheduledPlayback(0, timeScale, 1.0) != S_OK) {
        handle->playing = false;
        output->SetScheduledFrameCompletionCallback(nullptr);
        output->DisableVideoOutput();
        if (keyer) keyer->Disable();
        for (int index = 0; index < DLKOutput::kFrameCount; index += 1) {
            handle->frameBuffers[index]->Release();
            handle->frames[index]->Release();
        }
        handle->callback->Release();
        free(handle->latest);
        delete handle;
        writeError(error, errorLength, "scheduled playback failed to start");
        return nullptr;
    }

    handle->device = device.take();
    handle->output = output.take();
    handle->keyer = keyer.take();
    return handle;
}

bool dlk_output_display(
    DLKOutput *output, const uint8_t *bgra, size_t bytesPerRow) {
    if (!output || !bgra) return false;
    std::lock_guard<std::mutex> guard(output->mutex);
    if (!output->playing) return false;
    if (std::chrono::steady_clock::now() - output->lastCompletion >
        std::chrono::seconds(1))
        return false;
    const size_t destinationRow = (size_t)output->width * 4;
    const size_t copyRow =
        bytesPerRow < destinationRow ? bytesPerRow : destinationRow;
    for (int32_t row = 0; row < output->height; row += 1) {
        memcpy(output->latest + (size_t)row * destinationRow,
               bgra + (size_t)row * bytesPerRow, copyRow);
    }
    output->timing.latched += 1;
    return true;
}

void dlk_tally_completion(
    DLKOutputTiming *timing, double hostTime, DLKCompletionResult result,
    bool jumped) {
    if (!timing) return;
    timing->completions += 1;
    timing->lastCompletionHostTime = hostTime;

    if (timing->latched > 0) {
        uint64_t fresh = timing->latched - timing->shownLatch;
        if (fresh == 0) {
            timing->repeats += 1;
        } else if (fresh > 1) {
            timing->skips += fresh - 1;
        }
    }
    timing->shownLatch = timing->latched;
    if (result == DLKCompletionLate) timing->late += 1;
    if (result == DLKCompletionDropped) timing->dropped += 1;
    if (jumped) timing->jumps += 1;
}

DLKOutputTiming dlk_output_timing(DLKOutput *output) {
    if (!output) return DLKOutputTiming{};
    std::lock_guard<std::mutex> guard(output->mutex);
    return output->timing;
}

void dlk_output_close(DLKOutput *output) {
    if (!output) return;
    {
        std::lock_guard<std::mutex> guard(output->mutex);
        output->playing = false;
    }
    output->output->StopScheduledPlayback(0, nullptr, output->timeScale);
    output->output->SetScheduledFrameCompletionCallback(nullptr);
    output->output->DisableVideoOutput();
    if (output->keyer) {
        output->keyer->Disable();
        output->keyer->Release();
    }
    for (int index = 0; index < DLKOutput::kFrameCount; index += 1) {
        output->frameBuffers[index]->Release();
        output->frames[index]->Release();
    }
    output->callback->Release();
    output->output->Release();
    output->device->Release();
    free(output->latest);
    delete output;
}

}

struct DLKInput;

namespace {

bool isInterlaced(BMDFieldDominance dominance) {
    return dominance == bmdLowerFieldFirst || dominance == bmdUpperFieldFirst;
}

}

class DLKInputCallback : public IDeckLinkInputCallback {
public:
    explicit DLKInputCallback(DLKInput *owner) : owner_(owner) {}
    HRESULT QueryInterface(REFIID, LPVOID *object) override {
        *object = nullptr;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++refs_; }
    ULONG Release() override {
        ULONG remaining = --refs_;
        if (remaining == 0) delete this;
        return remaining;
    }
    HRESULT VideoInputFormatChanged(
        BMDVideoInputFormatChangedEvents events, IDeckLinkDisplayMode *mode,
        BMDDetectedVideoInputFormatFlags flags) override;
    HRESULT VideoInputFrameArrived(
        IDeckLinkVideoInputFrame *video,
        IDeckLinkAudioInputPacket *audio) override;

private:
    DLKInput *owner_;
    std::atomic<ULONG> refs_{1};
};

struct DLKInput {
    IDeckLink *device = nullptr;
    IDeckLinkInput *input = nullptr;
    DLKInputCallback *callback = nullptr;
    DLKInputFrameHandler onFrame = nullptr;
    DLKInputFormatHandler onFormat = nullptr;
    void *context = nullptr;
    int32_t audioChannels = 2;
    bool formatDetection = false;
    std::atomic<bool> interlaced{false};

    std::atomic<uint32_t> currentMode{0};

    std::atomic<bool> closing{false};

    void reportMode(IDeckLinkDisplayMode *mode) {
        char name[64] = "";
        CFStringRef modeName = nullptr;
        if (mode->GetName(&modeName) == S_OK && modeName != nullptr) {
            CFStringGetCString(modeName, name, (CFIndex)sizeof(name),
                               kCFStringEncodingUTF8);
            CFRelease(modeName);
        }
        BMDTimeValue duration = 0;
        BMDTimeScale scale = 0;
        mode->GetFrameRate(&duration, &scale);
        bool fields = isInterlaced(mode->GetFieldDominance());
        interlaced.store(fields);
        if (onFormat) {
            onFormat(context, name, (int32_t)mode->GetWidth(),
                     (int32_t)mode->GetHeight(), duration, scale, fields);
        }
    }
};

HRESULT DLKInputCallback::VideoInputFormatChanged(
    BMDVideoInputFormatChangedEvents, IDeckLinkDisplayMode *mode,
    BMDDetectedVideoInputFormatFlags) {
    DLKInput *owner = owner_;
    if (!owner || !mode || owner->closing.load()) return S_OK;

    if (!dlk_input_format_needs_restart(
            owner->currentMode.load(), mode->GetDisplayMode()))
        return S_OK;
    owner->currentMode.store(mode->GetDisplayMode());

    owner->input->PauseStreams();
    owner->input->EnableVideoInput(
        mode->GetDisplayMode(), bmdFormat8BitYUV,
        bmdVideoInputEnableFormatDetection);
    owner->input->FlushStreams();
    owner->input->StartStreams();
    owner->reportMode(mode);
    return S_OK;
}

HRESULT DLKInputCallback::VideoInputFrameArrived(
    IDeckLinkVideoInputFrame *video, IDeckLinkAudioInputPacket *audio) {
    DLKInput *owner = owner_;
    if (!owner || owner->closing.load() || !owner->onFrame) return S_OK;
    DLKInputFrame frame = {};
    frame.hostTime = hostSeconds();
    frame.captureHostTime = frame.hostTime;
    frame.interlaced = owner->interlaced.load();

    if (video) {
        BMDTimeValue frameTime = 0;
        BMDTimeValue frameDuration = 0;
        BMDTimeValue hardwareNow = 0;
        BMDTimeValue timeInFrame = 0;
        BMDTimeValue ticksPerFrame = 0;
        if (video->GetHardwareReferenceTimestamp(
                1000000, &frameTime, &frameDuration) == S_OK &&
            owner->input->GetHardwareReferenceClock(
                1000000, &hardwareNow, &timeInFrame, &ticksPerFrame) == S_OK &&
            hardwareNow >= frameTime && hardwareNow - frameTime < 1000000) {
            frame.captureHostTime =
                frame.hostTime - (double)(hardwareNow - frameTime) / 1e6;
        }
    }
    IDeckLinkVideoBuffer *buffer = nullptr;
    bool accessing = false;
    if (video) {
        frame.hasSignal = (video->GetFlags() & bmdFrameHasNoInputSource) == 0;
        frame.width = (int32_t)video->GetWidth();
        frame.height = (int32_t)video->GetHeight();
        frame.rowBytes = (size_t)video->GetRowBytes();

        if (frame.hasSignal && video->GetPixelFormat() == bmdFormat8BitYUV &&
            video->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&buffer) ==
                S_OK &&
            buffer) {
            if (buffer->StartAccess(bmdBufferAccessRead) == S_OK) {
                accessing = true;
                void *bytes = nullptr;
                if (buffer->GetBytes(&bytes) == S_OK) {
                    frame.bytes = (const uint8_t *)bytes;
                }
            }
        }
    }
    if (audio) {
        void *bytes = nullptr;
        if (audio->GetBytes(&bytes) == S_OK && bytes) {
            frame.audio = (const int32_t *)bytes;
            frame.audioFrames = (int32_t)audio->GetSampleFrameCount();
            frame.audioChannels = owner->audioChannels;
        }
    }
    owner->onFrame(owner->context, &frame);
    if (buffer) {
        if (accessing) buffer->EndAccess(bmdBufferAccessRead);
        buffer->Release();
    }
    return S_OK;
}

extern "C" {

DLKInput *dlk_input_open(
    int64_t persistentID, int32_t audioChannels,
    DLKInputFrameHandler onFrame, DLKInputFormatHandler onFormat,
    void *context, char *error, size_t errorLength) {
    COMRef<IDeckLink> device;
    device.pointer = findDevice(persistentID);
    if (!device) {
        writeError(error, errorLength,
                   "DeckLink device not found (unplugged, or Desktop Video "
                   "not installed)");
        return nullptr;
    }
    COMRef<IDeckLinkInput> input;
    if (device->QueryInterface(IID_IDeckLinkInput, (void **)input.out()) !=
            S_OK ||
        !input) {
        writeError(error, errorLength,
                   "device cannot capture (this connector may be mapped as an "
                   "output in Desktop Video Setup)");
        return nullptr;
    }

    COMRef<IDeckLinkProfileAttributes> attributes;
    device->QueryInterface(
        IID_IDeckLinkProfileAttributes, (void **)attributes.out());
    bool formatDetection = false;
    if (attributes) {
        attributes->GetFlag(
            BMDDeckLinkSupportsInputFormatDetection, &formatDetection);
    }

    int64_t audioConnections = 0;
    if (attributes &&
        attributes->GetInt(BMDDeckLinkAudioInputConnections, &audioConnections) ==
            S_OK &&
        (audioConnections & bmdAudioConnectionEmbedded) != 0) {
        COMRef<IDeckLinkConfiguration> configuration;
        if (device->QueryInterface(IID_IDeckLinkConfiguration,
                                   (void **)configuration.out()) == S_OK &&
            configuration) {
            configuration->SetInt(
                bmdDeckLinkConfigAudioInputConnection, bmdAudioConnectionEmbedded);
        }
    }

    BMDDisplayMode startMode = 0;
    {
        bool supported = false;
        BMDDisplayMode actual = 0;
        if (input->DoesSupportVideoMode(
                bmdVideoConnectionUnspecified, bmdModeHD1080p2997,
                bmdFormat8BitYUV, bmdNoVideoInputConversion,
                bmdSupportedVideoModeDefault, &actual, &supported) == S_OK &&
            supported) {
            startMode = bmdModeHD1080p2997;
        }
    }
    if (!startMode) {
        COMRef<IDeckLinkDisplayModeIterator> modes;
        if (input->GetDisplayModeIterator(modes.out()) == S_OK && modes) {
            IDeckLinkDisplayMode *candidate = nullptr;
            while (!startMode && modes->Next(&candidate) == S_OK) {
                COMRef<IDeckLinkDisplayMode> candidateRef;
                candidateRef.pointer = candidate;
                bool supported = false;
                BMDDisplayMode actual = 0;
                if (input->DoesSupportVideoMode(
                        bmdVideoConnectionUnspecified,
                        candidateRef->GetDisplayMode(), bmdFormat8BitYUV,
                        bmdNoVideoInputConversion, bmdSupportedVideoModeDefault,
                        &actual, &supported) == S_OK &&
                    supported) {
                    startMode = candidateRef->GetDisplayMode();
                }
            }
        }
    }
    if (!startMode) {
        writeError(error, errorLength, "no capture modes on this device");
        return nullptr;
    }

    if (input->EnableVideoInput(
            startMode, bmdFormat8BitYUV,
            formatDetection ? bmdVideoInputEnableFormatDetection
                            : bmdVideoInputFlagDefault) != S_OK) {
        writeError(error, errorLength,
                   "video input enable failed (input may be in use by another "
                   "app)");
        return nullptr;
    }
    if (input->EnableAudioInput(
            bmdAudioSampleRate48kHz, bmdAudioSampleType32bitInteger,
            (uint32_t)audioChannels) != S_OK) {
        input->DisableVideoInput();
        writeError(error, errorLength, "audio input enable failed");
        return nullptr;
    }

    DLKInput *handle = new DLKInput();
    handle->onFrame = onFrame;
    handle->onFormat = onFormat;
    handle->context = context;
    handle->audioChannels = audioChannels;
    handle->formatDetection = formatDetection;
    handle->input = input.pointer;
    handle->currentMode.store(startMode);
    {
        COMRef<IDeckLinkDisplayMode> mode;
        if (input->GetDisplayMode(startMode, mode.out()) == S_OK && mode) {
            handle->reportMode(mode.pointer);
        }
    }
    handle->callback = new DLKInputCallback(handle);
    input->SetCallback(handle->callback);
    if (input->StartStreams() != S_OK) {
        input->SetCallback(nullptr);
        input->DisableAudioInput();
        input->DisableVideoInput();
        handle->callback->Release();
        delete handle;
        writeError(error, errorLength,
                   "capture failed to start (input may be in use by another "
                   "app)");
        return nullptr;
    }
    handle->device = device.take();
    handle->input = input.take();
    return handle;
}

void dlk_input_close(DLKInput *input) {
    if (!input) return;
    input->closing.store(true);
    input->input->StopStreams();
    input->input->SetCallback(nullptr);
    input->input->DisableAudioInput();
    input->input->DisableVideoInput();
    input->callback->Release();
    input->input->Release();
    input->device->Release();
    delete input;
}

bool dlk_input_format_needs_restart(uint32_t currentMode, uint32_t detectedMode) {
    return detectedMode != 0 && detectedMode != currentMode;
}

void dlk_deinterlace_blend(
    const uint8_t *source, size_t sourceRowBytes,
    uint8_t *destination, size_t destinationRowBytes,
    size_t rowLength, int32_t height) {
    if (!source || !destination || height <= 0) return;
    for (int32_t row = 0; row + 1 < height; row += 1) {
        const uint8_t *upper = source + (size_t)row * sourceRowBytes;
        const uint8_t *lower = upper + sourceRowBytes;
        uint8_t *out = destination + (size_t)row * destinationRowBytes;
        for (size_t index = 0; index < rowLength; index += 1) {
            out[index] = (uint8_t)((upper[index] + lower[index] + 1) >> 1);
        }
    }
    memcpy(destination + (size_t)(height - 1) * destinationRowBytes,
           source + (size_t)(height - 1) * sourceRowBytes, rowLength);
}

}
