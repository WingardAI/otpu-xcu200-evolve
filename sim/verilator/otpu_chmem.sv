// Simulation model of the board memory behind the two channels' native ports n_*: per channel the
// board's bridge, otpu_mem_ch, in front of either a model of LiteDRAM's two native ports
// (otpu_ldn_model, MEM = 0) or the U200 path: otpu_axi_dram + axi_mem_model (MEM = 1), both
// channels in one controller clock (uclk). otpu_native_mem's parameters and ports, so the board
// model (tb_board) takes either; this one runs the RTL between the accelerator and the controller.
//
// MEM = 1 uses the same ch<c>.bin / ch<c>_out.bin images as the LiteDRAM model; the AXI model's
// read latency is one cycle (the board tests check data, not cycle counts).
module otpu_chmem #(
  parameter int WORDS = 1 << 18,
  parameter int PHYS  = 0,
  parameter int LAT   = 20,              // LiteDRAM model's minimum read latency (unused with MEM)
  parameter int SID   = 0,               // the slice: its channels' files are ch<2 SID + c>
  parameter bit CHASH = 1'b1,            // (otpu_native_mem's; unused: the images are physical)
  parameter bit MEM   = 1'b0,            // 1: otpu_axi_dram + axi_mem_model (U200)
  // MEM 1: the two controllers' AXI timings (axi_mem_model's): channel 0 RLAT/RGAP/WLAT and
  // channel 1 RLAT1 (a second DDR4 controller has its own latency). Defaults 0: the one-cycle
  // slave the board tests are written against.
  parameter int RLAT  = 0,
  parameter int RLAT1 = 0,
  parameter int RGAP  = 0,
  parameter int WLAT  = 0,
  parameter int RJIT  = 0
) (
  input  logic                  clk,
  input  logic                  rst,
  input  logic [1:0]            n_cvalid,
  output logic [1:0]            n_cready,
  input  logic [1:0]            n_cwe,
  input  logic [1:0][24:0]      n_caddr,
  input  logic [1:0]            n_wvalid,
  output logic [1:0]            n_wready,
  input  logic [1:0][511:0]     n_wdata,
  input  logic [1:0][63:0]      n_wmask,
  output logic [1:0]            n_rvalid,
  output logic [1:0][511:0]     n_rdata,
  output logic [1:0][15:0]      n_wdone,
  output logic [1:0]            n_err,
  input  logic                  dump
);
  localparam int BEATS = WORDS / 32;     // per channel: WORDS / 2 words, 16 a beat
  initial if (PHYS != 1) $fatal(1, "otpu_chmem: PHYS = 1 only (the channels' own images)");

  logic uclk = 1'b0, xclk = 1'b0;
  always begin
    #4 uclk = 1'b1; #4 uclk = 1'b0; #4 uclk = 1'b1; #3 uclk = 1'b0;
  end
  always #4 xclk = ~xclk;
  logic xrst = 1'b1, xr1 = 1'b1;
  always @(posedge xclk) {xrst, xr1} <= {xr1, rst};

  initial begin
    int seed;
    if ($value$plusargs("axi_seed=%d", seed)) void'($urandom(seed));
  end

  for (genvar c = 0; c < 2; c++) begin : g_ch
    logic         urst = 1'b1, ur1 = 1'b1;
    logic [1:0]   cv, cr, cwe, wv, wr, rv;          // the channel's two ports
    logic [1:0][24:0]  ca;
    logic [1:0][511:0] wd, rd;
    logic [1:0][63:0]  we;
    logic         ch_err;
    logic         axi_err;
    always @(posedge uclk) {urst, ur1} <= {ur1, rst};
    assign n_err[c] = ch_err | axi_err;
    otpu_mem_ch #(.XIDW(4)) u_ch (
      .clk, .rst,
      .n_cvalid(n_cvalid[c]), .n_cready(n_cready[c]), .n_cwe(n_cwe[c]), .n_caddr(n_caddr[c]),
      .n_wvalid(n_wvalid[c]), .n_wready(n_wready[c]), .n_wdata(n_wdata[c]), .n_wmask(n_wmask[c]),
      .n_rvalid(n_rvalid[c]), .n_rdata(n_rdata[c]), .n_wdone(n_wdone[c]), .n_err(ch_err),
      .xclk, .xrst,
      .x_awvalid(1'b0), .x_awready(), .x_awid(4'h0), .x_awaddr(32'h0), .x_awlen(8'h0),
      .x_wvalid(1'b0), .x_wready(), .x_wdata(128'h0), .x_wstrb(16'h0), .x_wlast(1'b0),
      .x_bvalid(), .x_bready(1'b1), .x_bid(), .x_bresp(),
      .x_arvalid(1'b0), .x_arready(), .x_arid(4'h0), .x_araddr(32'h0), .x_arlen(8'h0),
      .x_rvalid(), .x_rready(1'b1), .x_rid(), .x_rdata(), .x_rresp(), .x_rlast(),
      .uclk, .urst,
      .c_cmd_valid(cv), .c_cmd_ready(cr), .c_cmd_we(cwe), .c_cmd_addr(ca),
      .c_wdata_valid(wv), .c_wdata_ready(wr), .c_wdata_data(wd), .c_wdata_we(we),
      .c_rdata_valid(rv), .c_rdata_data(rd));

    if (MEM) begin : g_axi
      // the U200 path: native controller ports -> AXI4 -> the shell DDR model
      logic [63:0]  awaddr;  logic [7:0] awlen;  logic [2:0] awsize, awburst;
      logic         awvalid, awready;
      logic [511:0] wdata;   logic [63:0] wstrb; logic wlast, wvalid, wready;
      logic [1:0]   bresp;   logic bvalid, bready;
      logic [63:0]  araddr;  logic [7:0] arlen;  logic [2:0] arsize, arburst;
      logic         arvalid, arready;
      logic [511:0] rdata;   logic [1:0] rresp;  logic rvalid, rready, rlast;
      // the bridge's read-only diagnostics (the kernel top wires them to debug registers)
      logic         d_w_state;
      logic [5:0]   d_w_idx, d_w_blen, d_w_win_n, d_tag_pend;
      logic [6:0]   d_cmd_count;                 // $clog2(CDEPTH + 1), CDEPTH = 64
      logic [4:0]   d_wd_count0, d_wd_count1;    // $clog2(WDEPTH + 1), WDEPTH = 16
      logic [9:0]   d_outstanding;
      logic [4:0]   d_wout_pending;
      logic [2:0]   d_err_code;
      otpu_axi_dram #(.CDEPTH(64), .WDEPTH(16), .ROUT(64), .WOUT(16)) u_axi (
        .clk(uclk), .rst(urst), .base(64'd0), .win(64'd0),
        .c_cmd_valid(cv), .c_cmd_ready(cr), .c_cmd_we(cwe), .c_cmd_addr(ca),
        .c_wdata_valid(wv), .c_wdata_ready(wr), .c_wdata_data(wd), .c_wdata_we(we),
        .c_rdata_valid(rv), .c_rdata_data(rd), .err(axi_err),
        .dbg_outstanding(d_outstanding), .dbg_wout_pending(d_wout_pending),
        .dbg_err_code(d_err_code), .dbg_w_state(d_w_state), .dbg_w_idx(d_w_idx),
        .dbg_w_blen(d_w_blen), .dbg_w_win_n(d_w_win_n), .dbg_cmd_count(d_cmd_count),
        .dbg_wd_count0(d_wd_count0), .dbg_wd_count1(d_wd_count1), .dbg_tag_pend(d_tag_pend),
        .m_axi_AWADDR(awaddr), .m_axi_AWLEN(awlen), .m_axi_AWSIZE(awsize),
        .m_axi_AWBURST(awburst), .m_axi_AWVALID(awvalid), .m_axi_AWREADY(awready),
        .m_axi_WDATA(wdata), .m_axi_WSTRB(wstrb), .m_axi_WLAST(wlast),
        .m_axi_WVALID(wvalid), .m_axi_WREADY(wready),
        .m_axi_BRESP(bresp), .m_axi_BVALID(bvalid), .m_axi_BREADY(bready),
        .m_axi_ARADDR(araddr), .m_axi_ARLEN(arlen), .m_axi_ARSIZE(arsize),
        .m_axi_ARBURST(arburst), .m_axi_ARVALID(arvalid), .m_axi_ARREADY(arready),
        .m_axi_RDATA(rdata), .m_axi_RRESP(rresp), .m_axi_RVALID(rvalid),
        .m_axi_RREADY(rready), .m_axi_RLAST(rlast));
      axi_mem_model #(.WORDS(BEATS), .RQD(64), .CH(2 * SID + c), .IMG(1'b1),
                      .RLAT(c == 0 ? RLAT : RLAT1), .RGAP(RGAP), .WLAT(WLAT), .RJIT(RJIT)) u_mem (
        .clk(uclk), .rst(urst),
        .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize), .s_awburst(awburst),
        .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast), .s_wvalid(wvalid), .s_wready(wready),
        .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize), .s_arburst(arburst),
        .s_arvalid(arvalid), .s_arready(arready),
        .s_rdata(rdata), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(rready),
        .s_rlast(rlast), .dump(dump));
    end else begin : g_ldn
      assign axi_err = 1'b0;
      otpu_ldn_model #(.BEATS(BEATS), .LAT(LAT), .CH(2 * SID + c), .IMG(1'b1)) u_mem (
        .clk(uclk), .rst(urst),
        .c_cmd_valid(cv), .c_cmd_ready(cr), .c_cmd_we(cwe), .c_cmd_addr(ca),
        .c_wdata_valid(wv), .c_wdata_ready(wr), .c_wdata_data(wd), .c_wdata_we(we),
        .c_rdata_valid(rv), .c_rdata_data(rd), .dump);
    end
  end
endmodule
