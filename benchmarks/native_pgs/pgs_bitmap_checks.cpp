#include "../../native/mpv/pgs_bitmap.h"
#include <iostream>
#include <string>

int main() {
    int checks = 0;
    auto check = [&](bool ok) { if (!ok) throw std::runtime_error("PGS pixel check " + std::to_string(checks)); ++checks; };
    const uint8_t padded[] = {0,0,128,128, 255,0,0,255, 9,9,9,9,
                              0,128,0,128, 0,0,0,0, 9,9,9,9};
    quest_mpv_pgs_part part{padded,12,2,2, 3,5,2,2};
    quest_mpv_pgs_frame frame{10,10,9,1,1,&part};
    auto image = quest::compose_pgs(frame);
    check(image.x == 3 && image.y == 5 && image.width == 2 && image.height == 2);
    check(image.rgba == std::vector<uint8_t>({128,0,0,128, 0,0,255,255, 0,128,0,128, 0,0,0,0}));
    part.x = -1; part.y = -1;
    image = quest::compose_pgs(frame);
    check(image.width == 1 && image.height == 1 && image.rgba == std::vector<uint8_t>({0,0,0,0}));
    const uint8_t red[] = {0,0,128,128};
    const uint8_t blue[] = {128,0,0,128};
    quest_mpv_pgs_part overlap[] = {{blue,4,1,1,0,0,1,1}, {red,4,1,1,0,0,1,1}};
    frame = {2,2,1,1,2,overlap};
    image = quest::compose_pgs(frame);
    check(image.rgba == std::vector<uint8_t>({128,0,64,192}));
    part = {padded,12,2,2,0,0,1,1}; frame = {2,2,1,1,1,&part};
    image = quest::compose_pgs(frame);
    check(image.rgba == std::vector<uint8_t>({32,32,64,128}));
    frame.num_parts = 0;
    check(quest::compose_pgs(frame).rgba.empty());
    frame.num_parts = 1; part.x = 10; part.y = 10;
    check(quest::compose_pgs(frame).rgba.empty());
    part.x = 0; part.y = 0; part.stride = 1;
    bool rejected = false;
    try { quest::compose_pgs(frame); } catch (const std::exception&) { rejected = true; }
    check(rejected);
    std::cout << "PGS crop/palette/alpha/stride/scale/clipping checks passed: " << checks << '\n';
}
