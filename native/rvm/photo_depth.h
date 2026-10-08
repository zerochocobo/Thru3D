#pragma once

namespace quest {
// Still-image normalization. Only the content rectangle contributes to the band or
// foreground dilation; the surrounding padding is extended from its nearest content
// pixel so linear sampling cannot pull artificial depth into the picture's edges.
// Constant/invalid depth stays on the screen plane. Throws for an invalid rectangle.
void photo_near_map(const float* inverse, int width, int height,
                    int x, int y, int content_width, int content_height, float* near);
}
