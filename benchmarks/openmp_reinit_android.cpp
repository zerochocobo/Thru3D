// Isolate NDK OpenMP root-thread teardown from RVM/model/Godot code.
// Build with the locked Android NDK, -fopenmp -static-openmp -static-libstdc++.
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <omp.h>
extern "C" void kmp_set_defaults(const char*);

int main(int argc, char** argv) {
    if (argc != 2 || (std::strcmp(argv[1], "roots") &&
        std::strcmp(argv[1], "persistent") && std::strcmp(argv[1], "defaults"))) return 2;
    setenv("KMP_AFFINITY", "disabled", 1); // same as ncnn's initializer
    auto parallel = [](int iteration) {
        std::atomic<int> count{0};
        #pragma omp parallel num_threads(4)
        count.fetch_add(1);
        std::printf("iteration=%d threads=%d\n", iteration, count.load());
        std::fflush(stdout);
        if (count.load() != 4) std::abort();
    };
    if (!std::strcmp(argv[1], "persistent")) {
        std::thread root([&] { for (int i = 0; i != 3; ++i) parallel(i); });
        root.join();
    } else {
        for (int i = 0; i != 3; ++i) {
            std::thread root([&] {
                if (!std::strcmp(argv[1], "defaults")) kmp_set_defaults("KMP_AFFINITY=disabled");
                parallel(i);
            });
            root.join();
        }
    }
    return 0;
}
