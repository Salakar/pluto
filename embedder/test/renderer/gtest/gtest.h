#ifndef PLUTO_RENDERER_TEST_GTEST_GTEST_H_
#define PLUTO_RENDERER_TEST_GTEST_GTEST_H_

#include <exception>
#include <functional>
#include <iostream>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace testing {

struct TestCase {
  const char* suite;
  const char* name;
  void (*fn)();
};

inline std::vector<TestCase>& registry() {
  static std::vector<TestCase> tests;
  return tests;
}

inline int& failure_count() {
  static int count = 0;
  return count;
}

class FatalFailure final : public std::exception {
 public:
  const char* what() const noexcept override { return "fatal test assertion"; }
};

class Assertion final {
 public:
  Assertion(bool ok, bool fatal, const char* file, int line, std::string message)
      : ok_(ok), fatal_(fatal), file_(file), line_(line), message_(std::move(message)) {}
  Assertion(const Assertion&) = delete;
  Assertion& operator=(const Assertion&) = delete;
  Assertion(Assertion&& other) noexcept
      : ok_(other.ok_),
        fatal_(other.fatal_),
        file_(other.file_),
        line_(other.line_),
        message_(std::move(other.message_)),
        extra_(std::move(other.extra_)),
        moved_(false) {
    other.moved_ = true;
  }

  ~Assertion() noexcept(false) {
    if (moved_ || ok_) {
      return;
    }
    ++failure_count();
    std::cerr << file_ << ":" << line_ << ": Failure\n" << message_;
    const std::string extra = extra_.str();
    if (!extra.empty()) {
      std::cerr << "\n" << extra;
    }
    std::cerr << "\n";
    if (fatal_) {
      throw FatalFailure();
    }
  }

  template <typename T>
  Assertion& operator<<(const T& value) {
    if (!ok_) {
      extra_ << value;
    }
    return *this;
  }

 private:
  bool ok_;
  bool fatal_;
  const char* file_;
  int line_;
  std::string message_;
  std::ostringstream extra_;
  bool moved_ = false;
};

template <typename T>
void print_value(std::ostringstream& out, const T& value) {
  out << value;
}

// Byte pointers would stream as C strings (and read arbitrary memory while
// the message is built); print them as addresses instead.
inline void print_value(std::ostringstream& out, const unsigned char* value) {
  out << static_cast<const void*>(value);
}
inline void print_value(std::ostringstream& out, unsigned char* value) {
  out << static_cast<const void*>(value);
}

template <typename A, typename B>
std::string comparison_message(const char* lhs_expr,
                               const char* rhs_expr,
                               const A& lhs,
                               const B& rhs,
                               const char* op) {
  std::ostringstream out;
  out << "Expected: (" << lhs_expr << ") " << op << " (" << rhs_expr << ")\n"
      << "  Actual: ";
  print_value(out, lhs);
  out << " vs ";
  print_value(out, rhs);
  return out.str();
}

template <typename A, typename B>
Assertion expect_eq(const A& lhs,
                    const B& rhs,
                    const char* lhs_expr,
                    const char* rhs_expr,
                    const char* file,
                    int line,
                    bool fatal) {
  return Assertion(lhs == rhs, fatal, file, line,
                   comparison_message(lhs_expr, rhs_expr, lhs, rhs, "=="));
}

template <typename A, typename B>
Assertion expect_ne(const A& lhs,
                    const B& rhs,
                    const char* lhs_expr,
                    const char* rhs_expr,
                    const char* file,
                    int line,
                    bool fatal) {
  return Assertion(lhs != rhs, fatal, file, line,
                   comparison_message(lhs_expr, rhs_expr, lhs, rhs, "!="));
}

template <typename A, typename B>
Assertion expect_gt(const A& lhs,
                    const B& rhs,
                    const char* lhs_expr,
                    const char* rhs_expr,
                    const char* file,
                    int line,
                    bool fatal) {
  return Assertion(lhs > rhs, fatal, file, line,
                   comparison_message(lhs_expr, rhs_expr, lhs, rhs, ">"));
}

template <typename A, typename B>
Assertion expect_ge(const A& lhs,
                    const B& rhs,
                    const char* lhs_expr,
                    const char* rhs_expr,
                    const char* file,
                    int line,
                    bool fatal) {
  return Assertion(lhs >= rhs, fatal, file, line,
                   comparison_message(lhs_expr, rhs_expr, lhs, rhs, ">="));
}

template <typename A, typename B>
Assertion expect_lt(const A& lhs,
                    const B& rhs,
                    const char* lhs_expr,
                    const char* rhs_expr,
                    const char* file,
                    int line,
                    bool fatal) {
  return Assertion(lhs < rhs, fatal, file, line,
                   comparison_message(lhs_expr, rhs_expr, lhs, rhs, "<"));
}

template <typename A, typename B>
Assertion expect_le(const A& lhs,
                    const B& rhs,
                    const char* lhs_expr,
                    const char* rhs_expr,
                    const char* file,
                    int line,
                    bool fatal) {
  return Assertion(lhs <= rhs, fatal, file, line,
                   comparison_message(lhs_expr, rhs_expr, lhs, rhs, "<="));
}

