#include "presenter/swtcon/drm_swtcon_device.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

class FakeDrm final : public pluto::swtcon::DrmInterface {
public:
  int open_card(const std::string &, std::string *) override { return 7; }
  void close_fd(int fd) override { closed_fd = fd; }
  bool set_client_cap(int, std::uint64_t capability, std::uint64_t value,
                      std::string *) override {
    caps.push_back({capability, value});
    return true;
  }
  bool get_cap(int, std::uint64_t capability, std::uint64_t *value,
               std::string *) override {
    *value = capability == 1 || capability == 0x12 ? 1 : 0;
    return true;
  }
  bool get_resources(int, pluto::swtcon::DrmResources *out,
                     std::string *) override {
    out->crtcs = {20};
    out->connectors = {10};
    return true;
  }
  bool get_connector(int, std::uint32_t connector_id,
                     pluto::swtcon::DrmConnectorInfo *out,
                     std::string *) override {
    out->connector_id = connector_id;
    out->encoder_id = 30;
    out->connected = true;
    pluto::swtcon::DrmModeInfo mode{};
    mode.hdisplay = bad_mode ? 400 : pluto::swtcon::kDrmWidth;
    mode.vdisplay = pluto::swtcon::kDrmHeight;
    std::strncpy(mode.name, "swtcon-test", sizeof(mode.name) - 1);
    out->modes = {mode};
    out->properties = {{55, "DPMS", 0}};
    out->encoders = {30};
    return true;
  }
  bool get_encoder(int, std::uint32_t encoder_id,
                   pluto::swtcon::DrmEncoderInfo *out,
                   std::string *) override {
    out->encoder_id = encoder_id;
    out->crtc_id = 20;
    out->possible_crtcs = 1;
    return true;
  }
  bool get_plane_ids(int, std::vector<std::uint32_t> *out,
                     std::string *) override {
    *out = {40};
    return true;
  }
  bool get_plane(int, std::uint32_t plane_id,
                 pluto::swtcon::DrmPlaneInfo *out, std::string *) override {
    out->plane_id = plane_id;
    out->possible_crtcs = 1;
    out->properties = {{60, "type", 1},   {61, "FB_ID", 0},  {62, "CRTC_ID", 0},
                       {63, "CRTC_X", 0}, {64, "CRTC_Y", 0}, {65, "CRTC_W", 0},
                       {66, "CRTC_H", 0}, {67, "SRC_X", 0},  {68, "SRC_Y", 0},
                       {69, "SRC_W", 0},  {70, "SRC_H", 0}};
    return true;
  }
  bool create_dumb(int, std::uint32_t, std::uint32_t, std::uint32_t,
                   pluto::swtcon::DrmDumbCreateResult *out,
                   std::string *) override {
    ++created;
    out->handle = 1000 + created;
    out->pitch = pluto::swtcon::kDrmWidth * sizeof(std::uint16_t);
    out->size = pluto::swtcon::kDrmPhaseBytes;
    return true;
  }
  bool add_fb(int, std::uint32_t, std::uint32_t, std::uint8_t, std::uint8_t,
              std::uint32_t, std::uint32_t, std::uint32_t *fb_id,
              std::string *) override {
    *fb_id = 2000 + created;
    return true;
  }
  bool map_dumb(int, std::uint32_t handle, std::uint64_t *offset,
                std::string *) override {
    *offset = handle * 4096ULL;
    return true;
  }
  void *mmap_dumb(int, std::uint64_t, std::uint64_t size,
                  std::string *) override {
    maps.push_back(
        std::make_unique<std::uint8_t[]>(static_cast<std::size_t>(size)));
    return maps.back().get();
  }
  void munmap_dumb(void *, std::uint64_t) override { ++unmapped; }
  bool rm_fb(int, std::uint32_t, std::string *) override {
    ++removed_fbs;
    return true;
  }
  bool destroy_dumb(int, std::uint32_t, std::string *) override {
    ++destroyed;
    return true;
  }
  bool set_crtc(int, std::uint32_t crtc_id, std::uint32_t fb_id,
                std::uint32_t connector_id,
                const pluto::swtcon::DrmModeInfo &mode,
                std::string *) override {
    set_crtc_crtcs.push_back(crtc_id);
    set_crtc_fbs.push_back(fb_id);
    set_crtc_connectors.push_back(connector_id);
    set_crtc_modes.push_back(mode);
    return true;
  }
  bool blank_crtc(int, std::uint32_t crtc_id, std::string *) override {
    blank_crtcs.push_back(crtc_id);
    return true;
  }
  bool set_connector_property(int, std::uint32_t connector_id,
                              std::uint32_t property_id, std::uint64_t value,
                              std::string *) override {
    connector_properties.push_back({connector_id, property_id, value});
    return true;
  }
  bool atomic_commit(int, const pluto::swtcon::DrmAtomicRequest &request,
                     std::string *) override {
    atomic_requests.push_back(request);
    return true;
  }

  struct ConnectorPropertySet {
    std::uint32_t connector_id = 0;
    std::uint32_t property_id = 0;
    std::uint64_t value = 0;
  };

  bool bad_mode = false;
  int closed_fd = -1;
  int created = 0;
  int unmapped = 0;
  int removed_fbs = 0;
  int destroyed = 0;
  std::vector<std::pair<std::uint64_t, std::uint64_t>> caps;
  std::vector<std::unique_ptr<std::uint8_t[]>> maps;
  std::vector<std::uint32_t> set_crtc_crtcs;
  std::vector<std::uint32_t> set_crtc_fbs;
  std::vector<std::uint32_t> set_crtc_connectors;
  std::vector<pluto::swtcon::DrmModeInfo> set_crtc_modes;
  std::vector<std::uint32_t> blank_crtcs;
  std::vector<ConnectorPropertySet> connector_properties;
  std::vector<pluto::swtcon::DrmAtomicRequest> atomic_requests;
};

} // namespace

