#include "presenter/native/native_presenter.h"

#include <string_view>
#include <type_traits>

#include <gtest/gtest.h>

#include "presenter/native/gallery3_drm_backend.h"
#include "presenter/native/native_display_backend.h"
#include "presenter/native/scanout_transport.h"
#include "presenter/native/waveform_program.h"

static_assert(std::is_abstract_v<pluto::native::NativeDisplayBackend>);
static_assert(std::is_abstract_v<pluto::native::WaveformProgram>);
static_assert(std::is_abstract_v<pluto::native::ScanoutTransport>);

TEST(NativePresenter, RegistryExposesOnlyTheProductPresenterName) {
  EXPECT_EQ(pluto_presenter_by_name("native"), pluto_native_presenter_ops());
  EXPECT_EQ(pluto_presenter_by_name("swtcon"), nullptr);
  ASSERT_NE(pluto_gallery3_drm_presenter_ops(), nullptr);
  EXPECT_EQ(std::string_view(pluto_gallery3_drm_presenter_ops()->name),
            "gallery3_drm");
  EXPECT_EQ(std::string_view(pluto_native_presenter_ops()->name), "native");
}

TEST(NativePresenter, AdmitsOnlyAcceptedImplementedProfiles) {
  const pluto::GeneratedDeviceProfile *rm1 =
      pluto::generated_device_profile_by_id("rm1");
  const pluto::GeneratedDeviceProfile *rm2 =
      pluto::generated_device_profile_by_id("rm2");
  const pluto::GeneratedDeviceProfile *move =
      pluto::generated_device_profile_by_id("move");
  ASSERT_NE(rm1, nullptr);
  ASSERT_NE(rm2, nullptr);
  ASSERT_NE(move, nullptr);

  EXPECT_FALSE(pluto::native::native_display_backend_is_implemented(*rm1));
  EXPECT_FALSE(pluto::native::native_display_backend_is_implemented(*rm2));
  EXPECT_TRUE(pluto::native::native_display_backend_is_implemented(*move));

  PlutoStatus status = kPlutoStatusOk;
  EXPECT_EQ(pluto::native::make_native_display_backend(*rm1, &status), nullptr);
  EXPECT_EQ(status, kPlutoStatusUnsupported);
  EXPECT_EQ(pluto::native::make_native_display_backend(*rm2, &status), nullptr);
  EXPECT_EQ(status, kPlutoStatusUnsupported);
  EXPECT_NE(pluto::native::make_native_display_backend(*move, &status),
            nullptr);
  EXPECT_EQ(status, kPlutoStatusOk);

  pluto::GeneratedDeviceProfile disabled_move = *move;
  disabled_move.runtime.native_session_enabled = false;
  EXPECT_FALSE(
      pluto::native::native_display_backend_is_implemented(disabled_move));
  EXPECT_EQ(pluto::native::make_native_display_backend(disabled_move, &status),
            nullptr);
  EXPECT_EQ(status, kPlutoStatusUnsupported);

  EXPECT_FALSE(pluto::native::native_display_backend_is_implemented(*rm1));
  pluto::GeneratedDeviceProfile accepted_rm1 = *rm1;
  accepted_rm1.runtime.native_session_enabled = true;
  EXPECT_TRUE(
      pluto::native::native_display_backend_is_implemented(accepted_rm1));
  auto rm1_backend =
      pluto::native::make_native_display_backend(accepted_rm1, &status);
  ASSERT_NE(rm1_backend, nullptr);
  EXPECT_EQ(status, kPlutoStatusOk);
  EXPECT_EQ(rm1_backend->driver_name(), "mxcfb_epdc");
}

TEST(NativePresenter, RejectsAttemptsToSpoofAnInternalDriverName) {
  PlutoPresenterConfig config{};
  config.struct_size = sizeof(config);
  config.backend_name = "gallery3_drm";
  PlutoPresenter *presenter = nullptr;
  EXPECT_EQ(pluto_native_presenter_ops()->open(&config, &presenter),
            kPlutoStatusInvalidArgument);
  EXPECT_EQ(presenter, nullptr);
}
