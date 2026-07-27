#include <charconv>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string_view>
#include <system_error>
#include <vector>

namespace {
constexpr std::size_t kSegmentSize = 32768;
constexpr std::size_t kSegmentCount = 256;
constexpr std::size_t kInputSize = kSegmentSize * kSegmentCount;
constexpr std::uint64_t kChecksumMultiplier = 1000003;
constexpr std::uint64_t kChecksumModulus = 1000000007;
constexpr std::uint8_t kDelimiter = '|';

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

std::vector<std::uint8_t> make_input() {
  std::vector<std::uint8_t> segment(kSegmentSize, 'a');
  segment.back() = kDelimiter;
  std::vector<std::uint8_t> input;
  input.reserve(kInputSize);
  for (std::size_t i = 0; i < kSegmentCount; ++i) {
    input.insert(input.end(), segment.begin(), segment.end());
  }
  return input;
}

std::uint64_t scan(const std::vector<std::uint8_t>& input) {
  std::size_t from = 0;
  std::uint64_t total = 0;
  while (from < input.size()) {
    const void* found =
        std::memchr(input.data() + from, kDelimiter, input.size() - from);
    if (found == nullptr) break;
    const auto* position = static_cast<const std::uint8_t*>(found);
    const std::size_t index =
        static_cast<std::size_t>(position - input.data());
    total += index + 1;
    from = index + 1;
  }
  return total;
}
}  // namespace

int main(int argc, char** argv) {
  const std::uint64_t work = parse_work(argc, argv);
  const std::vector<std::uint8_t> input = make_input();
  std::uint64_t checksum = 0;
  for (std::uint64_t rep = 0; rep < work; ++rep) {
    checksum = (checksum * kChecksumMultiplier + scan(input)) % kChecksumModulus;
  }
  std::cout << checksum << '\n';
}
