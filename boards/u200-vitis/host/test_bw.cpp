// New in the XCU200 port (WingardAI, 2026) for openTPU,
// https://github.com/FeSens/openTPU (Apache-2.0). See NOTICE.

// On-card bandwidth test for the otpu_axi_dram bridge in OtpuKernel.
//
//   g++ -std=c++17 -O2 -I/opt/xilinx/xrt/include host/test_bw.cpp \
//       -L/opt/xilinx/xrt/lib -Wl,-rpath,/opt/xilinx/xrt/lib -lxrt_coreutil -luuid -lpthread \
//       -o test_bw
//   ./test_bw OtpuKernel.xclbin
//
// Allocates a 256 MiB BO in memory group 1 (DDR[1]), sets MemBase0, BwMode=1 and runs the read
// traffic generator for several beat counts. BwCycles is in ap_clk (300 MHz) cycles; the
// sustained rate is BwBeats*64 / (BwCycles/300e6). Peak of the DDR4-2400 channel: 19.2 GB/s
// (64 B per cycle at 300 MHz), so GB/s / 19.2 = BwBeats/BwCycles.
#include <experimental/xrt_ip.h>
#include <experimental/xrt_xclbin.h>
#include <xrt/xrt_bo.h>
#include <xrt/xrt_device.h>
#include <xrt/xrt_uuid.h>
#include <xclhal2.h>

#include <cstdint>
#include <cstdio>
#include <thread>
#include <chrono>
#include <cstring>
#include <string>
#include <vector>

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

    constexpr uint32_t kBaseLo = 0x10, kBaseHi = 0x14;
    constexpr uint32_t kCtrl = 0x24, kN = 0x28, kStart = 0x2C;
    constexpr uint32_t kStatus = 0x30, kCycles = 0x34, kBeats = 0x38, kMode = 0x3C;
    constexpr uint32_t kArIssued = 0x40, kArStall = 0x44, kCmdStall = 0x48;
    constexpr uint32_t kMaxOut = 0x4C, kErrCode = 0x50, kWrite = 0x54;
    constexpr uint32_t kReset = 0x58, kDbg0 = 0x5C, kDbg1 = 0x60;
    constexpr uint32_t kIssued = 0x64, kWdataIssued = 0x68, kRstBusy = 0x6C;

    const uint64_t bytes = 256ull << 20;          // 256 MiB BO
    xrt::bo bo(dev, bytes, 1);                    // memory group 1 == DDR[1]
    const uint64_t addr = bo.address();
    std::printf("BO address=0x%llx size=%llu MiB\n",
                static_cast<unsigned long long>(addr),
                static_cast<unsigned long long>(bytes >> 20));

    // soft-reset the bridge so every run starts from a clean FIFO/FSM state
    ip.write_register(kReset, 1);
    std::this_thread::sleep_for(std::chrono::milliseconds(2));

    ip.write_register(kBaseLo, static_cast<uint32_t>(addr));
    ip.write_register(kBaseHi, static_cast<uint32_t>(addr >> 32));
    ip.write_register(kMode, 1);                  // the AXI bridge owns m_axi_bank_0

    const bool do_write = (argc > 2 && std::string(argv[2]) == "write");
    ip.write_register(kWrite, do_write ? 1 : 0);

    for (uint32_t beats : {1u << 16, 1u << 20, 4u << 20}) {  // 4 MiB, 64 MiB, 256 MiB
      ip.write_register(kN, beats);
      ip.write_register(kStart, 0);
      ip.write_register(kCtrl, 1);
      uint32_t status = 0;
      for (int i = 0; i < 20000000; ++i) {
        status = ip.read_register(kStatus);
        if (status & 1) break;
      }
      const uint32_t cycles = ip.read_register(kCycles);
      const uint32_t got = ip.read_register(kBeats);
      const uint32_t ar = ip.read_register(kArIssued);
      const uint32_t ar_stall = ip.read_register(kArStall);
      const uint32_t cmd_stall = ip.read_register(kCmdStall);
      const uint32_t max_out = ip.read_register(kMaxOut);
      const uint32_t err_code = ip.read_register(kErrCode);
      const uint32_t dbg0 = ip.read_register(kDbg0);
      const uint32_t dbg1 = ip.read_register(kDbg1);
      const uint32_t issued = ip.read_register(kIssued);
      const uint32_t wdata_issued = ip.read_register(kWdataIssued);
      const double gbps = cycles ? (double)got * 64.0 * 300e6 / (double)cycles / 1e9 : 0.0;
      const double pct = cycles ? 100.0 * (double)got / (double)cycles : 0.0;
      std::printf("beats=%u (%u MiB) cycles=%u got=%u status=0x%x: %.2f GB/s = %.1f%% of 19.2\n",
                  beats, (beats * 64) >> 20, cycles, got, status, gbps, pct);
      std::printf("  ARs=%u (%.2f beats/AR) ar_stall=%u cmd_stall=%u max_out=%u err_code=%u\n",
                  ar, ar ? (double)got / (double)ar : 0.0, ar_stall, cmd_stall, max_out,
                  err_code);
      std::printf("  mode=%s issued=%u wdata_issued=%u\n",
                  do_write ? "write" : "read", issued, wdata_issued);
      std::printf("  dbg0=0x%08x (w_state=%u w_blen=%u w_idx=%u w_win_n=%u)\n",
                  dbg0, dbg0 >> 31, (dbg0 >> 25) & 0x3F, (dbg0 >> 19) & 0x3F,
                  (dbg0 >> 13) & 0x3F);
      std::printf("  dbg1=0x%08x (wout=%u tag_pend=%u cmd_count=%u wd0=%u wd1=%u)\n",
                  dbg1, (dbg1 >> 27) & 0x1F, (dbg1 >> 21) & 0x3F, (dbg1 >> 14) & 0x7F,
                  (dbg1 >> 7) & 0x7F, dbg1 & 0x7F);
      if (!(status & 1) || (status & 2) || got != beats) {
        std::fprintf(stderr, "bandwidth run failed (status=0x%x got=%u want=%u)\n",
                     status, got, beats);
        return 1;
      }
    }
    std::printf("PASS: bridge bandwidth runs completed\n");
    return 0;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "XRT error: %s\n", e.what());
    return 1;
  }
}
