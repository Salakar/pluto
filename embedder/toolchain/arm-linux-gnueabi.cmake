set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

if(NOT DEFINED PLUTO_RM_SDK_ROOT)
  if(DEFINED ENV{PLUTO_RM_SDK_ROOT})
    set(PLUTO_RM_SDK_ROOT "$ENV{PLUTO_RM_SDK_ROOT}")
  else()
    set(PLUTO_RM_SDK_ROOT "/sdk")
  endif()
endif()

set(
  PLUTO_RM_SDK_TARGET_SYSROOT
  "${PLUTO_RM_SDK_ROOT}/sysroots/cortexa7hf-neon-remarkable-linux-gnueabi"
)
set(
  PLUTO_RM_SDK_NATIVE_SYSROOT
  "${PLUTO_RM_SDK_ROOT}/sysroots/x86_64-codexsdk-linux"
)
set(
  PLUTO_RM_SDK_TOOLCHAIN_BIN
  "${PLUTO_RM_SDK_NATIVE_SYSROOT}/usr/bin/arm-remarkable-linux-gnueabi"
)
set(
  PLUTO_RM_SDK_TOOLCHAIN_PREFIX
  "${PLUTO_RM_SDK_TOOLCHAIN_BIN}/arm-remarkable-linux-gnueabi"
)

foreach(required_path
    "${PLUTO_RM_SDK_TARGET_SYSROOT}"
    "${PLUTO_RM_SDK_TOOLCHAIN_PREFIX}-gcc"
    "${PLUTO_RM_SDK_TOOLCHAIN_PREFIX}-g++")
  if(NOT EXISTS "${required_path}")
    message(
      FATAL_ERROR
      "The reMarkable ARM SDK is incomplete at ${PLUTO_RM_SDK_ROOT}; "
      "missing ${required_path}. Run tools/build/embedder-device-arm.sh with "
      "--sdk-volume or --sdk-dir."
    )
  endif()
endforeach()

set(CMAKE_SYSROOT "${PLUTO_RM_SDK_TARGET_SYSROOT}")
set(CMAKE_C_COMPILER "${PLUTO_RM_SDK_TOOLCHAIN_PREFIX}-gcc")
set(CMAKE_CXX_COMPILER "${PLUTO_RM_SDK_TOOLCHAIN_PREFIX}-g++")
set(CMAKE_AR "${PLUTO_RM_SDK_TOOLCHAIN_PREFIX}-ar")
set(CMAKE_NM "${PLUTO_RM_SDK_TOOLCHAIN_PREFIX}-nm")
set(CMAKE_OBJCOPY "${PLUTO_RM_SDK_TOOLCHAIN_PREFIX}-objcopy")
set(CMAKE_OBJDUMP "${PLUTO_RM_SDK_TOOLCHAIN_PREFIX}-objdump")
set(CMAKE_RANLIB "${PLUTO_RM_SDK_TOOLCHAIN_PREFIX}-ranlib")
set(CMAKE_READELF "${PLUTO_RM_SDK_TOOLCHAIN_PREFIX}-readelf")
set(CMAKE_STRIP "${PLUTO_RM_SDK_TOOLCHAIN_PREFIX}-strip")

# Both the Cortex-A9 reMarkable 1 and Cortex-A7 reMarkable 2 implement the
# ARMv7-A NEON hard-float baseline. Keep this deliberately CPU-generic: the
# official SDK environment defaults to its reMarkable 2 CPU, which is not a
# valid portability contract for the reMarkable 1.
set(PLUTO_ARM_ARCH_FLAGS "-march=armv7-a -mfpu=neon -mfloat-abi=hard")
set(CMAKE_C_FLAGS_INIT "${PLUTO_ARM_ARCH_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${PLUTO_ARM_ARCH_FLAGS}")
set(
  CMAKE_EXE_LINKER_FLAGS_INIT
  "-Wl,-O1 -Wl,--hash-style=gnu -Wl,--as-needed"
)

set(CMAKE_FIND_ROOT_PATH "${PLUTO_RM_SDK_TARGET_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