inline Assertion expect_near(double lhs,
                             double rhs,
                             double abs_error,
                             const char* lhs_expr,
                             const char* rhs_expr,
                             const char* file,
                             int line) {
  const double delta = lhs > rhs ? lhs - rhs : rhs - lhs;
  std::ostringstream out;
  out << "Expected: |" << lhs_expr << " - " << rhs_expr << "| <= " << abs_error
      << "\n  Actual: " << lhs << " vs " << rhs << " (delta " << delta << ")";
  return Assertion(delta <= abs_error, false, file, line, out.str());
}

inline Assertion expect_bool(bool value,
                             bool expected,
                             const char* expr,
                             const char* file,
                             int line,
                             bool fatal) {
  std::ostringstream out;
  out << "Expected: " << expr << " is " << (expected ? "true" : "false")
      << "\n  Actual: " << (value ? "true" : "false");
  return Assertion(value == expected, fatal, file, line, out.str());
}

class Registrar final {
 public:
  Registrar(const char* suite, const char* name, void (*fn)()) {
    registry().push_back(TestCase{suite, name, fn});
  }
};

inline void InitGoogleTest(int*, char**) {}

inline int RUN_ALL_TESTS() {
  int failed_tests = 0;
  for (const TestCase& test : registry()) {
    const int failures_before = failure_count();
    std::cerr << "[ RUN      ] " << test.suite << "." << test.name << "\n";
    try {
      test.fn();
    } catch (const FatalFailure&) {
    } catch (const std::exception& e) {
      ++failure_count();
      std::cerr << "Unhandled exception: " << e.what() << "\n";
    } catch (...) {
      ++failure_count();
      std::cerr << "Unhandled non-standard exception\n";
    }
    if (failure_count() == failures_before) {
      std::cerr << "[       OK ] " << test.suite << "." << test.name << "\n";
    } else {
      ++failed_tests;
      std::cerr << "[  FAILED  ] " << test.suite << "." << test.name << "\n";
    }
  }
  std::cerr << "[==========] " << registry().size() << " tests ran.\n";
  std::cerr << "[  PASSED  ] " << (registry().size() - failed_tests) << " tests.\n";
  if (failed_tests != 0) {
    std::cerr << "[  FAILED  ] " << failed_tests << " tests.\n";
  }
  return failed_tests == 0 ? 0 : 1;
}

}  // namespace testing

#define TEST(SUITE, NAME)                                                   \
  static void SUITE##_##NAME##_Test();                                      \
  static ::testing::Registrar SUITE##_##NAME##_registrar(#SUITE, #NAME,     \
                                                         &SUITE##_##NAME##_Test); \
  static void SUITE##_##NAME##_Test()

#define EXPECT_EQ(LHS, RHS) \
  ::testing::expect_eq((LHS), (RHS), #LHS, #RHS, __FILE__, __LINE__, false)
#define ASSERT_EQ(LHS, RHS) \
  ::testing::expect_eq((LHS), (RHS), #LHS, #RHS, __FILE__, __LINE__, true)
#define EXPECT_NE(LHS, RHS) \
  ::testing::expect_ne((LHS), (RHS), #LHS, #RHS, __FILE__, __LINE__, false)
#define ASSERT_NE(LHS, RHS) \
  ::testing::expect_ne((LHS), (RHS), #LHS, #RHS, __FILE__, __LINE__, true)
#define EXPECT_GT(LHS, RHS) \
  ::testing::expect_gt((LHS), (RHS), #LHS, #RHS, __FILE__, __LINE__, false)
#define ASSERT_GT(LHS, RHS) \
  ::testing::expect_gt((LHS), (RHS), #LHS, #RHS, __FILE__, __LINE__, true)
#define EXPECT_GE(LHS, RHS) \
  ::testing::expect_ge((LHS), (RHS), #LHS, #RHS, __FILE__, __LINE__, false)
#define ASSERT_GE(LHS, RHS) \
  ::testing::expect_ge((LHS), (RHS), #LHS, #RHS, __FILE__, __LINE__, true)
#define EXPECT_LT(LHS, RHS) \
  ::testing::expect_lt((LHS), (RHS), #LHS, #RHS, __FILE__, __LINE__, false)
#define EXPECT_LE(LHS, RHS) \
  ::testing::expect_le((LHS), (RHS), #LHS, #RHS, __FILE__, __LINE__, false)
#define EXPECT_NEAR(LHS, RHS, ABS_ERROR) \
  ::testing::expect_near((LHS), (RHS), (ABS_ERROR), #LHS, #RHS, __FILE__, \
                         __LINE__)
#define EXPECT_TRUE(EXPR) \
  ::testing::expect_bool(static_cast<bool>(EXPR), true, #EXPR, __FILE__, __LINE__, false)
#define ASSERT_TRUE(EXPR) \
  ::testing::expect_bool(static_cast<bool>(EXPR), true, #EXPR, __FILE__, __LINE__, true)
#define EXPECT_FALSE(EXPR) \
  ::testing::expect_bool(static_cast<bool>(EXPR), false, #EXPR, __FILE__, __LINE__, false)

#endif  // PLUTO_RENDERER_TEST_GTEST_GTEST_H_
