#include "presenter/swtcon/admission_mailbox.h"

#include "presenter/swtcon/pixel_engine.h"

#include <gtest/gtest.h>

#include <atomic>
#include <cstdint>
#include <thread>
#include <vector>

namespace {

using pluto::swtcon::AdmissionMailbox;
using pluto::swtcon::AdmissionMailboxConfig;
using pluto::swtcon::AdmissionMailboxRecord;
using pluto::swtcon::AdmitRequest;
using pluto::swtcon::kAdmitFlagGuardNull;
using pluto::swtcon::kAdmitFlagPen;

AdmitRequest make_request(const PlutoRect& rect,
                          const std::uint8_t* levels,
                          std::uint64_t frame_id,
                          std::uint32_t flags = 0) {
  AdmitRequest request;
  request.rect = rect;
  request.mode = 2;
  request.levels = levels;
  request.frame_id = frame_id;
  request.flags = flags;
  return request;
}

TEST(AdmissionMailboxTest, RoundTripsHeaderAndPayload) {
  AdmissionMailbox mailbox;
  AdmissionMailboxConfig config;
  config.capacity = 8;
  config.payload_capacity = 64;
  ASSERT_TRUE(mailbox.configure(config));
  EXPECT_EQ(mailbox.capacity(), 8u);

  // Strided source payload: the copy tightens it to rect.width pitch.
  const PlutoRect rect{5, 7, 4, 3};
  std::vector<std::uint8_t> levels(3 * 16, 0);
  for (int y = 0; y < 3; ++y) {
    for (int x = 0; x < 4; ++x) {
      levels[static_cast<std::size_t>(y) * 16 + x] =
          static_cast<std::uint8_t>(y * 4 + x);
    }
  }
  AdmitRequest request = make_request(rect, levels.data(), 42);
  request.levels_stride = 16;
  request.mode = 7;
  request.temp_bin = 4;
  ASSERT_EQ(mailbox.push(request), kPlutoStatusOk);

  AdmissionMailboxRecord record;
  ASSERT_TRUE(mailbox.pop(&record));
  EXPECT_EQ(record.request.rect.x, 5);
  EXPECT_EQ(record.request.rect.y, 7);
  EXPECT_EQ(record.request.rect.width, 4);
  EXPECT_EQ(record.request.rect.height, 3);
  EXPECT_EQ(record.request.mode, 7);
  EXPECT_EQ(record.request.temp_bin, 4);
  EXPECT_EQ(record.request.frame_id, 42u);
  EXPECT_EQ(record.request.levels_stride, 0u);
  ASSERT_EQ(record.payload.size(), 12u);
  ASSERT_TRUE(record.request.levels == record.payload.data());
  for (int i = 0; i < 12; ++i) {
    EXPECT_EQ(record.payload[static_cast<std::size_t>(i)], i);
  }
  EXPECT_FALSE(mailbox.pop(&record));  // drained
}

TEST(AdmissionMailboxTest, PenAndGuardRecordsAreHeaderOnly) {
  AdmissionMailbox mailbox;
  AdmissionMailboxConfig config;
  config.capacity = 4;
  config.payload_capacity = 16;
  ASSERT_TRUE(mailbox.configure(config));

  // The legacy PEN sentinel is header-only: zero payload copy and
  // levels may be null. Pen-correlated app damage uses payload records.
  const PlutoRect rect{0, 0, 32, 32};  // larger than payload_capacity
  ASSERT_EQ(mailbox.push(make_request(rect, nullptr, 7, kAdmitFlagPen)),
            kPlutoStatusOk);
  ASSERT_EQ(mailbox.push(make_request(rect, nullptr, 0, kAdmitFlagGuardNull)),
            kPlutoStatusOk);

  AdmissionMailboxRecord record;
  ASSERT_TRUE(mailbox.pop(&record));
  EXPECT_EQ(record.request.flags, static_cast<std::uint32_t>(kAdmitFlagPen));
  EXPECT_TRUE(record.request.levels == nullptr);
  EXPECT_EQ(record.payload.size(), 0u);
  ASSERT_TRUE(mailbox.pop(&record));
  EXPECT_EQ(record.request.flags,
            static_cast<std::uint32_t>(kAdmitFlagGuardNull));
  EXPECT_TRUE(record.request.levels == nullptr);
}

TEST(AdmissionMailboxTest, FullRingReturnsAgainAndRecoversAfterPop) {
  AdmissionMailbox mailbox;
  AdmissionMailboxConfig config;
  config.capacity = 4;  // already a power of two
  config.payload_capacity = 4;
  ASSERT_TRUE(mailbox.configure(config));

  const PlutoRect rect{0, 0, 2, 2};
  const std::uint8_t levels[4] = {1, 2, 3, 4};
  for (std::uint64_t i = 0; i < 4; ++i) {
    ASSERT_EQ(mailbox.push(make_request(rect, levels, i + 1)),
              kPlutoStatusOk);
  }
  // kPlutoStatusAgain is the ONLY backpressure signal.
  EXPECT_EQ(mailbox.push(make_request(rect, levels, 99)), kPlutoStatusAgain);
  EXPECT_EQ(mailbox.stats().full_rejects, 1u);

  AdmissionMailboxRecord record;
  ASSERT_TRUE(mailbox.pop(&record));
  EXPECT_EQ(record.request.frame_id, 1u);  // FIFO
  ASSERT_EQ(mailbox.push(make_request(rect, levels, 5)), kPlutoStatusOk);
  for (std::uint64_t expected = 2; expected <= 5; ++expected) {
    ASSERT_TRUE(mailbox.pop(&record));
    EXPECT_EQ(record.request.frame_id, expected);
  }
  EXPECT_FALSE(mailbox.pop(&record));
}

TEST(AdmissionMailboxTest, RejectsInvalidRequestsAndConfigs) {
  AdmissionMailbox mailbox;
  const PlutoRect rect{0, 0, 2, 2};
  const std::uint8_t levels[4] = {0, 0, 0, 0};
  // Unconfigured.
  EXPECT_EQ(mailbox.push(make_request(rect, levels, 1)),
            kPlutoStatusInvalidArgument);

  AdmissionMailboxConfig bad;
  bad.capacity = 0;
  EXPECT_FALSE(mailbox.configure(bad));

  AdmissionMailboxConfig config;
  config.capacity = 5;  // rounds up to 8
  config.payload_capacity = 8;
  ASSERT_TRUE(mailbox.configure(config));
  EXPECT_EQ(mailbox.capacity(), 8u);

  // Missing levels on a payload-carrying record.
  EXPECT_EQ(mailbox.push(make_request(rect, nullptr, 1)),
            kPlutoStatusInvalidArgument);
  // Degenerate rect.
  EXPECT_EQ(mailbox.push(make_request({0, 0, 0, 2}, levels, 1)),
            kPlutoStatusInvalidArgument);
  // Payload over capacity: producer split bug, not backpressure.
  EXPECT_EQ(mailbox.push(make_request({0, 0, 3, 3}, levels, 1)),
            kPlutoStatusInvalidArgument);
}

// MPSC torture: N producers at max rate against one consumer. Exactly-once
// delivery + per-producer FIFO. The host-tsan preset builds and runs this
// test with the race detector on.
TEST(AdmissionMailboxTest, TortureManyProducersExactlyOnceFifoPerProducer) {
  constexpr int kProducers = 4;
  constexpr std::uint64_t kPerProducer = 20000;
  constexpr std::uint32_t kPayloadStamp = 4;  // 2x2 rect

  AdmissionMailbox mailbox;
  AdmissionMailboxConfig config;
  config.capacity = 256;
  config.payload_capacity = kPayloadStamp;
  ASSERT_TRUE(mailbox.configure(config));

  std::atomic<bool> start{false};
  // No EXPECT/ASSERT off the main thread (the shim's fatal path throws):
  // producer-side violations are flagged and asserted after join.
  std::atomic<std::uint64_t> producer_errors{0};
  std::vector<std::thread> producers;
  producers.reserve(kProducers);
  for (int p = 0; p < kProducers; ++p) {
    producers.emplace_back([&mailbox, &start, &producer_errors, p]() {
      while (!start.load(std::memory_order_acquire)) {
        std::this_thread::yield();
      }
      const PlutoRect rect{p, 0, 2, 2};
      for (std::uint64_t i = 0; i < kPerProducer; ++i) {
        // frame_id encodes (producer, per-producer seq) for the FIFO check;
        // the payload carries the low byte so the copy is validated too.
        const std::uint64_t frame_id =
            (static_cast<std::uint64_t>(p) << 32) | (i + 1);
        std::uint8_t levels[kPayloadStamp];
        for (std::uint32_t b = 0; b < kPayloadStamp; ++b) {
          levels[b] = static_cast<std::uint8_t>((i + b) & 0xff);
        }
        AdmitRequest request;
        request.rect = rect;
        request.mode = 2;
        request.levels = levels;
        request.frame_id = frame_id;
        for (;;) {
          const PlutoStatus status = mailbox.push(request);
          if (status == kPlutoStatusOk) {
            break;
          }
          if (status != kPlutoStatusAgain ||
              producer_errors.load(std::memory_order_relaxed) != 0) {
            producer_errors.fetch_add(1, std::memory_order_relaxed);
            return;
          }
          std::this_thread::yield();
        }
      }
    });
  }

  std::uint64_t last_seq[kProducers] = {0, 0, 0, 0};
  std::uint64_t received = 0;
  std::uint64_t payload_errors = 0;
  start.store(true, std::memory_order_release);

  AdmissionMailboxRecord record;
  while (received < kProducers * kPerProducer &&
         producer_errors.load(std::memory_order_relaxed) == 0) {
    if (!mailbox.pop(&record)) {
      std::this_thread::yield();
      continue;
    }
    ++received;
    const int producer =
        static_cast<int>(record.request.frame_id >> 32);
    const std::uint64_t seq = record.request.frame_id & 0xffffffffull;
    ASSERT_TRUE(producer >= 0 && producer < kProducers);
    // FIFO per producer: this producer's seqs arrive strictly ascending.
    ASSERT_TRUE(seq > last_seq[producer])
        << "producer " << producer << " seq " << seq << " after "
        << last_seq[producer];
    last_seq[producer] = seq;
    // Payload integrity.
    ASSERT_EQ(record.payload.size(), static_cast<std::size_t>(kPayloadStamp));
    for (std::uint32_t b = 0; b < kPayloadStamp; ++b) {
      if (record.payload[b] !=
          static_cast<std::uint8_t>((seq - 1 + b) & 0xff)) {
        ++payload_errors;
      }
    }
  }

  for (std::thread& producer : producers) {
    producer.join();
  }
  EXPECT_EQ(producer_errors.load(std::memory_order_relaxed), 0u);
  // Exactly-once: every message seen, each producer's last seq is its max.
  EXPECT_EQ(received, kProducers * kPerProducer);
  EXPECT_EQ(payload_errors, 0u);
  for (int p = 0; p < kProducers; ++p) {
    EXPECT_EQ(last_seq[p], kPerProducer);
  }
  EXPECT_EQ(mailbox.stats().pushes, kProducers * kPerProducer);
  EXPECT_EQ(mailbox.stats().pops, kProducers * kPerProducer);
  EXPECT_FALSE(mailbox.pop(&record));
}

}  // namespace
