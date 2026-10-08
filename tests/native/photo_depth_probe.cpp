// Standalone Android probe of the production Depth class, model placement and normalization.
// No app installation or XR session. Android Bitmap/EXIF and subjective stereo are not tested.
#include "../../native/rvm/depth_runtime_jni.cpp"
#include <fstream>
#include <sys/resource.h>

int main(int argc, char** argv) {
    if (argc != 10) {
        std::fprintf(stderr,"usage: photo_depth_probe model rgb.bin near.bin cache x y cw ch photo\n");
        return 2;
    }
    try {
        std::ifstream file(argv[1],std::ios::binary);
        std::vector<char> model((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        require(!model.empty(),"Missing model");
        const bool photo = std::atoi(argv[9]) != 0;
        Depth depth(model.data(),model.size(),argv[4],photo);
        const size_t n = static_cast<size_t>(depth.width)*depth.height;
        std::vector<float> rgb(n*3), near(n);
        std::ifstream input(argv[2],std::ios::binary);
        input.read(reinterpret_cast<char*>(rgb.data()),static_cast<std::streamsize>(rgb.size()*4));
        require(static_cast<size_t>(input.gcount())==rgb.size()*4,"RGB length differs");
        for(float value : rgb) require(std::isfinite(value) && value>=0 && value<=1,"Invalid RGB");
        std::vector<double> times;
        for(int run=0;run<3;++run) {
            if(photo) depth.process_photo(rgb.data(),near.data(),std::atoi(argv[5]),std::atoi(argv[6]),std::atoi(argv[7]),std::atoi(argv[8]));
            else depth.process(rgb.data(),near.data(),true,1);
            for(float value : near) require(std::isfinite(value) && value>=0 && value<=1,"Invalid depth");
            times.push_back(depth.last_ms);
        }
        std::ofstream output(argv[3],std::ios::binary);
        output.write(reinterpret_cast<const char*>(near.data()),static_cast<std::streamsize>(near.size()*4));
        require(output.good(),"Could not write near map");
        struct rusage usage{}; getrusage(RUSAGE_SELF,&usage);
        std::printf("{\"state\":\"ready\",\"width\":%d,\"height\":%d,\"gpu_ops\":%d,\"cpu_fallback_ops\":%zu,\"prepare_ms\":%.3f,\"runs_ms\":[%.3f,%.3f,%.3f],\"max_rss_kb\":%ld}\n",
            depth.width,depth.height,depth.gpu_ops,depth.host_ops.size(),depth.prepare_ms,times[0],times[1],times[2],usage.ru_maxrss);
        return 0;
    } catch (const std::exception& error) { std::fprintf(stderr,"Photo depth probe failed: %s\n",error.what()); return 1; }
}