TEST(SwtconDrmDeviceTest, DiscoversPipeAndCreatesSixteenMappedBuffers) {
  auto fake = std::make_unique<FakeDrm>();
  FakeDrm *raw = fake.get();
  pluto::swtcon::DrmSwtconDevice device(std::move(fake));

  pluto::swtcon::DrmSwtconDevice::Config config;
  ASSERT_EQ(device.open(config), kPlutoStatusOk);

  EXPECT_EQ(raw->caps.size(), static_cast<std::size_t>(2));
  EXPECT_EQ(raw->created, pluto::swtcon::kDrmBufferCount);
  EXPECT_EQ(device.connector_id(), 10u);
  EXPECT_EQ(device.crtc_id(), 20u);
  EXPECT_EQ(device.plane_id(), 40u);
  EXPECT_EQ(device.dpms_property_id(), 55u);
  EXPECT_EQ(device.fb_id_property_id(), 61u);
  EXPECT_TRUE(device.plane_property_ids().complete());
  EXPECT_EQ(device.buffers().size(),
            static_cast<std::size_t>(pluto::swtcon::kDrmBufferCount));

  std::vector<std::uint16_t> phase(pluto::swtcon::kDrmPhaseWords, 0x1234);
  EXPECT_EQ(device.copy_phase_to_buffer(0, phase.data()), kPlutoStatusOk);
  EXPECT_EQ(device.set_crtc(14), kPlutoStatusOk);
  ASSERT_EQ(raw->set_crtc_fbs.size(), static_cast<std::size_t>(1));
  EXPECT_EQ(raw->set_crtc_fbs[0], 2015u);
  EXPECT_EQ(raw->set_crtc_connectors[0], 10u);

  EXPECT_EQ(device.blank(), kPlutoStatusOk);
  ASSERT_EQ(raw->blank_crtcs.size(), static_cast<std::size_t>(1));
  EXPECT_EQ(raw->blank_crtcs[0], 20u);

  device.close();
  EXPECT_EQ(raw->unmapped, pluto::swtcon::kDrmBufferCount);
  EXPECT_EQ(raw->removed_fbs, pluto::swtcon::kDrmBufferCount);
  EXPECT_EQ(raw->destroyed, pluto::swtcon::kDrmBufferCount);
  EXPECT_EQ(raw->closed_fd, 7);
}

TEST(SwtconDrmDeviceTest, SetsDpmsAndBuildsAtomicPrimaryPlaneFlip) {
  auto fake = std::make_unique<FakeDrm>();
  FakeDrm *raw = fake.get();
  pluto::swtcon::DrmSwtconDevice device(std::move(fake));

  pluto::swtcon::DrmSwtconDevice::Config config;
  ASSERT_EQ(device.open(config), kPlutoStatusOk);

  EXPECT_EQ(device.set_dpms_on(), kPlutoStatusOk);
  ASSERT_EQ(raw->connector_properties.size(), static_cast<std::size_t>(1));
  EXPECT_EQ(raw->connector_properties[0].connector_id, 10u);
  EXPECT_EQ(raw->connector_properties[0].property_id, 55u);
  EXPECT_EQ(raw->connector_properties[0].value, 0u);

  EXPECT_EQ(device.atomic_flip(14), kPlutoStatusOk);
  ASSERT_EQ(raw->atomic_requests.size(), static_cast<std::size_t>(1));
  const pluto::swtcon::DrmAtomicRequest &request = raw->atomic_requests[0];
  EXPECT_EQ(request.flags, 0u);
  ASSERT_EQ(request.objects.size(), static_cast<std::size_t>(1));
  EXPECT_EQ(request.objects[0], 40u);
  ASSERT_EQ(request.property_counts.size(), static_cast<std::size_t>(1));
  EXPECT_EQ(request.property_counts[0], 10u);

  const std::vector<std::uint32_t> expected_properties = {62, 63, 64, 65, 66,
                                                          67, 68, 69, 70, 61};
  ASSERT_EQ(request.properties.size(), expected_properties.size());
  for (std::size_t i = 0; i < expected_properties.size(); ++i) {
    EXPECT_EQ(request.properties[i], expected_properties[i]);
  }

  const std::vector<std::uint64_t> expected_values = {
      20,
      0,
      0,
      pluto::swtcon::kDrmWidth,
      pluto::swtcon::kDrmHeight,
      0,
      0,
      static_cast<std::uint64_t>(pluto::swtcon::kDrmWidth) << 16,
      static_cast<std::uint64_t>(pluto::swtcon::kDrmHeight) << 16,
      2015};
  ASSERT_EQ(request.values.size(), expected_values.size());
  for (std::size_t i = 0; i < expected_values.size(); ++i) {
    EXPECT_EQ(request.values[i], expected_values[i]);
  }
}

TEST(SwtconDrmDeviceTest, RejectsNonSwtconModeSize) {
  auto fake = std::make_unique<FakeDrm>();
  fake->bad_mode = true;
  FakeDrm *raw = fake.get();
  pluto::swtcon::DrmSwtconDevice device(std::move(fake));

  pluto::swtcon::DrmSwtconDevice::Config config;
  EXPECT_EQ(device.open(config), kPlutoStatusDeviceLost);
  EXPECT_TRUE(device.last_error().find("size mismatch") != std::string::npos);
  EXPECT_EQ(raw->created, 0);
}
