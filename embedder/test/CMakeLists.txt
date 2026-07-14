option(PLUTO_FETCH_GTEST "Fetch GoogleTest when it is not installed" OFF)

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
  set(PLUTO_GTEST_MAIN GTest::gtest_main)
elseif(TARGET gtest_main)
  set(PLUTO_GTEST_MAIN gtest_main)
endif()

if(DEFINED PLUTO_GTEST_MAIN)
  add_executable(pluto_abi_test abi_test.cc)
  target_link_libraries(pluto_abi_test PRIVATE pluto_abi ${PLUTO_GTEST_MAIN})

  include(GoogleTest)
  gtest_discover_tests(pluto_abi_test)
else()
  message(STATUS "GoogleTest not available; skipping native tests")
endif()

