// Create a small cropped frame on a large canvas using exported libjxl APIs.
// The 32-bit djxl CLI must allocate a PackedImage for the entire canvas.
#include <jxl/color_encoding.h>
#include <jxl/encode.h>
#include <jxl/types.h>

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static void Check(bool ok, const char* label) {
  if (!ok) {
    fprintf(stderr, "%s failed\n", label);
    std::exit(1);
  }
}

int main(int argc, char** argv) {
  if (argc != 6) {
    fprintf(stderr, "usage: %s OUTPUT CANVAS_W CANVAS_H FRAME_X FRAME_Y\n",
            argv[0]);
    return 2;
  }
  unsigned canvas_w = std::strtoul(argv[2], nullptr, 10);
  unsigned canvas_h = std::strtoul(argv[3], nullptr, 10);
  int frame_x = std::atoi(argv[4]);
  int frame_y = std::atoi(argv[5]);

  std::vector<uint8_t> pixels(8 * 8 * 3);
  for (unsigned y = 0; y < 8; ++y) {
    for (unsigned x = 0; x < 8; ++x) {
      unsigned pos = (y * 8 + x) * 3;
      pixels[pos] = (x * 17 + y * 29) & 255;
      pixels[pos + 1] = (x * 31 + y * 7) & 255;
      pixels[pos + 2] = (x * 3 + y * 47) & 255;
    }
  }

  JxlEncoder* encoder = JxlEncoderCreate(nullptr);
  Check(encoder != nullptr, "JxlEncoderCreate");
  JxlBasicInfo info;
  JxlEncoderInitBasicInfo(&info);
  info.xsize = canvas_w;
  info.ysize = canvas_h;
  info.bits_per_sample = 8;
  info.num_color_channels = 3;
  info.uses_original_profile = JXL_TRUE;
  Check(JxlEncoderSetCodestreamLevel(encoder, 10) == JXL_ENC_SUCCESS,
        "JxlEncoderSetCodestreamLevel");
  Check(JxlEncoderSetBasicInfo(encoder, &info) == JXL_ENC_SUCCESS,
        "JxlEncoderSetBasicInfo");
  JxlColorEncoding color;
  JxlColorEncodingSetToSRGB(&color, JXL_FALSE);
  Check(JxlEncoderSetColorEncoding(encoder, &color) == JXL_ENC_SUCCESS,
        "JxlEncoderSetColorEncoding");

  JxlEncoderFrameSettings* settings = JxlEncoderFrameSettingsCreate(encoder, nullptr);
  Check(settings != nullptr, "JxlEncoderFrameSettingsCreate");
  Check(JxlEncoderSetFrameLossless(settings, JXL_TRUE) == JXL_ENC_SUCCESS,
        "JxlEncoderSetFrameLossless");
  Check(JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, 1)
            == JXL_ENC_SUCCESS, "JXL_ENC_FRAME_SETTING_EFFORT");
  JxlFrameHeader frame;
  JxlEncoderInitFrameHeader(&frame);
  frame.layer_info.have_crop = JXL_TRUE;
  frame.layer_info.xsize = 8;
  frame.layer_info.ysize = 8;
  frame.layer_info.crop_x0 = frame_x;
  frame.layer_info.crop_y0 = frame_y;
  Check(JxlEncoderSetFrameHeader(settings, &frame) == JXL_ENC_SUCCESS,
        "JxlEncoderSetFrameHeader");
  JxlPixelFormat format = {3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
  Check(JxlEncoderAddImageFrame(settings, &format, pixels.data(), pixels.size())
            == JXL_ENC_SUCCESS, "JxlEncoderAddImageFrame");
  JxlEncoderCloseInput(encoder);

  std::vector<uint8_t> compressed(4096);
  uint8_t* next = compressed.data();
  size_t available = compressed.size();
  JxlEncoderStatus status;
  while ((status = JxlEncoderProcessOutput(encoder, &next, &available))
         == JXL_ENC_NEED_MORE_OUTPUT) {
    size_t used = next - compressed.data();
    compressed.resize(compressed.size() * 2);
    next = compressed.data() + used;
    available = compressed.size() - used;
  }
  Check(status == JXL_ENC_SUCCESS, "JxlEncoderProcessOutput");
  compressed.resize(next - compressed.data());
  FILE* out = fopen(argv[1], "wb");
  Check(out != nullptr, "fopen");
  Check(fwrite(compressed.data(), 1, compressed.size(), out) == compressed.size(),
        "fwrite");
  Check(fclose(out) == 0, "fclose");
  fprintf(stderr, "wrote %zu bytes, canvas=%ux%u, frame=(%d,%d)+8x8\n",
          compressed.size(), canvas_w, canvas_h, frame_x, frame_y);
  JxlEncoderDestroy(encoder);
}
