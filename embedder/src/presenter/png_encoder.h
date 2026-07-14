#ifndef PLUTO_PRESENTER_PNG_ENCODER_H_
#define PLUTO_PRESENTER_PNG_ENCODER_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "pluto/presenter.h"

namespace pluto {

// Encodes one tightly described presenter surface as an 8-bit RGBA PNG.
// The encoder deliberately uses stored DEFLATE blocks so device builds need
// no additional image or compression libraries.
bool encode_png(const std::uint8_t *pixels, std::int32_t width,
                std::int32_t height, std::size_t stride,
                PlutoPixelFormat format, std::vector<std::uint8_t> *out,
                std::string *error = nullptr);

} // namespace pluto

#endif // PLUTO_PRESENTER_PNG_ENCODER_H_
