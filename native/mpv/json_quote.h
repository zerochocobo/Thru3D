#pragma once
#include <cstdint>
#include <string>

namespace quest {
// ASCII JSON also satisfies JNI NewStringUTF's modified UTF-8 contract.
// Escape supplementary characters as a UTF-16 pair, preserving subtitle emoji.
inline std::string json_quote(const std::string& value) {
    std::string out = "\"";
    const char* digits = "0123456789abcdef";
    auto unit = [&](uint32_t cp) {
        out += "\\u";
        for (int shift = 12; shift >= 0; shift -= 4) out += digits[(cp >> shift) & 15];
    };
    for (size_t i = 0; i < value.size();) {
        const auto first = static_cast<unsigned char>(value[i]);
        if (first < 128) {
            ++i;
            if (first == '"' || first == '\\') { out += '\\'; out += static_cast<char>(first); }
            else if (first < 32) unit(first);
            else out += static_cast<char>(first);
            continue;
        }
        const int bytes = first >= 0xc2 && first <= 0xdf ? 2 :
                          (first >= 0xe0 && first <= 0xef ? 3 : (first >= 0xf0 && first <= 0xf4 ? 4 : 0));
        uint32_t cp = bytes == 2 ? first & 31 : (bytes == 3 ? first & 15 : first & 7);
        bool valid = bytes > 0 && i+bytes <= value.size();
        for (int j = 1; valid && j < bytes; ++j) {
            const auto next = static_cast<unsigned char>(value[i+j]);
            if ((next & 0xc0) != 0x80) valid = false;
            else cp = (cp << 6) | (next & 63);
        }
        if (!valid || (bytes == 2 && cp < 0x80) || (bytes == 3 && cp < 0x800) ||
            (bytes == 4 && cp < 0x10000) || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) {
            unit(0xfffd); ++i; continue;
        }
        i += bytes;
        if (cp <= 0xffff) unit(cp);
        else { cp -= 0x10000; unit(0xd800+(cp >> 10)); unit(0xdc00+(cp & 1023)); }
    }
    return out + '"';
}
}
