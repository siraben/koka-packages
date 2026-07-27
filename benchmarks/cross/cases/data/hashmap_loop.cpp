#include <charconv>
#include <cstdint>
#include <iostream>
#include <string_view>
#include <system_error>
#include <unordered_map>

namespace {
constexpr std::int64_t kValueModulus = 1000003;

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
}  // namespace

int main(int argc, char** argv) {
  const std::uint64_t work = parse_work(argc, argv);
  std::unordered_map<std::uint64_t, std::int64_t> entries;
  entries.reserve(static_cast<std::size_t>(work));
  for (std::uint64_t i = 0; i < work; ++i) {
    entries.emplace(i, static_cast<std::int64_t>((17 * i + 3) % kValueModulus));
  }

  std::int64_t checksum = 0;
  for (std::uint64_t i = work; i > 0; --i) {
    const auto found = entries.find(i - 1);
    if (found != entries.end()) checksum += found->second;
  }
  std::cout << checksum << '\n';
}
