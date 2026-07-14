add_executable(
  swtcon_probe
    swtcon_probe.cc
    ../drm_swtcon_device.cc
    ../swtcon_packer.cc
    ../swtcon_phase_generator.cc
    ../swtcon_rails.cc
    ../swtcon_waveform.cc
)

find_library(DRM_LIBRARY drm REQUIRED)

target_include_directories(
  swtcon_probe
  PRIVATE
    ${PROJECT_SOURCE_DIR}/include
    ${PROJECT_SOURCE_DIR}/src
)
target_link_libraries(
  swtcon_probe
  PRIVATE
    Threads::Threads
    ${CMAKE_DL_LIBS}
    ${DRM_LIBRARY}
)
target_compile_features(swtcon_probe PRIVATE cxx_std_20)
set_target_properties(
  swtcon_probe
  PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
)

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(swtcon_probe PRIVATE -Wall -Wextra -Wpedantic)
  target_link_options(swtcon_probe PRIVATE -Wl,--no-as-needed)
endif()
