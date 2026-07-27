#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

std::vector<unsigned char> read_all(const std::string& path) {
  std::ifstream source(path, std::ios::binary | std::ios::ate);
  if (!source) {
    throw std::runtime_error("cannot open fixture: " + path);
  }
  const auto end = source.tellg();
  if (end < 0) {
    throw std::runtime_error("cannot determine fixture size");
  }
  std::vector<unsigned char> data(static_cast<std::size_t>(end));
  source.seekg(0);
  if (!source.read(reinterpret_cast<char*>(data.data()), end)) {
    throw std::runtime_error("failed while reading fixture");
  }
  return data;
}

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "usage: whole_read REPETITIONS FIXTURE\n";
    return 2;
  }
  try {
    const int repetitions = std::stoi(argv[1]);
    if (repetitions <= 0) {
      throw std::runtime_error("repetitions must be positive");
    }
    std::uint64_t total_bytes = 0;
    std::uint64_t checksum = 0;
    for (int i = 0; i < repetitions; ++i) {
      const auto data = read_all(argv[2]);
      total_bytes += data.size();
      checksum += data.size();
      checksum += data.front() + data.back();
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
