#include "decklink_shim.h"

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
            attributes->GetInt(BMDDeckLinkVideoIOSupport, &ioSupport) == S_OK)
            info.supportsPlayback = (ioSupport & bmdDeviceSupportsPlayback) != 0;
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
        if (haveHardwareTime &&
            output->streamTime < hardwareTime + output->frameDuration) {
            output->streamTime = hardwareTime + 2 * output->frameDuration;
        }
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
    (void)result;
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
    return true;
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
