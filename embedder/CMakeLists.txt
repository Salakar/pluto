cmake_minimum_required(VERSION 3.27)

project(
  pluto_embedder
  VERSION 0.1.0
  LANGUAGES C CXX
)

option(PLUTO_BUILD_TESTS "Build Pluto native tests" ON)
option(PLUTO_FETCH_GTEST "Fetch GoogleTest when it is not installed" OFF)
option(PLUTO_BUILD_SWTCON_PROBE "Build standalone SWTCON probe" OFF)

find_package(Threads REQUIRED)

add_library(pluto_abi STATIC src/abi.cc)
target_include_directories(
  pluto_abi
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_compile_features(pluto_abi PUBLIC cxx_std_20)

add_library(
  pluto_renderer
  STATIC
    src/renderer/abi_bridge.cc
    src/renderer/auto_ghostbuster.cc
    src/renderer/classify_ladder.cc
    src/renderer/convert.cc
    src/renderer/frame_ledger.cc
    src/renderer/gallery3.cc
    src/renderer/guard_band.cc
    src/renderer/kernels_neon.cc
    src/renderer/kernels_scalar.cc
    src/renderer/ledgers.cc
    src/renderer/perception.cc
    src/renderer/pen_render_policy.cc
    src/renderer/quantize.cc
    src/renderer/region_scheduler.cc
    src/renderer/renderer_handoff.cc
    src/renderer/scroll_detect.cc
    src/renderer/settle_policy.cc
    src/renderer/tile_pass.cc
)
target_include_directories(
  pluto_renderer
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_link_libraries(pluto_renderer PUBLIC pluto_abi)
target_compile_features(pluto_renderer PUBLIC cxx_std_20)

add_library(
  pluto_input
  STATIC
    src/input/calibrate.cc
    src/input/evdev.cc
    src/input/ink_thread.cc
    src/input/pen.cc
    src/input/pen_ring.cc
    src/input/record.cc
    src/input/touch.cc
    src/input/transform.cc
)
target_include_directories(
  pluto_input
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)
# Input publishes events and trajectory hints only; it does not depend on the
# renderer or own pixels.
target_link_libraries(pluto_input PUBLIC Threads::Threads)
target_compile_features(pluto_input PUBLIC cxx_std_20)

add_library(
  pluto_embedder_core
  STATIC
    src/channels/channel_registry.cc
    src/channels/event_channel.cc
    src/channels/json_codec.cc
    src/channels/pen_channels.cc
    src/channels/pluto_channels.cc
    src/channels/sensor_channels.cc
    src/channels/service_channels.cc
    src/channels/standard_codec.cc
    src/channels/system_channels.cc
    src/channels/wpa_supplicant_client.cc
    src/compositor/backing_store_pool.cc
    src/compositor/software_compositor.cc
    src/engine/device_identity.cc
    src/engine/engine_host.cc
    src/engine/engine_loader.cc
    src/engine/qtfb_input_bridge.cc
    src/ffi/dart_dl.cc
    src/glass_handoff.cc
    src/presenter/host_preview.cc
    src/presenter/native/mxcfb/mxcfb_backend.cc
    src/presenter/native/mxcfb/mxcfb_device.cc
    src/presenter/native/native_presenter.cc
    src/presenter/native/rm2/wbf_decoder.cc
    src/presenter/png_encoder.cc
    src/presenter/qtfb/qtfb_client.cc
    src/presenter/qtfb/qtfb_presenter.cc
    src/presenter/registry.cc
    src/presenter/swtcon/admission_mailbox.cc
    src/presenter/swtcon/ct33_frontend.cc
    src/presenter/swtcon/dc_ledger.cc
    src/presenter/swtcon/drm_swtcon_device.cc
    src/presenter/swtcon/drm_swtcon_presenter.cc
    src/presenter/swtcon/fast_rail_admit_kernels_neon.cc
    src/presenter/swtcon/fast_rail_admit_kernels_scalar.cc
    src/presenter/swtcon/hygiene_fsm.cc
    src/presenter/swtcon/lut_cache.cc
    src/presenter/swtcon/mapped_sweep.cc
    src/presenter/swtcon/phase_emit.cc
    src/presenter/swtcon/pixel_engine.cc
    src/presenter/swtcon/scan_loop.cc
    src/presenter/swtcon/sweep_kernels_neon.cc
    src/presenter/swtcon/sweep_kernels_scalar.cc
    src/presenter/swtcon/swtcon_rails.cc
    src/presenter/swtcon/swtcon_temperature.cc
    src/presenter/swtcon/swtcon_waveform.cc
    src/presenter/swtcon/xochitl_delta_table.cc
    src/presenter/swtcon/xochitl_color_pipeline.cc
    src/presenter/swtcon/xochitl_history_state.cc
    src/presenter/swtcon/xochitl_selector16.cc
    src/runtime/direct_control_server.cc
    src/runtime/event_loop.cc
    src/runtime/lifecycle.cc
    src/runtime/sha256.cc
    src/runtime/vsync_pacer.cc
    src/sensors/iio.cc
    third_party/dart/dart_api_dl.c
)
set_source_files_properties(
  src/presenter/host_preview.cc
  PROPERTIES
    COMPILE_DEFINITIONS
      "pluto_presenter_by_name=pluto_host_preview_presenter_by_name_legacy;pluto_presenter_probe=pluto_host_preview_presenter_probe_legacy"
)
target_include_directories(
  pluto_embedder_core
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party
)
target_link_libraries(
  pluto_embedder_core
  PUBLIC
    pluto_abi
    pluto_renderer
    pluto_input
    Threads::Threads
    ${CMAKE_DL_LIBS}
)
target_compile_features(pluto_embedder_core PUBLIC cxx_std_20)

add_executable(pluto-embedder src/main.cc)
target_link_libraries(pluto-embedder PRIVATE pluto_embedder_core)
target_compile_features(pluto-embedder PRIVATE cxx_std_20)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_link_options(pluto-embedder PRIVATE -Wl,--export-dynamic-symbol=pluto_*)
endif()

if(NOT CMAKE_CROSSCOMPILING)
  add_executable(pluto_wbf_inspect tools/wbf_inspect.cc)
  target_link_libraries(pluto_wbf_inspect PRIVATE pluto_embedder_core)
  target_compile_features(pluto_wbf_inspect PRIVATE cxx_std_20)
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(pluto_wbf_inspect PRIVATE -Wall -Wextra -Wpedantic)
  endif()
endif()

add_executable(pluto_renderer_bench bench/renderer/simple_bench.cc)
target_link_libraries(pluto_renderer_bench PRIVATE pluto_renderer)
target_compile_features(pluto_renderer_bench PRIVATE cxx_std_20)

# Presenter engine bench: scalar-vs-NEON A/B of the fused advance+emit
# sweep (full-field and ~500k active sets) against the 11.76 ms scan budget.
add_executable(pluto_presenter_bench bench/presenter/engine_bench.cc)
target_link_libraries(pluto_presenter_bench PRIVATE pluto_embedder_core)
target_include_directories(pluto_presenter_bench PRIVATE test/presenter)
target_compile_features(pluto_presenter_bench PRIVATE cxx_std_20)

# Full Paper Pro Move warm-handoff bundle benchmark. This intentionally uses
# the production serializer (including checksums, fsync, and atomic rename)
# and reports process RSS alongside save/load latency.
add_executable(
  glass_handoff_bench
  bench/presenter/glass_handoff_bench.cc
)
target_link_libraries(glass_handoff_bench PRIVATE pluto_embedder_core)
target_compile_features(glass_handoff_bench PRIVATE cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(glass_handoff_bench PRIVATE -Wall -Wextra -Wpedantic)
endif()

# Focused ct33 RGB565 locality benchmark. Unlike the aggregate presenter
# benchmark this reports the first call and keeps random/palette cases separate
# so cache-layout changes cannot hide regressions behind warmup samples.
add_executable(
  ct33_frontend_bench
  bench/presenter/ct33_frontend_bench.cc
)
target_link_libraries(ct33_frontend_bench PRIVATE pluto_embedder_core)
target_compile_features(ct33_frontend_bench PRIVATE cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(ct33_frontend_bench PRIVATE -Wall -Wextra -Wpedantic)
endif()

# Standalone mapped source->drive sweep: full-panel one-phase host guardrail
# against the 11.764 ms (85 Hz) device scan period.  The benchmark compares
# the scalar reference with the architecture dispatch without integrating the
# still-gated Xochitl history/selector path into the live presenter.
add_executable(
  xochitl_mapped_sweep_bench
  bench/presenter/mapped_sweep_bench.cc
)
target_link_libraries(xochitl_mapped_sweep_bench PRIVATE pluto_embedder_core)
target_compile_features(xochitl_mapped_sweep_bench PRIVATE cxx_std_20)

# Transactional Xochitl A/B preparation/commit integration baseline.
add_executable(
  xochitl_history_state_bench
  bench/presenter/xochitl_history_state_bench.cc
)
target_include_directories(
  xochitl_history_state_bench PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_link_libraries(xochitl_history_state_bench PRIVATE pluto_embedder_core)
target_compile_features(xochitl_history_state_bench PRIVATE cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(
    xochitl_history_state_bench PRIVATE -Wall -Wextra -Wpedantic
  )
endif()

# Installed-data end-to-end colour CPU benchmark: RGB565 selector/ct33,
# transactional history mapping, mapped admission, first/steady DRM plane
# builds, and scan-confirm-style commit timing. It reports 85 Hz misses rather
# than inferring end-to-end latency from component-only sweep numbers.
add_executable(
  xochitl_color_e2e_bench
  bench/presenter/xochitl_color_e2e_bench.cc
)
target_link_libraries(xochitl_color_e2e_bench PRIVATE pluto_embedder_core)
target_compile_features(xochitl_color_e2e_bench PRIVATE cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(
    xochitl_color_e2e_bench PRIVATE -Wall -Wextra -Wpedantic
  )
endif()

# Replay harness: replays a PLUTO_RECORD_FRAMES stream through the renderer
# with a determinism self-check (two runs must settle to byte-equal frames
# with identical damage totals) and prints damage efficiency. Also owns the
# synthetic stream generators, so CI regenerates fixtures on demand.
add_executable(renderer_replay tools/renderer_replay.cc)
target_link_libraries(renderer_replay PRIVATE pluto_embedder_core)
target_compile_features(renderer_replay PRIVATE cxx_std_20)

if(PLUTO_BUILD_SWTCON_PROBE)
  add_subdirectory(src/presenter/swtcon/tools)
endif()

include(CTest)
if(BUILD_TESTING)
  add_test(NAME pluto_embedder_smoke COMMAND pluto-embedder)
  add_test(
    NAME pluto_embedder_default_release
    COMMAND pluto-embedder --print-config
  )
  set_tests_properties(
    pluto_embedder_default_release
    PROPERTIES PASS_REGULAR_EXPRESSION "mode.*release"
  )
  add_test(
    NAME pluto_embedder_explicit_debug
    COMMAND pluto-embedder --debug --print-config
  )
  set_tests_properties(
    pluto_embedder_explicit_debug
    PROPERTIES PASS_REGULAR_EXPRESSION "mode.*debug"
  )
  # Regenerate the three synthetic streams and prove the renderer replays
  # each deterministically (byte-equal settled frames, identical damage
  # totals across two runs).
  add_test(NAME renderer_replay_harness COMMAND renderer_replay all)
  # The four-stream harness takes ~60 s on a bare host but ~5.5 min under
  # ThreadSanitizer; the budget covers the TSan run with margin.
  set_tests_properties(renderer_replay_harness PROPERTIES TIMEOUT 900)
endif()

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(pluto_abi PRIVATE -Wall -Wextra -Wpedantic)
  target_compile_options(pluto_renderer PRIVATE -Wall -Wextra -Wpedantic)
  target_compile_options(pluto_input PRIVATE -Wall -Wextra -Wpedantic)
  target_compile_options(pluto_embedder_core PRIVATE -Wall -Wextra -Wpedantic)
  target_compile_options(pluto-embedder PRIVATE -Wall -Wextra -Wpedantic)
  target_compile_options(pluto_renderer_bench PRIVATE -Wall -Wextra -Wpedantic)
  target_compile_options(pluto_presenter_bench PRIVATE -Wall -Wextra -Wpedantic)
  target_compile_options(xochitl_mapped_sweep_bench PRIVATE -Wall -Wextra -Wpedantic)
  target_compile_options(renderer_replay PRIVATE -Wall -Wextra -Wpedantic)
endif()

if(BUILD_TESTING AND PLUTO_BUILD_TESTS)
  add_subdirectory(test)

  find_package(GTest QUIET)
  if(NOT GTest_FOUND AND PLUTO_FETCH_GTEST)
    include(FetchContent)
    FetchContent_Declare(
      googletest
      URL https://github.com/google/googletest/archive/refs/tags/v1.15.2.zip
    )
    FetchContent_MakeAvailable(googletest)
  endif()

  if(TARGET GTest::gtest_main)
    set(PLUTO_RENDERER_GTEST_MAIN GTest::gtest_main)
  elseif(TARGET gtest_main)
    set(PLUTO_RENDERER_GTEST_MAIN gtest_main)
  endif()

  set(PLUTO_RENDERER_TEST_SOURCES
    test/renderer/abi_bridge_convert_test.cc
    test/renderer/abi_bridge_test.cc
    test/renderer/auto_ghostbuster_test.cc
    test/renderer/classify_ladder_test.cc
    test/renderer/frame_ledger_test.cc
    test/renderer/guard_band_test.cc
    test/renderer/kernels_test.cc
    test/renderer/ledgers_test.cc
    test/renderer/pen_render_policy_test.cc
    test/renderer/region_scheduler_test.cc
    test/renderer/renderer_config_test.cc
    test/renderer/renderer_handoff_test.cc
    test/renderer/renderer_test.cc
    test/renderer/scroll_detect_test.cc
    test/renderer/settle_policy_test.cc
    test/renderer/tile_pass_test.cc
  )

  if(DEFINED PLUTO_RENDERER_GTEST_MAIN)
    add_executable(pluto_renderer_test ${PLUTO_RENDERER_TEST_SOURCES})
    target_link_libraries(
      pluto_renderer_test
      PRIVATE
        pluto_renderer
        ${PLUTO_RENDERER_GTEST_MAIN}
    )
    target_compile_features(pluto_renderer_test PRIVATE cxx_std_20)
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
      target_compile_options(pluto_renderer_test PRIVATE -Wall -Wextra -Wpedantic)
    endif()

    include(GoogleTest)
    gtest_discover_tests(pluto_renderer_test)
  else()
    message(STATUS "GoogleTest not available; using renderer test compatibility shim")
    add_executable(
      pluto_renderer_test
        ${PLUTO_RENDERER_TEST_SOURCES}
        test/renderer/gtest_main.cc
    )
    target_include_directories(pluto_renderer_test PRIVATE test/renderer)
    target_link_libraries(pluto_renderer_test PRIVATE pluto_renderer)
    target_compile_features(pluto_renderer_test PRIVATE cxx_std_20)
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
      target_compile_options(pluto_renderer_test PRIVATE -Wall -Wextra -Wpedantic)
    endif()
    add_test(NAME pluto_renderer_test COMMAND pluto_renderer_test)
  endif()

  set(PLUTO_INPUT_TEST_SOURCES
    test/input/calibration_test.cc
    test/input/evdev_replay_test.cc
    test/input/ink_thread_test.cc
    test/input/pen_ring_test.cc
    test/input/pen_test.cc
    test/input/touch_test.cc
    test/input/transform_test.cc
  )

  if(DEFINED PLUTO_RENDERER_GTEST_MAIN)
    add_executable(pluto_input_test ${PLUTO_INPUT_TEST_SOURCES})
    target_link_libraries(
      pluto_input_test
      PRIVATE
        pluto_input
        ${PLUTO_RENDERER_GTEST_MAIN}
    )
    target_compile_features(pluto_input_test PRIVATE cxx_std_20)
    target_compile_definitions(
      pluto_input_test
      PRIVATE
        PLUTO_INPUT_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/test/input/fixtures"
    )
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
      target_compile_options(pluto_input_test PRIVATE -Wall -Wextra -Wpedantic)
    endif()

    gtest_discover_tests(pluto_input_test)
  else()
    add_executable(
      pluto_input_test
        ${PLUTO_INPUT_TEST_SOURCES}
        test/renderer/gtest_main.cc
    )
    target_include_directories(pluto_input_test PRIVATE test/renderer)
    target_link_libraries(pluto_input_test PRIVATE pluto_input)
    target_compile_features(pluto_input_test PRIVATE cxx_std_20)
    target_compile_definitions(
      pluto_input_test
      PRIVATE
        PLUTO_INPUT_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/test/input/fixtures"
    )
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
      target_compile_options(pluto_input_test PRIVATE -Wall -Wextra -Wpedantic)
    endif()
    add_test(NAME pluto_input_test COMMAND pluto_input_test)
  endif()

  set(PLUTO_EMBEDDER_CORE_TEST_SOURCES
    test/channels/channel_registry_test.cc
    test/channels/device_channels_test.cc
    test/channels/event_channel_test.cc
    test/channels/pen_channels_test.cc
    test/channels/sensor_channels_test.cc
    test/channels/service_channels_test.cc
    test/channels/standard_codec_test.cc
    test/compositor/backing_store_pool_test.cc
    test/compositor/frame_renderer_test.cc
    test/compositor/software_compositor_test.cc
    test/engine/device_identity_test.cc
    test/engine/engine_host_test.cc
    test/engine/engine_loader_test.cc
    test/engine/lifecycle_test.cc
    test/engine/qtfb_input_bridge_test.cc
    test/presenter/mxcfb_backend_test.cc
    test/presenter/mxcfb_device_test.cc
    test/presenter/png_encoder_test.cc
    test/presenter/native_presenter_test.cc
    test/runtime/sha256_test.cc
    test/runtime/vsync_pacer_test.cc
    test/sensors/iio_test.cc
  )
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    list(APPEND PLUTO_EMBEDDER_CORE_TEST_SOURCES
      test/runtime/event_loop_test.cc
    )
  endif()

  if(DEFINED PLUTO_RENDERER_GTEST_MAIN)
    add_executable(pluto_embedder_core_test ${PLUTO_EMBEDDER_CORE_TEST_SOURCES})
    target_link_libraries(
      pluto_embedder_core_test
      PRIVATE
        pluto_embedder_core
        ${PLUTO_RENDERER_GTEST_MAIN}
    )
    target_compile_features(pluto_embedder_core_test PRIVATE cxx_std_20)
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
      target_compile_options(pluto_embedder_core_test PRIVATE -Wall -Wextra -Wpedantic)
    endif()
    gtest_discover_tests(pluto_embedder_core_test)
  else()
    # The compatibility shim only supports a subset of gtest assertions
    # (no ASSERT_FALSE/EXPECT_DOUBLE_EQ/EXPECT_STREQ); these suites only
    # build against real GoogleTest.
    list(REMOVE_ITEM PLUTO_EMBEDDER_CORE_TEST_SOURCES
      test/channels/event_channel_test.cc
      test/sensors/iio_test.cc
    )
    message(STATUS
      "GoogleTest not available; omitting shim-incompatible embedder core "
      "tests (event_channel, iio)")
    add_executable(
      pluto_embedder_core_test
        ${PLUTO_EMBEDDER_CORE_TEST_SOURCES}
        test/renderer/gtest_main.cc
    )
    target_include_directories(pluto_embedder_core_test PRIVATE test/renderer)
    target_link_libraries(pluto_embedder_core_test PRIVATE pluto_embedder_core)
    target_compile_features(pluto_embedder_core_test PRIVATE cxx_std_20)
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
      target_compile_options(pluto_embedder_core_test PRIVATE -Wall -Wextra -Wpedantic)
    endif()
    add_test(NAME pluto_embedder_core_test COMMAND pluto_embedder_core_test)
  endif()

  if(DEFINED PLUTO_RENDERER_GTEST_MAIN)
    add_executable(
      pluto_wbf_decoder_test
      test/presenter/wbf_decoder_test.cc
    )
    target_link_libraries(
      pluto_wbf_decoder_test
      PRIVATE
        pluto_embedder_core
        ${PLUTO_RENDERER_GTEST_MAIN}
    )
    gtest_discover_tests(pluto_wbf_decoder_test)
  else()
    add_executable(
      pluto_wbf_decoder_test
      test/presenter/wbf_decoder_test.cc
      test/renderer/gtest_main.cc
    )
    target_include_directories(pluto_wbf_decoder_test PRIVATE test/renderer)
    target_link_libraries(pluto_wbf_decoder_test PRIVATE pluto_embedder_core)
    add_test(NAME pluto_wbf_decoder_test COMMAND pluto_wbf_decoder_test)
  endif()
  target_compile_features(pluto_wbf_decoder_test PRIVATE cxx_std_20)
  target_compile_definitions(
    pluto_wbf_decoder_test
    PRIVATE
      PLUTO_RM2_WBF_FIXTURE="${CMAKE_CURRENT_SOURCE_DIR}/../analysis/native-cutover/rm2/vendor/active.wbf"
  )
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(
      pluto_wbf_decoder_test PRIVATE -Wall -Wextra -Wpedantic
    )
  endif()

  # Keep the bundle's corruption/atomicity/large exact-color tests independently
  # runnable; the full presenter suite is intentionally much slower.
  if(DEFINED PLUTO_RENDERER_GTEST_MAIN)
    add_executable(
      pluto_glass_handoff_test
      test/presenter/glass_handoff_test.cc
    )
    target_link_libraries(
      pluto_glass_handoff_test
      PRIVATE
        pluto_embedder_core
        ${PLUTO_RENDERER_GTEST_MAIN}
    )
    gtest_discover_tests(pluto_glass_handoff_test)
  else()
    add_executable(
      pluto_glass_handoff_test
      test/presenter/glass_handoff_test.cc
      test/renderer/gtest_main.cc
    )
    target_include_directories(pluto_glass_handoff_test PRIVATE test/renderer)
    target_link_libraries(pluto_glass_handoff_test PRIVATE pluto_embedder_core)
    add_test(NAME pluto_glass_handoff_test COMMAND pluto_glass_handoff_test)
  endif()
  target_compile_features(pluto_glass_handoff_test PRIVATE cxx_std_20)
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(
      pluto_glass_handoff_test PRIVATE -Wall -Wextra -Wpedantic
    )
  endif()

  set(PLUTO_PRESENTER_TEST_SOURCES
    test/presenter/admission_mailbox_test.cc
    test/presenter/ct33_frontend_test.cc
    test/presenter/content_consistency_test.cc
    test/presenter/convert_levels_test.cc
    test/presenter/drm_swtcon_presenter_test.cc
    test/presenter/engine_equivalence_test.cc
    test/presenter/fast_rail_admit_kernels_test.cc
    test/presenter/hygiene_fsm_test.cc
    test/presenter/l0_trace_test.cc
    test/presenter/phase_emit_test.cc
    test/presenter/pixel_engine_test.cc
    test/presenter/qtfb_presenter_test.cc
    test/presenter/scan_loop_test.cc
    test/presenter/sweep_kernels_test.cc
    test/presenter/swtcon_dc_ledger_test.cc
    test/presenter/swtcon_drm_device_test.cc
    test/presenter/swtcon_lut_cache_test.cc
    test/presenter/swtcon_packer_test.cc
    test/presenter/swtcon_rails_test.cc
    test/presenter/swtcon_temperature_test.cc
    test/presenter/swtcon_waveform_test.cc
    # TEST-ONLY reference model: the legacy record-playback
    # packer is compiled into the test binary as the equivalence-proof
    # oracle + word-exact encoding pins. It has NO production linkage — the
    # per-pixel engine (pixel_engine/phase_emit) is the only frame path.
    src/presenter/swtcon/swtcon_packer.cc
    src/presenter/swtcon/swtcon_phase_generator.cc
  )

  # Golden-decode fixture: the panel .eink checked into analysis/. The test
  # self-skips when the file is absent (e.g. stripped-down checkouts).
  set(PLUTO_SWTCON_EINK_FIXTURE
    "${CMAKE_CURRENT_SOURCE_DIR}/../analysis/swtcon/waveforms/GAL3_AAB0AM_IC0801_AC073MC1F2_AD1004-GCA_TC.eink")
  set(PLUTO_CT33_FIXTURE
    "${CMAKE_CURRENT_SOURCE_DIR}/../analysis/swtcon/waveforms/ct33_std.bin")

  if(DEFINED PLUTO_RENDERER_GTEST_MAIN)
    add_executable(pluto_presenter_test ${PLUTO_PRESENTER_TEST_SOURCES})
    target_link_libraries(
      pluto_presenter_test
      PRIVATE
        pluto_embedder_core
        ${PLUTO_RENDERER_GTEST_MAIN}
    )
    target_compile_features(pluto_presenter_test PRIVATE cxx_std_20)
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
      target_compile_options(pluto_presenter_test PRIVATE -Wall -Wextra -Wpedantic)
    endif()
    # Surface GTEST_SKIP (e.g. the gitignored .eink golden fixture missing)
    # as ctest "Skipped" instead of a silent pass.
    gtest_discover_tests(
      pluto_presenter_test
      PROPERTIES SKIP_REGULAR_EXPRESSION "\\[  SKIPPED \\]"
    )
  else()
    add_executable(
      pluto_presenter_test
        ${PLUTO_PRESENTER_TEST_SOURCES}
        test/renderer/gtest_main.cc
    )
    target_include_directories(pluto_presenter_test PRIVATE test/renderer)
    target_link_libraries(pluto_presenter_test PRIVATE pluto_embedder_core)
    target_compile_features(pluto_presenter_test PRIVATE cxx_std_20)
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
      target_compile_options(pluto_presenter_test PRIVATE -Wall -Wextra -Wpedantic)
    endif()
    add_test(NAME pluto_presenter_test COMMAND pluto_presenter_test)
  endif()
  target_compile_definitions(
    pluto_presenter_test
    PRIVATE
      PLUTO_SWTCON_EINK_FIXTURE="${PLUTO_SWTCON_EINK_FIXTURE}"
      PLUTO_CT33_FIXTURE="${PLUTO_CT33_FIXTURE}"
  )

  # Production-disconnected scalar oracle for the installed Xochitl 3.27
  # legacy colour mapper.  Keep this as its own test executable so adding the
  # model can never make it part of pluto_embedder_core or the device image.
  set(PLUTO_XOCHITL_MAPPER_REFERENCE_TEST_SOURCES
    test/presenter/xochitl_color_mapper_reference.cc
    test/presenter/xochitl_color_mapper_reference_test.cc
    test/presenter/xochitl_fast_state_reference.cc
    test/presenter/xochitl_fast_state_reference_test.cc
    test/presenter/xochitl_selector16_reference.cc
    test/presenter/xochitl_selector16_reference_test.cc
  )
  if(DEFINED PLUTO_RENDERER_GTEST_MAIN)
    add_executable(
      xochitl_color_mapper_reference_test
      ${PLUTO_XOCHITL_MAPPER_REFERENCE_TEST_SOURCES}
    )
    target_link_libraries(
      xochitl_color_mapper_reference_test
      PRIVATE ${PLUTO_RENDERER_GTEST_MAIN}
    )
    gtest_discover_tests(xochitl_color_mapper_reference_test)
  else()
    add_executable(
      xochitl_color_mapper_reference_test
      ${PLUTO_XOCHITL_MAPPER_REFERENCE_TEST_SOURCES}
      test/renderer/gtest_main.cc
    )
    target_include_directories(
      xochitl_color_mapper_reference_test PRIVATE test/renderer
    )
    add_test(
      NAME xochitl_color_mapper_reference_test
      COMMAND xochitl_color_mapper_reference_test
    )
  endif()
  target_compile_features(
    xochitl_color_mapper_reference_test PRIVATE cxx_std_20
  )
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(
      xochitl_color_mapper_reference_test PRIVATE -Wall -Wextra -Wpedantic
    )
  endif()

  # Production delta-table surface, differentially checked against the
  # separately compiled research oracle.  The reference remains test-only;
  # only xochitl_delta_table.cc is linked into pluto_embedder_core.
  set(PLUTO_XOCHITL_DELTA_TABLE_TEST_SOURCES
    test/presenter/xochitl_delta_table_test.cc
    test/presenter/xochitl_color_mapper_reference.cc
  )
  if(DEFINED PLUTO_RENDERER_GTEST_MAIN)
    add_executable(
      xochitl_delta_table_test
      ${PLUTO_XOCHITL_DELTA_TABLE_TEST_SOURCES}
    )
    target_link_libraries(
      xochitl_delta_table_test
      PRIVATE
        pluto_embedder_core
        ${PLUTO_RENDERER_GTEST_MAIN}
    )
    gtest_discover_tests(xochitl_delta_table_test)
  else()
    add_executable(
      xochitl_delta_table_test
      ${PLUTO_XOCHITL_DELTA_TABLE_TEST_SOURCES}
      test/renderer/gtest_main.cc
    )
    target_include_directories(
      xochitl_delta_table_test PRIVATE test/renderer
    )
    target_link_libraries(
      xochitl_delta_table_test PRIVATE pluto_embedder_core
    )
    add_test(NAME xochitl_delta_table_test COMMAND xochitl_delta_table_test)
  endif()

  if(DEFINED PLUTO_RENDERER_GTEST_MAIN)
    add_executable(
      xochitl_color_pipeline_test
      test/presenter/xochitl_color_pipeline_test.cc
    )
    target_link_libraries(
      xochitl_color_pipeline_test
      PRIVATE pluto_embedder_core ${PLUTO_RENDERER_GTEST_MAIN}
    )
    gtest_discover_tests(xochitl_color_pipeline_test)
  else()
    add_executable(
      xochitl_color_pipeline_test
      test/presenter/xochitl_color_pipeline_test.cc
      test/renderer/gtest_main.cc
    )
    target_include_directories(
      xochitl_color_pipeline_test PRIVATE test/renderer test/presenter
    )
    target_link_libraries(
      xochitl_color_pipeline_test PRIVATE pluto_embedder_core
    )
    add_test(
      NAME xochitl_color_pipeline_test COMMAND xochitl_color_pipeline_test
    )
  endif()
  target_include_directories(
    xochitl_color_pipeline_test PRIVATE test/presenter
  )
  target_compile_features(xochitl_color_pipeline_test PRIVATE cxx_std_20)
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(
      xochitl_color_pipeline_test PRIVATE -Wall -Wextra -Wpedantic
    )
  endif()
  target_compile_definitions(
    xochitl_delta_table_test
    PRIVATE PLUTO_SWTCON_EINK_FIXTURE="${PLUTO_SWTCON_EINK_FIXTURE}"
  )
  target_compile_features(xochitl_delta_table_test PRIVATE cxx_std_20)
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(
      xochitl_delta_table_test PRIVATE -Wall -Wextra -Wpedantic
    )
  endif()

  # Allocation-free production mapped sweep, isolated from the live grayscale
  # engine while the Xochitl path's release gates remain open.  On AArch64 its
  # random suite differentially checks the NEON byte stream and all state
  # planes against the scalar reference, including cold-bin phase counts.
  if(DEFINED PLUTO_RENDERER_GTEST_MAIN)
    add_executable(
      mapped_sweep_test
      test/presenter/mapped_sweep_test.cc
    )
    target_link_libraries(
      mapped_sweep_test
      PRIVATE
        pluto_embedder_core
        ${PLUTO_RENDERER_GTEST_MAIN}
    )
    gtest_discover_tests(mapped_sweep_test)
  else()
    add_executable(
      mapped_sweep_test
      test/presenter/mapped_sweep_test.cc
      test/renderer/gtest_main.cc
    )
    target_include_directories(mapped_sweep_test PRIVATE test/renderer)
    target_link_libraries(mapped_sweep_test PRIVATE pluto_embedder_core)
    add_test(NAME mapped_sweep_test COMMAND mapped_sweep_test)
  endif()
  target_compile_features(mapped_sweep_test PRIVATE cxx_std_20)
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(
      mapped_sweep_test PRIVATE -Wall -Wextra -Wpedantic
    )
  endif()

  # Production selector-16 surface, checked against the independently
  # compiled stock scalar transcription.  The production route retains the
  # stock lifetime halo but globally barriers coarse/classify/resolve stages,
  # eliminating the installed three-worker scheduling race.
  set(PLUTO_XOCHITL_SELECTOR16_TEST_SOURCES
    test/presenter/xochitl_selector16_test.cc
    test/presenter/xochitl_selector16_reference.cc
  )
  if(DEFINED PLUTO_RENDERER_GTEST_MAIN)
    add_executable(
      xochitl_selector16_test
      ${PLUTO_XOCHITL_SELECTOR16_TEST_SOURCES}
    )
    target_link_libraries(
      xochitl_selector16_test
      PRIVATE
        pluto_embedder_core
        ${PLUTO_RENDERER_GTEST_MAIN}
    )
    gtest_discover_tests(xochitl_selector16_test)
  else()
    add_executable(
      xochitl_selector16_test
      ${PLUTO_XOCHITL_SELECTOR16_TEST_SOURCES}
      test/renderer/gtest_main.cc
    )
    target_include_directories(
      xochitl_selector16_test PRIVATE test/renderer
    )
    target_link_libraries(
      xochitl_selector16_test PRIVATE pluto_embedder_core
    )
    add_test(NAME xochitl_selector16_test COMMAND xochitl_selector16_test)
  endif()
  target_compile_features(xochitl_selector16_test PRIVATE cxx_std_20)
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(
      xochitl_selector16_test PRIVATE -Wall -Wextra -Wpedantic
    )
  endif()

  # Transactional production A/B owner.  It is not connected to the
  # presenter yet; this dedicated target differentially checks its whole-op
  # journals against the independently compiled legacy/Fast research models.
  set(PLUTO_XOCHITL_HISTORY_STATE_TEST_SOURCES
    test/presenter/xochitl_history_state_test.cc
    test/presenter/xochitl_color_mapper_reference.cc
    test/presenter/xochitl_fast_state_reference.cc
  )
  if(DEFINED PLUTO_RENDERER_GTEST_MAIN)
    add_executable(
      xochitl_history_state_test
      ${PLUTO_XOCHITL_HISTORY_STATE_TEST_SOURCES}
    )
    target_link_libraries(
      xochitl_history_state_test
      PRIVATE
        pluto_embedder_core
        ${PLUTO_RENDERER_GTEST_MAIN}
    )
    gtest_discover_tests(xochitl_history_state_test)
  else()
    add_executable(
      xochitl_history_state_test
      ${PLUTO_XOCHITL_HISTORY_STATE_TEST_SOURCES}
      test/renderer/gtest_main.cc
    )
    target_include_directories(
      xochitl_history_state_test PRIVATE test/renderer
    )
    target_link_libraries(
      xochitl_history_state_test PRIVATE pluto_embedder_core
    )
    add_test(
      NAME xochitl_history_state_test COMMAND xochitl_history_state_test
    )
  endif()
  target_compile_features(xochitl_history_state_test PRIVATE cxx_std_20)
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(
      xochitl_history_state_test PRIVATE -Wall -Wextra -Wpedantic
    )
  endif()
endif()
