#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

constexpr std::size_t chunk_size = 65536;

std::pair<std::uint64_t, std::uint64_t> one_pass(const std::string& path) {
  std::ifstream source(path, std::ios::binary);
  if (!source) {
    throw std::runtime_error("cannot open fixture: " + path);
  }

  std::array<unsigned char, chunk_size> buffer{};
  std::uint64_t seen = 0;
  std::uint64_t checksum = 0;
  while (source.read(reinterpret_cast<char*>(buffer.data()), buffer.size()) ||
         source.gcount() != 0) {
    const auto count = static_cast<std::size_t>(source.gcount());
    if (count != 0) {
      checksum += count;
      checksum += buffer.front() + buffer[count - 1];
    }
    seen += count;
  }
  if (!source.eof()) {
    throw std::runtime_error("failed while reading fixture");
  }
  return {seen, checksum};
}

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "usage: stream_cpp REPETITIONS FIXTURE\n";
    return 2;
  }
  try {
    const int repetitions = std::stoi(argv[1]);
    if (repetitions <= 0) {
      throw std::runtime_error("repetitions must be positive");
    }
    const std::string path = argv[2];
    std::uint64_t total_bytes = 0;
    std::uint64_t checksum = 0;
    for (int i = 0; i < repetitions; ++i) {
      const auto [seen, partial] = one_pass(path);
      total_bytes += seen;
      checksum += partial;
    }
    if (total_bytes % static_cast<std::uint64_t>(repetitions) != 0) {
      throw std::runtime_error("inconsistent byte count");
    }
    std::cout << "bytes=" << total_bytes / repetitions
              << " reps=" << repetitions
              << " checksum=" << checksum << '\n';
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
