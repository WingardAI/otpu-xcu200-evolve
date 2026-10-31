// New in the XCU200 port (WingardAI, 2026) for openTPU,
// https://github.com/FeSens/openTPU (Apache-2.0). See NOTICE.

// ctypes shim for the parts of XRT that pyxrt 2.18 does not expose: xrt::ip (arbitrary control
// register access) and xrt::bo (host BOs). opentpu/host/xrt.py loads this library.
#include <xrt/xrt_device.h>
#include <xrt/xrt_bo.h>
#include <experimental/xrt_ip.h>
#include <experimental/xrt_xclbin.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

struct OtpuXrt {
  xrt::device dev;
  xrt::uuid uuid;
  std::unique_ptr<xrt::ip> ip;
  std::vector<std::unique_ptr<xrt::bo>> bos;
  OtpuXrt(const char* xclbin, const char* kernel)
      : dev(0), uuid(dev.load_xclbin(xclbin)) {
    std::string name = kernel ? kernel : "";
    if (name.empty()) {
      xrt::xclbin bin(xclbin);
      for (auto& k : bin.get_kernels()) { name = k.get_name(); break; }
    }
    ip = std::make_unique<xrt::ip>(dev, uuid, name);
  }
};

extern "C" {

void* otpu_xrt_open(const char* xclbin, const char* kernel, char* err, int errlen) {
  try {
    return new OtpuXrt(xclbin, kernel);
  } catch (const std::exception& e) {
    if (err && errlen > 0) { std::snprintf(err, errlen, "%s", e.what()); }
    return nullptr;
  }
}

void otpu_xrt_close(void* h) { delete static_cast<OtpuXrt*>(h); }

uint32_t otpu_xrt_read(void* h, uint32_t off) {
  return static_cast<OtpuXrt*>(h)->ip->read_register(off);
}

void otpu_xrt_write(void* h, uint32_t off, uint32_t val) {
  static_cast<OtpuXrt*>(h)->ip->write_register(off, val);
}

void* otpu_xrt_bo(void* h, size_t bytes, int group) {
  auto* x = static_cast<OtpuXrt*>(h);
  x->bos.push_back(std::make_unique<xrt::bo>(x->dev, bytes, xrt::bo::flags::normal, group));
  return x->bos.back().get();
}

uint64_t otpu_xrt_bo_addr(void* bo) {
  return static_cast<xrt::bo*>(bo)->address();
}

int otpu_xrt_bo_write(void* bo, const void* data, size_t bytes, size_t off) {
  try {
    static_cast<xrt::bo*>(bo)->write(data, bytes, off);
    return 0;
  } catch (const std::exception&) { return -1; }
}

int otpu_xrt_bo_read(void* bo, void* data, size_t bytes, size_t off) {
  try {
    static_cast<xrt::bo*>(bo)->read(data, bytes, off);
    return 0;
  } catch (const std::exception&) { return -1; }
}

int otpu_xrt_bo_sync(void* bo, int to_device) {
  try {
    static_cast<xrt::bo*>(bo)->sync(to_device ? XCL_BO_SYNC_BO_TO_DEVICE
                                              : XCL_BO_SYNC_BO_FROM_DEVICE);
    return 0;
  } catch (const std::exception&) { return -1; }
}

int otpu_xrt_bo_sync_range(void* bo, int to_device, size_t bytes, size_t off) {
  try {
    static_cast<xrt::bo*>(bo)->sync(to_device ? XCL_BO_SYNC_BO_TO_DEVICE
                                              : XCL_BO_SYNC_BO_FROM_DEVICE, bytes, off);
    return 0;
  } catch (const std::exception&) { return -1; }
}

}  // extern "C"
