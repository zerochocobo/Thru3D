#include "../../native/rvm/photo_depth.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <stdexcept>
#include <vector>

int main() {
    int failures = 0, checks = 0;
    auto check = [&](bool ok, const char* name) { ++checks; if (!ok) { ++failures; std::fprintf(stderr, "%s\n", name); } };
    for (bool portrait : {false, true}) {
        const int w = 518, h = 518, x = portrait ? 76 : 0, y = portrait ? 0 : 76;
        const int cw = portrait ? 366 : w, ch = portrait ? h : 366;
        std::vector<float> a(w*h, -10000.f), b(w*h, 10000.f), na(w*h), nb(w*h);
        for (int row = y; row < y+ch; ++row) for (int col = x; col < x+cw; ++col)
            a[row*w+col] = b[row*w+col] = 1.f + static_cast<float>(col-x) / (cw-1);
        quest::photo_near_map(a.data(),w,h,x,y,cw,ch,na.data());
        quest::photo_near_map(b.data(),w,h,x,y,cw,ch,nb.data());
        check(na == nb, "Changing only padding must not alter normalization or dilation");
        check(na[(y+ch/2)*w+x] < .01f && na[(y+ch/2)*w+x+cw-1] > .99f, "Content must retain its full near/far range");
        check(std::all_of(na.begin(),na.end(),[](float v) { return std::isfinite(v) && v>=0 && v<=1; }), "Finite bounded output");
        bool extended = true;
        for (int row=0;row<h;++row) for(int col=0;col<w;++col)
            if (row<y || row>=y+ch || col<x || col>=x+cw)
                extended &= na[row*w+col] == na[std::clamp(row,y,y+ch-1)*w+std::clamp(col,x,x+cw-1)];
        check(extended,"Padding must replicate the content edge for linear sampling");
        // Constant or invalid content remains on the screen, regardless of arbitrary padding.
        for (float value : {2.f, std::numeric_limits<float>::quiet_NaN()}) {
            for(int row=y;row<y+ch;++row) for(int col=x;col<x+cw;++col) a[row*w+col]=value;
            quest::photo_near_map(a.data(),w,h,x,y,cw,ch,na.data());
            check(std::all_of(na.begin(),na.end(),[](float v) { return v==.35f; }),"Flat/invalid photo must be neutral");
        }
        bool rejected = false;
        try { quest::photo_near_map(a.data(),w,h,x,y,w+1,ch,na.data()); }
        catch(const std::invalid_argument&) { rejected=true; }
        check(rejected,"Reject out-of-bounds content before reading buffers");
        quest::photo_near_map(a.data(),w,h,0,0,1,1,na.data());
        check(na[0]==.35f,"Tiny content remains bounded and neutral");
    }
    std::printf("Photo depth normalization: %d checks, %d failures\n",checks,failures);
    return failures ? 1 : 0;
}
