#include "vlc_video_output.h"

#include <algorithm>
#include <cstdint>
#include <cstring>

namespace vlc_player {
namespace {

// A bin for pictures nobody will ever look at.
//
// libVLC 3's lock callback cannot refuse a picture: vmem writes back whatever
// the callback leaves in `planes`, so a lock that declines by returning
// nullptr without touching them hands the decoder uninitialised stack
// addresses to memcpy a frame into. Every refusal therefore has to point at
// real memory, and one process-wide buffer is enough - nothing reads it, so
// simultaneous writers cannot bother each other.
//
// It only grows, and a block that has been outgrown is deliberately not
// freed: a video thread may still be writing into it, and the handful of
// bytes that costs is the price of never having to prove otherwise.
uint8_t* ScratchBin(size_t bytes) {
  static std::mutex mutex;
  static uint8_t* buffer = nullptr;
  static size_t capacity = 0;

  std::lock_guard<std::mutex> lock(mutex);
  if (bytes > capacity) {
    buffer = new uint8_t[bytes]();
    capacity = bytes;
  }
  return buffer;
}

}  // namespace

VlcVideoOutput::VlcVideoOutput(libvlc_media_player_t* player,
                               VlcFrameSink* sink)
    : player_(player), attachment_(new Attachment()) {
  if (player_ == nullptr || sink == nullptr) {
    return;
  }
  attachment_->sink = sink;
  libvlc_video_set_callbacks(player_, &VlcVideoOutput::LockCallback,
                             &VlcVideoOutput::UnlockCallback,
                             &VlcVideoOutput::DisplayCallback, attachment_);
  libvlc_video_set_format_callbacks(player_, &VlcVideoOutput::SetupCallback,
                                    &VlcVideoOutput::CleanupCallback);
}

VlcVideoOutput::~VlcVideoOutput() {
  Detach();
  // attachment_ is deliberately not deleted. See the note on Attachment.
}

void VlcVideoOutput::Detach() {
  {
    std::lock_guard<std::mutex> lock(attachment_->mutex);
    if (attachment_->sink == nullptr) {
      return;
    }
    attachment_->sink = nullptr;
  }
  libvlc_video_set_callbacks(player_, nullptr, nullptr, nullptr, nullptr);
  libvlc_video_set_format_callbacks(player_, nullptr, nullptr);
}

void VlcVideoOutput::PointAtScratch(const Attachment& attachment,
                                    void** planes) {
  size_t total = 0;
  for (uint32_t i = 0; i < attachment.plane_count; ++i) {
    total += static_cast<size_t>(attachment.pitches[i]) * attachment.lines[i];
  }
  if (total == 0) {
    return;
  }

  uint8_t* bin = ScratchBin(total);
  size_t offset = 0;
  for (uint32_t i = 0; i < attachment.plane_count; ++i) {
    planes[i] = bin + offset;
    offset += static_cast<size_t>(attachment.pitches[i]) * attachment.lines[i];
  }
}

unsigned VlcVideoOutput::SetupCallback(void** opaque,
                                       char* chroma,
                                       unsigned* width,
                                       unsigned* height,
                                       unsigned* pitches,
                                       unsigned* lines) {
  auto* attachment = static_cast<Attachment*>(*opaque);
  std::lock_guard<std::mutex> lock(attachment->mutex);
  if (attachment->sink == nullptr) {
    return 0;
  }

  VlcFrameFormat format;
  // libVLC passes the source chroma in and expects the answer in the same
  // four bytes; it is not NUL-terminated on the way in.
  std::memcpy(format.chroma, chroma, 4);
  format.chroma[4] = '\0';
  format.width = *width;
  format.height = *height;

  const uint32_t planes = attachment->sink->Configure(&format);
  if (planes == 0) {
    return 0;
  }

  std::memcpy(chroma, format.chroma, 4);
  *width = format.width;
  *height = format.height;
  const uint32_t used = std::min<uint32_t>(planes, kVlcMaxPlanes);
  attachment->plane_count = used;
  for (uint32_t i = 0; i < used; ++i) {
    pitches[i] = format.pitches[i];
    lines[i] = format.lines[i];
    attachment->pitches[i] = format.pitches[i];
    attachment->lines[i] = format.lines[i];
  }
  return used;
}

void VlcVideoOutput::CleanupCallback(void* opaque) {
  auto* attachment = static_cast<Attachment*>(opaque);
  std::lock_guard<std::mutex> lock(attachment->mutex);
  if (attachment->sink != nullptr) {
    attachment->sink->Cleanup();
  }
}

void* VlcVideoOutput::LockCallback(void* opaque, void** planes) {
  auto* attachment = static_cast<Attachment*>(opaque);
  std::lock_guard<std::mutex> lock(attachment->mutex);
  void* picture =
      attachment->sink == nullptr ? nullptr : attachment->sink->Acquire(planes);
  if (picture == nullptr) {
    // Detached, or the sink had no buffer to spare. Either way libVLC is
    // about to write a frame, so it needs somewhere to write it.
    PointAtScratch(*attachment, planes);
  }
  return picture;
}

void VlcVideoOutput::UnlockCallback(void* opaque,
                                    void* picture,
                                    void* const* planes) {
  auto* attachment = static_cast<Attachment*>(opaque);
  std::lock_guard<std::mutex> lock(attachment->mutex);
  if (attachment->sink != nullptr) {
    attachment->sink->Release(picture, planes);
  }
}

void VlcVideoOutput::DisplayCallback(void* opaque, void* picture) {
  auto* attachment = static_cast<Attachment*>(opaque);
  std::lock_guard<std::mutex> lock(attachment->mutex);
  if (attachment->sink != nullptr) {
    attachment->sink->Commit(picture);
  }
}

}  // namespace vlc_player
