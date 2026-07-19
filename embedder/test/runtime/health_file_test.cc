#include "runtime/health_file.h"

#include <sys/stat.h>
#include <unistd.h>

#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>

#include "gtest/gtest.h"

namespace {

class TempHealthFile {
public:
  explicit TempHealthFile(const char *suffix)
      : directory_(
            std::filesystem::temp_directory_path() /
            ("pluto-health-file-" + std::to_string(::getpid()) + "-" + suffix)),
        path_(directory_ / "health") {
    std::filesystem::remove_all(directory_);
    std::filesystem::create_directories(directory_);
  }

  ~TempHealthFile() { std::filesystem::remove_all(directory_); }

  const std::filesystem::path &directory() const { return directory_; }
  const std::filesystem::path &path() const { return path_; }

private:
  std::filesystem::path directory_;
  std::filesystem::path path_;
};

std::string read_all(const std::filesystem::path &path) {
  std::ifstream stream(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(stream),
                     std::istreambuf_iterator<char>());
}

TEST(HealthFilePublisherTest, AtomicallyReplacesExactPrivateRecord) {
  TempHealthFile temp("atomic");
  std::ofstream(temp.path(), std::ios::binary) << "stale-partial-content";
  pluto::HealthFilePublisher publisher(temp.path().string());
  int error_code = -1;

  ASSERT_TRUE(publisher.publish(1'234'567, &error_code));
  EXPECT_EQ(error_code, 0);
  EXPECT_EQ(read_all(temp.path()),
            "pid=" + std::to_string(::getpid()) + " seq=1 mono_ms=1234\n");
  EXPECT_EQ(publisher.sequence(), 1u);

  struct stat info {};
  ASSERT_EQ(::lstat(temp.path().c_str(), &info), 0);
  EXPECT_TRUE(S_ISREG(info.st_mode));
  EXPECT_EQ(info.st_mode & 0777, 0600);

  ASSERT_TRUE(publisher.publish(2'000'999, &error_code));
  EXPECT_EQ(read_all(temp.path()),
            "pid=" + std::to_string(::getpid()) + " seq=2 mono_ms=2000\n");
  EXPECT_EQ(publisher.sequence(), 2u);

  size_t entries = 0;
  for (const auto &entry :
       std::filesystem::directory_iterator(temp.directory())) {
    (void)entry;
    ++entries;
  }
  EXPECT_EQ(entries, 1u) << "temporary publication files must not remain";
}

TEST(HealthFilePublisherTest, FailureDoesNotAdvanceSequence) {
  TempHealthFile temp("failure");
  const auto missing_path = temp.directory() / "missing" / "health";
  pluto::HealthFilePublisher publisher(missing_path.string());
  int error_code = 0;

  EXPECT_FALSE(publisher.publish(1'000'000, &error_code));
  EXPECT_NE(error_code, 0);
  EXPECT_EQ(publisher.sequence(), 0u);
  EXPECT_FALSE(std::filesystem::exists(missing_path));
}

} // namespace
