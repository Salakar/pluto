#include "compositor/backing_store_pool.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace pluto {
namespace {

size_t align_up(size_t value, size_t alignment) {
  return (value + alignment - 1u) & ~(alignment - 1u);
}

}  // namespace

size_t bytes_per_pixel(PlutoPixelFormat format) {
  switch (format) {
    case kPlutoPixelFormatGray8:
      return 1;
    case kPlutoPixelFormatXrgb8888:
      return 4;
    case kPlutoPixelFormatRgb565:
      return 2;
  }
  return 2;
}

FlutterSoftwarePixelFormat to_flutter_pixel_format(PlutoPixelFormat format) {
  switch (format) {
    case kPlutoPixelFormatGray8:
      return kFlutterSoftwarePixelFormatGray8;
    case kPlutoPixelFormatXrgb8888:
      return kFlutterSoftwarePixelFormatRGBX8888;
    case kPlutoPixelFormatRgb565:
      return kFlutterSoftwarePixelFormatRGB565;
  }
  return kFlutterSoftwarePixelFormatRGB565;
}

BackingStorePool::BackingStorePool(size_t cap, PlutoPixelFormat format)
    : cap_(cap), format_(format) {}

BackingStorePool::~BackingStorePool() {
  for (const std::unique_ptr<Slot>& slot : slots_) {
    std::free(slot->allocation);
  }
}

BackingStorePool::Slot* BackingStorePool::find_slot(uint32_t width,
                                                    uint32_t height,
                                                    size_t row_bytes) {
  for (const std::unique_ptr<Slot>& slot : slots_) {
    if (!slot->in_use && slot->width == width && slot->height == height &&
        slot->row_bytes == row_bytes && slot->format == format_) {
      return slot.get();
    }
  }
  return nullptr;
}

BackingStorePool::Slot* BackingStorePool::allocate_slot(uint32_t width,
                                                        uint32_t height,
                                                        size_t row_bytes) {
  if (slots_.size() >= cap_) {
    return nullptr;
  }
  auto slot = std::make_unique<Slot>();
  slot->width = width;
  slot->height = height;
  slot->row_bytes = row_bytes;
  slot->format = format_;
  slot->allocation_size = row_bytes * height;
  void* allocation = nullptr;
  if (posix_memalign(&allocation, 64, slot->allocation_size) != 0 ||
      allocation == nullptr) {
    return nullptr;
  }
  std::memset(allocation, 0, slot->allocation_size);
  slot->allocation = allocation;
  Slot* raw = slot.get();
  slots_.push_back(std::move(slot));
  return raw;
}

bool BackingStorePool::create(const FlutterBackingStoreConfig* config,
                              FlutterBackingStore* backing_store_out) {
  if (config == nullptr || backing_store_out == nullptr ||
      config->struct_size < sizeof(FlutterBackingStoreConfig)) {
    return false;
  }
  const auto width = static_cast<uint32_t>(std::ceil(config->size.width));
  const auto height = static_cast<uint32_t>(std::ceil(config->size.height));
  if (width == 0 || height == 0) {
    return false;
  }
  const size_t row_bytes = align_up(static_cast<size_t>(width) *
                                        bytes_per_pixel(format_),
                                    64);
  Slot* slot = find_slot(width, height, row_bytes);
  if (slot == nullptr) {
    slot = allocate_slot(width, height, row_bytes);
  }
  if (slot == nullptr) {
    return false;
  }
  slot->in_use = true;

  FlutterBackingStore store{};
  store.struct_size = sizeof(store);
  store.user_data = slot;
  store.type = kFlutterBackingStoreTypeSoftware2;
  store.did_update = false;
  store.software2.struct_size = sizeof(FlutterSoftwareBackingStore2);
  store.software2.allocation = slot->allocation;
  store.software2.row_bytes = slot->row_bytes;
  store.software2.height = slot->height;
  store.software2.user_data = slot;
  store.software2.destruction_callback = destruction_callback;
  store.software2.pixel_format = to_flutter_pixel_format(format_);
  *backing_store_out = store;
  return true;
}

bool BackingStorePool::collect(const FlutterBackingStore* backing_store) {
  if (backing_store == nullptr || backing_store->user_data == nullptr) {
    return false;
  }
  auto* slot = static_cast<Slot*>(backing_store->user_data);
  slot->in_use = false;
  return true;
}

size_t BackingStorePool::active_count() const {
  size_t count = 0;
  for (const std::unique_ptr<Slot>& slot : slots_) {
    if (slot->in_use) {
      ++count;
    }
  }
  return count;
}

void BackingStorePool::destruction_callback(void* user_data) {
  if (user_data != nullptr) {
    static_cast<Slot*>(user_data)->in_use = false;
  }
}

}  // namespace pluto
