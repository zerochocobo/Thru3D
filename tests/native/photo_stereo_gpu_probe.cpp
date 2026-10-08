// Compile for Quest and run as a standalone process; executes the production video/photo shaders.
#include "../../native/render-bridge/render_bridge.cpp"
#include <fstream>
#include <iostream>

int main(int argc, char** argv) {
    try {
        const int w = 512, h = 96;
        std::vector<unsigned char> color(w*h*4), output(w*h*8);
        std::vector<float> depth(w*h, .35f);
        for (int y=0; y<h; ++y) for (int x=0; x<w; ++x) {
            const size_t i=(y*w+x)*4;
            color[i]=static_cast<unsigned char>(40+x%160);
            color[i+1]=static_cast<unsigned char>(20+y*2);
            color[i+2]=90; color[i+3]=255;
        }
        PhotoEgl owner; const auto context=eglGetCurrentContext();
        photo_stereo(color.data(),w,h,depth.data(),w,h,{{0,0,1,1}},0,output.data());
        if (eglGetCurrentContext()!=context) throw std::runtime_error("Worker EGL did not restore its caller");
        for (int y=0; y<h; ++y) for (int eye=0; eye<2; ++eye) for (int x=0; x<w; ++x) for (int c=0; c<4; ++c)
            if (output[(y*w*2+eye*w+x)*4+c]!=color[(y*w+x)*4+c]) throw std::runtime_error("Zero strength changed pixels, eye packing or row/channel order");
        photo_stereo(color.data(),w,h,depth.data(),w,h,{{0,0,1,1}},2,output.data());
        for (int y=0; y<h; ++y) for (int eye=0; eye<2; ++eye) for (int x=0; x<w; ++x) for (int c=0; c<4; ++c)
            if (output[(y*w*2+eye*w+x)*4+c]!=color[(y*w+x)*4+c]) throw std::runtime_error("Screen-plane depth introduced stereo disparity");
        std::fill(depth.begin(),depth.end(),.05f);
        for (int y=0; y<h; ++y) for (int x=192; x<320; ++x) {
            depth[y*w+x]=.95f;
            color[(y*w+x)*4]=240; color[(y*w+x)*4+1]=10; color[(y*w+x)*4+2]=30;
        }
        photo_stereo(color.data(),w,h,depth.data(),w,h,{{0,0,1,1}},1,output.data());
        int left=-1,right=-1;
        for (int x=170; x<220; ++x) {
            if (left<0 && output[(48*w*2+x)*4]>230) left=x;
            if (right<0 && output[(48*w*2+w+x)*4]>230) right=x;
        }
        if (left<=right || left<192 || right>192 || left-right<8) throw std::runtime_error("Foreground eye order or z-buffer disparity incorrect");
        for (size_t i=0; i<output.size(); i+=4) if (output[i]+output[i+1]+output[i+2]<25 || output[i+3]!=255)
            throw std::runtime_error("Unfilled/transparent hole in the generated stereo pair");
        bool rejected=false;
        try { photo_stereo(color.data(),w,h,depth.data(),w,h,{{0,0,1,1}},3,output.data()); }
        catch (const std::exception&) { rejected=true; }
        if (!rejected || eglGetCurrentContext()!=context) throw std::runtime_error("Invalid input altered caller context");
        if (argc>1) std::ofstream(argv[1],std::ios::binary).write(reinterpret_cast<char*>(output.data()),static_cast<std::streamsize>(output.size()));
        std::cout << "{\"state\":\"passed\",\"width\":512,\"height\":96,\"left_edge\":" << left
                  << ",\"right_edge\":" << right << ",\"strategy\":\"production_video_soft_shift_gpu\"}\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
