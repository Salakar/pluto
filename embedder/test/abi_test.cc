#include "pluto/abi.h"

#include <gtest/gtest.h>

TEST(PlutoAbiTest, VersionIsTwo) { EXPECT_EQ(pluto_abi_version(), 2u); }
