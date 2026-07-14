#include "engine/engine_loader.h"

#include "gtest/gtest.h"

namespace {

TEST(EngineLoader, MissingLibraryFailsWithDiagnostic) {
  pluto::EngineLibrary library;
  std::string error;
  EXPECT_FALSE(library.load("/definitely/missing/libflutter_engine.so", &error));
  EXPECT_TRUE(!library.loaded());
  EXPECT_TRUE(error.find("dlopen failed") != std::string::npos);
}

}  // namespace
