// Offline 2D->3D tool: runs the device's near-map stabilizer over a sequence of model outputs.
// Usage: depth_stabilizer_cli <dir> <width> <height> <count> [dilate=1]
// Reads <dir>/inv_NNN.bin (float32 HxW inverse depth) and <dir>/rgb_NNN.bin (float32 CHW in [0,1])
// with step_NNN.txt optional (source frames since the previous input, default 1); writes near_NNN.bin.
// Build: tools/Test-DepthStabilizer.ps1 -Cli
#include "../../native/rvm/depth_stabilizer.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

static bool read_file(const std::string& path, std::vector<float>& data) {
    FILE* file = std::fopen(path.c_str(), "rb");
    if (!file) return false;
    const size_t got = std::fread(data.data(), sizeof(float), data.size(), file);
    std::fclose(file);
    return got == data.size();
}

int main(int argc, char** argv) {
    if (argc < 5) { std::fprintf(stderr, "usage: %s dir width height count\n", argv[0]); return 2; }
    const std::string dir = argv[1];
    const int w = std::atoi(argv[2]), h = std::atoi(argv[3]), count = std::atoi(argv[4]);
    const size_t n = static_cast<size_t>(w) * h;
    quest::DepthStabilizer stabilizer(w, h);
    if (argc > 5) stabilizer.set_dilation(std::atoi(argv[5]));
    std::vector<float> inv(n), rgb(3 * n), near(n);
    char name[64];
    for (int i = 0; i < count; ++i) {
        std::snprintf(name, sizeof(name), "/inv_%03d.bin", i);
        if (!read_file(dir + name, inv)) { std::fprintf(stderr, "missing %s\n", name); return 1; }
        std::snprintf(name, sizeof(name), "/rgb_%03d.bin", i);
        if (!read_file(dir + name, rgb)) { std::fprintf(stderr, "missing %s\n", name); return 1; }
        int step = 1;
        std::snprintf(name, sizeof(name), "/step_%03d.txt", i);
        if (FILE* file = std::fopen((dir + name).c_str(), "r")) { if (std::fscanf(file, "%d", &step) != 1) step = 1; std::fclose(file); }
        stabilizer.process(inv.data(), rgb.data(), step, near.data());
        std::snprintf(name, sizeof(name), "/near_%03d.bin", i);
        FILE* out = std::fopen((dir + name).c_str(), "wb");
        if (!out) return 1;
        std::fwrite(near.data(), sizeof(float), n, out);
        std::fclose(out);
    }
    std::printf("stabilized %d frames, cuts %llu\n", count, static_cast<unsigned long long>(stabilizer.cuts()));
    return 0;
}
