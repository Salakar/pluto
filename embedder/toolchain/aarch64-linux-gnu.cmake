set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_C_COMPILER clang CACHE FILEPATH "C compiler")
set(CMAKE_CXX_COMPILER clang++ CACHE FILEPATH "C++ compiler")
set(CMAKE_C_COMPILER_TARGET aarch64-linux-gnu)
set(CMAKE_CXX_COMPILER_TARGET aarch64-linux-gnu)

set(CMAKE_C_FLAGS_INIT "-mcpu=cortex-a55")
set(CMAKE_CXX_FLAGS_INIT "-mcpu=cortex-a55")

