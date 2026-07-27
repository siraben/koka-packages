#include <array>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <string_view>
#include <system_error>
#include <vector>

namespace {
constexpr std::size_t kAppendsPerRepetition = 80000;
constexpr std::size_t kOutputSize = 800000;
constexpr std::uint64_t kChecksumMultiplier = 1000003;
constexpr std::uint64_t kChecksumModulus = 1000000007;
constexpr std::array<std::uint8_t, 10> kChunk{
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9'};

std::uint64_t parse_work(int argc, char** argv) {
  if (argc < 2) return 1;
  std::int64_t work = 0;
  const std::string_view text(argv[1]);
  const auto parsed =
      std::from_chars(text.data(), text.data() + text.size(), work);
  if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
    return 1;
  }
  return work > 0 ? static_cast<std::uint64_t>(work) : 0;
}

std::uint64_t one_repetition() {
  std::vector<std::uint8_t> output;
  output.reserve(kOutputSize);
  for (std::size_t i = 0; i < kAppendsPerRepetition; ++i) {
    output.insert(output.end(), kChunk.begin(), kChunk.end());
  }
  return output.size() + (output.empty() ? 0 : 1);
}
}  // namespace

int main(int argc, char** argv) {
  const std::uint64_t work = parse_work(argc, argv);
  std::uint64_t checksum = 0;
  for (std::uint64_t rep = 0; rep < work; ++rep) {
    checksum =
        (checksum * kChecksumMultiplier + one_repetition()) % kChecksumModulus;
  }
  std::cout << checksum << '\n';
}
