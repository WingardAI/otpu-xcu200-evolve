// Phase 3 smoke test: load OtpuCoreKernel and read its control/CFG registers.
#include <cstdio>
#include <cstdint>
#include <string>
#include <xrt/xrt_device.h>
#include <experimental/xrt_xclbin.h>
#include <xrt/xrt_bo.h>
#include <experimental/xrt_ip.h>

int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: %s <xclbin>\n", argv[0]); return 2; }
  try {
    xrt::device dev(0);
    auto uuid = dev.load_xclbin(argv[1]);
    std::string name;
    for (auto& k : xrt::xclbin(argv[1]).get_kernels()) {
      if (k.get_name().find("OtpuCoreKernel") != std::string::npos) name = k.get_name();
    }
    if (name.empty()) { std::fprintf(stderr, "no OtpuCoreKernel\n"); return 1; }
    std::printf("IP: %s\n", name.c_str());
    xrt::ip ip(dev, uuid, name);
    auto rd = [&](uint32_t o) { return ip.read_register(o); };
    std::printf("ID=0x%08x VERSION=%u CTRL=0x%x STATUS=0x%x\n",
                rd(0x00), rd(0x04), rd(0x08), rd(0x0C));
    std::printf("REGMAP=0x%x CAPS=0x%08x CORE_KHZ=%u BUILD_ID=0x%08x\n",
                rd(0x3C), rd(0x40), rd(0x44), rd(0x48));
    std::printf("CFG_SLICES=%u TMEM=%u IMEM=%u ACT=%u\n",
                rd(0x80), rd(0x84), rd(0x88), rd(0x8C));
    std::printf("CFG_DRAM=0x%x UARCH=0x%x PLATFORM=%u HASH=0x%x\n",
                rd(0x90), rd(0x94), rd(0x98), rd(0x9C));
    const uint32_t id = rd(0x00);
    if (id != 0x4f545055u) { std::fprintf(stderr, "unexpected ID\n"); return 1; }
    std::printf("PASS: core kernel control/CFG readable\n");
    return 0;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "XRT error: %s\n", e.what());
    return 1;
  }
}
