#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

int one_scope(const std::string& path) {
  std::ifstream source(path, std::ios::binary);
  if (!source) {
    throw std::runtime_error("cannot open fixture: " + path);
  }
  char octet = 0;
  source.read(&octet, 1);
  if (source.gcount() != 1) {
    throw std::runtime_error("fixture did not contain one byte");
  }
  return 1;
}

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "usage: scope SCOPES FIXTURE\n";
    return 2;
  }
  try {
    const int scopes = std::stoi(argv[1]);
    if (scopes <= 0) {
      throw std::runtime_error("scope count must be positive");
    }
    int checksum = 0;
    for (int i = 0; i < scopes; ++i) {
      checksum += one_scope(argv[2]);
    }
    std::cout << "scopes=" << scopes
              << " bytes=" << checksum
              << " checksum=" << checksum << '\n';
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
