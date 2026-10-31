// New in the XCU200 port (WingardAI, 2026) for openTPU,
// https://github.com/FeSens/openTPU (Apache-2.0). See NOTICE.

// Phase 1 host test for the openTPU U200 kernel.
//
//   source /opt/xilinx/xrt/setup.sh
//   g++ -std=c++17 -O2 -I/opt/xilinx/xrt/include host/test_control.cpp \
//       -L/opt/xilinx/xrt/lib -Wl,-rpath,/opt/xilinx/xrt/lib -lxrt_coreutil -luuid -lpthread \
//       -o test_control
//   ./test_control OtpuKernel.xclbin
//
// It loads the xclbin, reads otpu_ctrl's ID/CFG_PLATFORM through xrt::ip (0x100/0x198), allocates
// a 4 KiB xrt::bo in memory group 1, has the kernel write 1 KiB of {16{pattern}} through its
// m_axi_bank_0 master, reads it back, and checks the scratch status.
#include <experimental/xrt_ip.h>
#include <experimental/xrt_xclbin.h>
#include <xrt/xrt_bo.h>
#include <xrt/xrt_device.h>
#include <xrt/xrt_uuid.h>
#include <xclhal2.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <OtpuKernel.xclbin>\n", argv[0]);
    return 2;
  }
  const char* xclbin = argv[1];

  try {
    xrt::device dev(0);
    auto uuid = dev.load_xclbin(xclbin);

    xrt::xclbin xc(xclbin);
    std::string ip_name;
    for (const auto& ip : xc.get_ips()) {
      const std::string n = ip.get_name();
      if (n.rfind("OtpuKernel", 0) == 0) ip_name = n;
    }
    if (ip_name.empty()) {
      std::fprintf(stderr, "no OtpuKernel IP in %s\n", xclbin);
      return 1;
    }
    std::printf("IP: %s\n", ip_name.c_str());

    xrt::ip ip(dev, uuid, ip_name);

    constexpr uint32_t kBase = 0x10;   // MemBase0 low/high
    constexpr uint32_t kCtrl = 0x18;
    constexpr uint32_t kStat = 0x1C;
    constexpr uint32_t kPat = 0x20;
    constexpr uint32_t kId = 0x100;    // otpu_ctrl R_ID
    constexpr uint32_t kPlat = 0x198;  // otpu_ctrl R_CFG_PLATFORM (0x100 + 0x98)

    const uint32_t id = ip.read_register(kId);
    const uint32_t plat = ip.read_register(kPlat);
    std::printf("otpu_ctrl ID=0x%08x CFG_PLATFORM=%u\n", id, plat);

    xrt::bo bo(dev, 4096, 1);  // memory group 1 (the m_axi_bank_0 bank)
    auto* p = bo.map<char*>();
    std::memset(p, 0, 4096);
    bo.sync(XCL_BO_SYNC_BO_TO_DEVICE);
    const uint64_t addr = bo.address();
    std::printf("BO address=0x%llx\n", static_cast<unsigned long long>(addr));

    const uint32_t pattern = 0xDEADBEEFu;
    ip.write_register(kBase + 0, static_cast<uint32_t>(addr));
    ip.write_register(kBase + 4, static_cast<uint32_t>(addr >> 32));
    ip.write_register(kPat, pattern);
    ip.write_register(kCtrl, 1);

    uint32_t status = 0;
    for (int i = 0; i < 2000000; ++i) {
      status = ip.read_register(kStat);
      if (status & 1) break;
    }
    std::printf("scratch status=0x%08x (done=%u error=%u)\n", status, status & 1,
                (status >> 1) & 1);

    bo.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
    bool data_ok = true;
    for (int i = 0; i < 1024 / 4; ++i) {
      uint32_t v;
      std::memcpy(&v, p + 4 * i, 4);
      if (v != pattern) {
        data_ok = false;
        std::printf("mismatch at word %d: 0x%08x != 0x%08x\n", i, v, pattern);
        break;
      }
    }

    const bool ok = (status & 1) && !(status & 2) && data_ok && id == 0x4F545055u &&
                    plat == 4u;
    std::printf("id_ok=%d platform_ok=%d data_ok=%d -> %s\n", id == 0x4F545055u,
                plat == 4u, data_ok, ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "XRT error: %s\n", e.what());
    return 1;
  }
}
