// Minimal public-API driver for the DDS reproducer.
//
// This follows the same path as an application opening an untrusted image:
// ImageInput::open(path), then read_image() in the file's native format. It
// does not include private headers or call a plugin-internal function.

#include <OpenImageIO/imageio.h>

#include <cstdio>
#include <memory>
#include <vector>

int
main(int argc, char** argv)
{
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s <imagefile>\n", argv[0]);
        return 2;
    }

    auto input = OIIO::ImageInput::open(argv[1]);
    if (!input) {
        std::printf("[harness] open failed: %s\n", OIIO::geterror().c_str());
        return 1;
    }

    const OIIO::ImageSpec& spec = input->spec();
    std::printf("[harness] subimage 0: %dx%dx%d nchans=%d format=%s\n",
                spec.width, spec.height, spec.depth, spec.nchannels,
                spec.format.c_str());

    const size_t size = static_cast<size_t>(spec.image_bytes());
    std::printf("[harness] allocating %zu bytes for read_image()\n", size);
    std::vector<unsigned char> pixels(size ? size : 1);

    const bool ok = input->read_image(0, 0, 0, spec.nchannels, spec.format,
                                      pixels.data());
    if (!ok) {
        std::printf("[harness] read_image failed: %s\n",
                    input->geterror().c_str());
    } else {
        std::printf("[harness] read_image ok (%zu bytes)\n", size);
    }
    input->close();
    return ok ? 0 : 1;
}
