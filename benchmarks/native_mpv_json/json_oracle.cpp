#include "../../native/mpv/json_quote.h"
#include <fstream>
#include <iostream>
#include <stdexcept>

int main(int argc, char** argv) {
    try {
        if (argc != 2) throw std::runtime_error("Input fixture path required");
        std::ifstream file(argv[1]);
        if (!file) throw std::runtime_error("Input fixture unavailable");
        std::string hex;
        while (std::getline(file, hex)) {
            if (hex.size() % 2) throw std::runtime_error("Odd hex input");
            std::string input;
            for (size_t i = 0; i < hex.size(); i += 2)
                input += static_cast<char>(std::stoi(hex.substr(i, 2), nullptr, 16));
            std::cout << quest::json_quote(input) << '\n';
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
