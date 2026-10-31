// openTPU on the Alveo U200 as a Vitis RTL kernel: the S = 2 accelerator (two slices, four
// memory channels, one DDR4 controller each).
//
//   ap_clk / ap_rst_n, s_axi_control (AXI4-Lite) -> otpu_board's control block
//   m_axi_bank_0 .. m_axi_bank_3: channel 2s + c of slice s. Each channel is
//     otpu_board n_* -> two otpu_native_reg (the SLR0 -> SLR1 crossing) -> otpu_mem_ch ->
//     otpu_axi_dram -> AXI4 -> the shell's DDR. Both slices sit in SLR0, the four channels in
//     SLR1 (constraints/core_pblocks.tcl); the collective unit runs GATHER (S > 1).
//
// 0x300/0x308/0x310/0x318 (s_axi_control, captured here): DramBase0..3, the 64-bit device address
// of the host BO backing each channel (the AXI bridges add it to the channel-relative beats).
module OtpuCoreKernel (
  input  logic         ap_clk,
  input  logic         ap_rst_n,

  input  logic [11:0]  s_axi_control_AWADDR,
  input  logic         s_axi_control_AWVALID,
  output logic         s_axi_control_AWREADY,
  input  logic [31:0]  s_axi_control_WDATA,
  input  logic [3:0]   s_axi_control_WSTRB,
  input  logic         s_axi_control_WVALID,
  output logic         s_axi_control_WREADY,
  output logic [1:0]   s_axi_control_BRESP,
  output logic         s_axi_control_BVALID,
  input  logic         s_axi_control_BREADY,
  input  logic [11:0]  s_axi_control_ARADDR,
  input  logic         s_axi_control_ARVALID,
  output logic         s_axi_control_ARREADY,
  output logic [31:0]  s_axi_control_RDATA,
  output logic [1:0]   s_axi_control_RRESP,
  output logic         s_axi_control_RVALID,
  input  logic         s_axi_control_RREADY,

  output logic [63:0]  m_axi_bank_0_AWADDR,
  output logic [7:0]   m_axi_bank_0_AWLEN,
  output logic [2:0]   m_axi_bank_0_AWSIZE,
  output logic [2:0]   m_axi_bank_0_AWBURST,
  output logic         m_axi_bank_0_AWVALID,
  input  logic         m_axi_bank_0_AWREADY,
  output logic [511:0] m_axi_bank_0_WDATA,
  output logic [63:0]  m_axi_bank_0_WSTRB,
  output logic         m_axi_bank_0_WLAST,
  output logic         m_axi_bank_0_WVALID,
  input  logic         m_axi_bank_0_WREADY,
  input  logic [1:0]   m_axi_bank_0_BRESP,
  input  logic         m_axi_bank_0_BVALID,
  output logic         m_axi_bank_0_BREADY,
  output logic [63:0]  m_axi_bank_0_ARADDR,
  output logic [7:0]   m_axi_bank_0_ARLEN,
  output logic [2:0]   m_axi_bank_0_ARSIZE,
  output logic [2:0]   m_axi_bank_0_ARBURST,
  output logic         m_axi_bank_0_ARVALID,
  input  logic         m_axi_bank_0_ARREADY,
  input  logic [511:0] m_axi_bank_0_RDATA,
  input  logic [1:0]   m_axi_bank_0_RRESP,
  input  logic         m_axi_bank_0_RVALID,
  output logic         m_axi_bank_0_RREADY,
  input  logic         m_axi_bank_0_RLAST,

  output logic [63:0]  m_axi_bank_1_AWADDR,
  output logic [7:0]   m_axi_bank_1_AWLEN,
  output logic [2:0]   m_axi_bank_1_AWSIZE,
  output logic [2:0]   m_axi_bank_1_AWBURST,
  output logic         m_axi_bank_1_AWVALID,
  input  logic         m_axi_bank_1_AWREADY,
  output logic [511:0] m_axi_bank_1_WDATA,
  output logic [63:0]  m_axi_bank_1_WSTRB,
  output logic         m_axi_bank_1_WLAST,
  output logic         m_axi_bank_1_WVALID,
  input  logic         m_axi_bank_1_WREADY,
  input  logic [1:0]   m_axi_bank_1_BRESP,
  input  logic         m_axi_bank_1_BVALID,
  output logic         m_axi_bank_1_BREADY,
  output logic [63:0]  m_axi_bank_1_ARADDR,
  output logic [7:0]   m_axi_bank_1_ARLEN,
  output logic [2:0]   m_axi_bank_1_ARSIZE,
  output logic [2:0]   m_axi_bank_1_ARBURST,
  output logic         m_axi_bank_1_ARVALID,
  input  logic         m_axi_bank_1_ARREADY,
  input  logic [511:0] m_axi_bank_1_RDATA,
  input  logic [1:0]   m_axi_bank_1_RRESP,
  input  logic         m_axi_bank_1_RVALID,
  output logic         m_axi_bank_1_RREADY,
  input  logic         m_axi_bank_1_RLAST,
  output logic [63:0]  m_axi_bank_2_AWADDR,
  output logic [7:0]   m_axi_bank_2_AWLEN,
  output logic [2:0]   m_axi_bank_2_AWSIZE,
  output logic [2:0]   m_axi_bank_2_AWBURST,
  output logic         m_axi_bank_2_AWVALID,
  input  logic         m_axi_bank_2_AWREADY,
  output logic [511:0] m_axi_bank_2_WDATA,
  output logic [63:0]  m_axi_bank_2_WSTRB,
  output logic         m_axi_bank_2_WLAST,
  output logic         m_axi_bank_2_WVALID,
  input  logic         m_axi_bank_2_WREADY,
  input  logic [1:0]   m_axi_bank_2_BRESP,
  input  logic         m_axi_bank_2_BVALID,
  output logic         m_axi_bank_2_BREADY,
  output logic [63:0]  m_axi_bank_2_ARADDR,
  output logic [7:0]   m_axi_bank_2_ARLEN,
  output logic [2:0]   m_axi_bank_2_ARSIZE,
  output logic [2:0]   m_axi_bank_2_ARBURST,
  output logic         m_axi_bank_2_ARVALID,
  input  logic         m_axi_bank_2_ARREADY,
  input  logic [511:0] m_axi_bank_2_RDATA,
  input  logic [1:0]   m_axi_bank_2_RRESP,
  input  logic         m_axi_bank_2_RVALID,
  output logic         m_axi_bank_2_RREADY,
  input  logic         m_axi_bank_2_RLAST,
  output logic [63:0]  m_axi_bank_3_AWADDR,
  output logic [7:0]   m_axi_bank_3_AWLEN,
  output logic [2:0]   m_axi_bank_3_AWSIZE,
  output logic [2:0]   m_axi_bank_3_AWBURST,
  output logic         m_axi_bank_3_AWVALID,
  input  logic         m_axi_bank_3_AWREADY,
  output logic [511:0] m_axi_bank_3_WDATA,
  output logic [63:0]  m_axi_bank_3_WSTRB,
  output logic         m_axi_bank_3_WLAST,
  output logic         m_axi_bank_3_WVALID,
  input  logic         m_axi_bank_3_WREADY,
  input  logic [1:0]   m_axi_bank_3_BRESP,
  input  logic         m_axi_bank_3_BVALID,
  output logic         m_axi_bank_3_BREADY,
  output logic [63:0]  m_axi_bank_3_ARADDR,
  output logic [7:0]   m_axi_bank_3_ARLEN,
  output logic [2:0]   m_axi_bank_3_ARSIZE,
  output logic [2:0]   m_axi_bank_3_ARBURST,
  output logic         m_axi_bank_3_ARVALID,
  input  logic         m_axi_bank_3_ARREADY,
  input  logic [511:0] m_axi_bank_3_RDATA,
  input  logic [1:0]   m_axi_bank_3_RRESP,
  input  logic         m_axi_bank_3_RVALID,
  output logic         m_axi_bank_3_RREADY,
  input  logic         m_axi_bank_3_RLAST
);
  // Reset synchronizers, one per SLR group (the kernel's clock-distribution pattern): async
  // assert from ap_rst_n, synchronous deassert. The async CLR pins are false-pathed in
  // constraints/core_pblocks.tcl. rst0: board + mem_ch (SLR0); rst1: AXI bridges (SLR1).
  (* ASYNC_REG = "TRUE" *) logic [1:0] rstn_sync0 = 2'b00;
  (* ASYNC_REG = "TRUE" *) logic [1:0] rstn_sync1 = 2'b00;
  (* ASYNC_REG = "TRUE" *) logic [1:0] rstn_sync2 = 2'b00;
  always_ff @(posedge ap_clk or negedge ap_rst_n) begin
    if (!ap_rst_n) begin
      rstn_sync0 <= 2'b00;
      rstn_sync1 <= 2'b00;
      rstn_sync2 <= 2'b00;
    end else begin
      rstn_sync0 <= {rstn_sync0[0], 1'b1};
      rstn_sync1 <= {rstn_sync1[0], 1'b1};
      rstn_sync2 <= {rstn_sync2[0], 1'b1};
    end
  end
  logic rst0 = ~rstn_sync0[1];
  logic rst1 = ~rstn_sync1[1];
  logic rst2 = ~rstn_sync2[1];

  // host BO bases for the four channel AXI bridges (0x300, 0x308, 0x310, 0x318) and their pool
  // windows (0x320, 0x328, 0x330, 0x338): the window an expert-slot beat in the channel's top
  // 1 GiB names (docs/u200.md 3c), 0 for none
  localparam int NS  = 2;             // slices (the MoE image builds NS = 1)
  localparam int NCH = 2 * NS;        // memory channels: one DDR4 controller each
  localparam int NPORT = 4;           // the kernel's m_axi_bank_* ports (the XML's four): the
                                      // ports above NCH are tied off, so a one-slice build does
                                      // not drive X into the shell's DDR[2]/DDR[3]
  logic [63:0] dram_base [NCH];
  logic [63:0] pool_win  [NCH];
  always_ff @(posedge ap_clk) begin
    if (rst1) begin
      for (int c = 0; c < NCH; c++) begin
        dram_base[c] <= '0;
        pool_win[c]  <= '0;
      end
    end else if (s_axi_control_AWVALID && s_axi_control_WVALID) begin
      for (int c = 0; c < NCH; c++) begin
        if (s_axi_control_AWADDR == 12'(12'h300 + 8 * c)) dram_base[c][31:0]  <= s_axi_control_WDATA;
        if (s_axi_control_AWADDR == 12'(12'h304 + 8 * c)) dram_base[c][63:32] <= s_axi_control_WDATA;
        if (s_axi_control_AWADDR == 12'(12'h320 + 8 * c)) pool_win[c][31:0]   <= s_axi_control_WDATA;
        if (s_axi_control_AWADDR == 12'(12'h324 + 8 * c)) pool_win[c][63:32]  <= s_axi_control_WDATA;
      end
    end
  end

  // the board's native channel masters (2 * NS channels); b_* is the board's side of the
  // SLR-crossing register slices, t_* the crossing nets, n_* the mem_ch's side
  logic [NCH-1:0]        n_cvalid, n_cready, n_cwe, n_wvalid, n_wready, n_rvalid, n_err;
  logic [NCH-1:0][24:0]  n_caddr;
  logic [NCH-1:0][511:0] n_wdata, n_rdata;
  logic [NCH-1:0][63:0]  n_wmask;
  logic [NCH-1:0][15:0]  n_wdone;
  logic [NCH-1:0]        b_cvalid, b_cready, b_cwe, b_wvalid, b_wready, b_rvalid, b_err;
  logic [NCH-1:0][24:0]  b_caddr;
  logic [NCH-1:0][511:0] b_wdata, b_rdata;
  logic [NCH-1:0][63:0]  b_wmask;
  logic [NCH-1:0][15:0]  b_wdone;
  logic [NCH-1:0]        t_cvalid, t_cready, t_cwe, t_wvalid, t_wready, t_rvalid, t_err;
  logic [NCH-1:0][24:0]  t_caddr;
  logic [NCH-1:0][511:0] t_wdata, t_rdata;
  logic [NCH-1:0][63:0]  t_wmask;
  logic [NCH-1:0][15:0]  t_wdone;


  logic [NCH-1:0]    ch_err;         // mem_ch native contract error per channel
  logic              led;
  logic [3:0]        i2c_lo;

  // ---- bridge diagnostics, read back at 0x028..0x02F (otpu_ctrl's `dbg` words). The AXI
  // error a model run reported has no attribution otherwise: 0x028 gives each bridge's sticky
  // cause (1 = an R beat with no tag, 2 = RLAST mismatch, 3 = RRESP != OKAY, 4 = BRESP != OKAY)
  // with its sticky valid bit, 0x029..0x02C the address of the last AR/AW issued when the first
  // error appeared (both channels), 0x02D/0x02E the write state and queue counts, 0x02F the
  // cycle count at the first error.
  logic [2:0]  br_err_code [NCH];
  logic        br_err_c [NCH];   // each channel's bridge error
  logic [NCH-1:0] br_err_sticky;
  logic [2:0]  br_code_sticky [NCH];
  logic [NCH-1:0] ch_err_sticky;
  logic [39:0] last_ar [NCH], last_aw [NCH];
  logic [39:0] err_ar   [NCH], err_aw   [NCH];
  logic [2:0]  err_ch;            // the channel that errored first (0..3)
  logic [31:0] err_cycle;
  logic        br_dbg_w_state [NCH];
  logic [5:0]  br_dbg_w_idx [NCH], br_dbg_w_blen [NCH], br_dbg_w_win_n [NCH];
  logic [6:0]  br_dbg_cmd_count [NCH], br_dbg_wd0 [NCH], br_dbg_wd1 [NCH];
  logic [5:0]  br_dbg_tag_pend [NCH];
  logic [7:0]  br_dbg_outstanding [NCH];
  logic [7:0][31:0] dbg_words;
  logic [31:0]      dbg_cycle;

  always_ff @(posedge ap_clk) begin
    if (rst1) begin
      br_err_sticky <= '0;
      ch_err_sticky <= '0;
      err_ch <= '0;
      for (int c = 0; c < NCH; c++) begin
        br_code_sticky[c] <= '0;
        err_ar[c] <= '0; err_aw[c] <= '0;
      end
      err_cycle <= '0;
    end else begin
      // the last AR/AW each port issued (the mem_ch's contract error is about a port's response,
      // the bridge's is about the burst, so both are useful at the first failure)
      for (int c = 0; c < NCH; c++) begin
        if (ax_arvalid[c] && ax_arready[c]) last_ar[c] <= ax_araddr[c][39:0];
        if (ax_awvalid[c] && ax_awready[c]) last_aw[c] <= ax_awaddr[c][39:0];
      end
      for (int c = 0; c < NCH; c++) begin
        // channel c's error: the mem_ch's contract check (STATUS AXI_ERR) or the bridge's AXI error
        if ((br_err_c[c] || ch_err[c]) && !br_err_sticky[c]) begin
          br_err_sticky[c]  <= 1'b1;
          ch_err_sticky[c]  <= ch_err[c];
          br_code_sticky[c] <= br_err_code[c];
          err_ar[c] <= last_ar[c];
          err_aw[c] <= last_aw[c];
          if (br_err_sticky == '0) begin        // the first channel to fail
            err_ch    <= 3'(c);
            err_cycle <= dbg_cycle;
          end
        end
      end
    end
  end

  // 0x028: per channel {err, cause} (4 bits each, channels 0..3) + the mem_ch's own sticky bits;
  // 0x029/0x02A: the AR/AW address the FIRST failing channel had last issued; 0x02B: which channel
  // that was, + its sticky bit; 0x02C: the cycle count at the first failure.
  assign dbg_words[0] = {12'd0,
                         ch_err_sticky,                                  // [19:16]
                         br_code_sticky[3], br_err_sticky[3],            // [15:12]
                         br_code_sticky[2], br_err_sticky[2],            // [11:8]
                         br_code_sticky[1], br_err_sticky[1],            // [7:4]
                         br_code_sticky[0], br_err_sticky[0]};           // [3:0]
  assign dbg_words[1] = err_ar[err_ch][31:0];
  assign dbg_words[2] = err_aw[err_ch][31:0];
  assign dbg_words[3] = {28'd0, err_ch, br_err_sticky != '0};
  assign dbg_words[4] = err_cycle;
  assign dbg_words[5] = {8'(br_dbg_outstanding[0]), 6'(br_dbg_cmd_count[0]), 6'(br_dbg_wd0[0]),
                         6'(br_dbg_wd1[0]), 2'(br_dbg_tag_pend[0]), br_dbg_w_state[0], 3'b0};
  assign dbg_words[6] = {8'(br_dbg_outstanding[1]), 6'(br_dbg_cmd_count[1]), 6'(br_dbg_wd0[1]),
                         6'(br_dbg_wd1[1]), 2'(br_dbg_tag_pend[1]), br_dbg_w_state[1], 3'b0};
  assign dbg_words[7] = err_cycle;

  always_ff @(posedge ap_clk) begin
    if (rst1) dbg_cycle <= '0;
    else      dbg_cycle <= dbg_cycle + 32'd1;
  end

  otpu_board #(
    .S(NS), .D(128), .MCOLS(4), .ACT_ROWS(16), .ACT_BLOCKS(128),
    .TMEM_WORDS(1 << 15), .IMEM_WORDS(1 << 15), .LANES(8), .WIN(16),
    .TMEM_IMPL(0), .MXU_IMPL(2), .MXU_E(4), .VPU_CL(2), .ULANES(8),
    .CORE_KHZ(150000), .BUILD_ID(32'h0), .DDR_MTS(2400),
    .TRACE_DEPTH(16384), .TRACE_QD(32), .PQ_WIN(1024),
    .HAS_I2C(1'b0), .CHASH(1'b1), .DSTEP(1'b1), .HOSTCAL(1'b0),
    .COLL_GATHER(1'b1), .SEQ_WC(1'b1), .PLATFORM(4), .ARCH_HASH(32'h0)
  ) u_board (
    .clk(ap_clk), .clk_f(ap_clk), .rst(rst0), .ctl_mrst(rst0),
    .calib({NCH{1'b1}}), .ded({NCH{1'b0}}), .dbg(dbg_words), .temp(12'd0), .led(led),
    .i2c_lo(i2c_lo), .i2c_pin(5'b11111),
    .s_ctl_awaddr(s_axi_control_AWADDR), .s_ctl_awvalid(s_axi_control_AWVALID),
    .s_ctl_awready(s_axi_control_AWREADY), .s_ctl_wdata(s_axi_control_WDATA),
    .s_ctl_wstrb(s_axi_control_WSTRB), .s_ctl_wvalid(s_axi_control_WVALID),
    .s_ctl_wready(s_axi_control_WREADY), .s_ctl_bresp(s_axi_control_BRESP),
    .s_ctl_bvalid(s_axi_control_BVALID), .s_ctl_bready(s_axi_control_BREADY),
    .s_ctl_araddr(s_axi_control_ARADDR), .s_ctl_arvalid(s_axi_control_ARVALID),
    .s_ctl_arready(s_axi_control_ARREADY), .s_ctl_rdata(s_axi_control_RDATA),
    .s_ctl_rresp(s_axi_control_RRESP), .s_ctl_rvalid(s_axi_control_RVALID),
    .s_ctl_rready(s_axi_control_RREADY),
    .n_cvalid(b_cvalid), .n_cready(b_cready), .n_cwe(b_cwe), .n_caddr(b_caddr),
    .n_wvalid(b_wvalid), .n_wready(b_wready), .n_wdata(b_wdata), .n_wmask(b_wmask),
    .n_rvalid(b_rvalid), .n_rdata(b_rdata), .n_wdone(b_wdone),
    .n_err(b_err | ch_err | n_err)
  );

  // The native bus' SLR crossing: two otpu_native_reg a channel, as the BCU's SLL has them. The
  // board's driver sits in SLR0 and the mem_ch (its input FIFOs are LUTRAM) in SLR1, so without
  // them a board flip-flop drove the mem_ch's FIFO write port 4.4 ns away -- fp17's worst path at
  // 200 MHz, after the TMEM path had been fixed. otpu_native_reg keeps the native contract
  // (commands and write data in order, read data and n_wdone a cycle later); one slice stays with
  // the board, the other with the mem_ch (constraints/core_pblocks.tcl), so the crossing net is
  // flop to flop.
  for (genvar c = 0; c < NCH; c++) begin : g_nreg
    otpu_native_reg u_nbtx (
      .clk(ap_clk), .rst(rst0),
      .s_cvalid(b_cvalid[c]), .s_cready(b_cready[c]), .s_cwe(b_cwe[c]), .s_caddr(b_caddr[c]),
      .s_wvalid(b_wvalid[c]), .s_wready(b_wready[c]), .s_wdata(b_wdata[c]),
      .s_wmask(b_wmask[c]),
      .s_rvalid(b_rvalid[c]), .s_rdata(b_rdata[c]), .s_wdone(b_wdone[c]), .s_err(b_err[c]),
      .m_cvalid(t_cvalid[c]), .m_cready(t_cready[c]), .m_cwe(t_cwe[c]), .m_caddr(t_caddr[c]),
      .m_wvalid(t_wvalid[c]), .m_wready(t_wready[c]), .m_wdata(t_wdata[c]),
      .m_wmask(t_wmask[c]),
      .m_rvalid(t_rvalid[c]), .m_rdata(t_rdata[c]), .m_wdone(t_wdone[c]), .m_err(t_err[c]));
    otpu_native_reg u_nbrx (
      .clk(ap_clk), .rst(rst2),
      .s_cvalid(t_cvalid[c]), .s_cready(t_cready[c]), .s_cwe(t_cwe[c]), .s_caddr(t_caddr[c]),
      .s_wvalid(t_wvalid[c]), .s_wready(t_wready[c]), .s_wdata(t_wdata[c]),
      .s_wmask(t_wmask[c]),
      .s_rvalid(t_rvalid[c]), .s_rdata(t_rdata[c]), .s_wdone(t_wdone[c]), .s_err(t_err[c]),
      .m_cvalid(n_cvalid[c]), .m_cready(n_cready[c]), .m_cwe(n_cwe[c]), .m_caddr(n_caddr[c]),
      .m_wvalid(n_wvalid[c]), .m_wready(n_wready[c]), .m_wdata(n_wdata[c]),
      .m_wmask(n_wmask[c]),
      .m_rvalid(n_rvalid[c]), .m_rdata(n_rdata[c]), .m_wdone(n_wdone[c]),
      .m_err(ch_err[c] | n_err[c]));   // the channel's error: the mem_ch's contract or the bridge's AXI error
  end

  // the four channels: one AXI net set each, assigned to the kernel's m_axi_bank_* ports below
  logic [NPORT-1:0][63:0]  ax_awaddr, ax_araddr;
  logic [NPORT-1:0][7:0]   ax_awlen, ax_arlen;
  logic [NPORT-1:0][2:0]   ax_awsize, ax_awburst, ax_arsize, ax_arburst;
  logic [NPORT-1:0]        ax_awvalid, ax_awready, ax_arvalid, ax_arready;
  logic [NPORT-1:0]        ax_wlast, ax_wvalid, ax_wready;
  logic [NPORT-1:0][511:0] ax_wdata, ax_rdata;
  logic [NPORT-1:0][63:0]  ax_wstrb;
  logic [NCH-1:0][1:0]   ax_bresp, ax_rresp;
  logic [NPORT-1:0]        ax_bvalid, ax_bready, ax_rvalid, ax_rready, ax_rlast;

  for (genvar c = 0; c < NCH; c++) begin : g_ch
    logic [1:0]        ccv, ccr, ccwe, cwv, cwr, crv;
    logic [1:0][24:0]  cca;
    logic [1:0][511:0] cwd, crd;
    logic [1:0][63:0]  cwe;
    logic              br_err;

    otpu_mem_ch #(.XIDW(4)) u_memch (
      .clk(ap_clk), .rst(rst2),
      .n_cvalid(n_cvalid[c]), .n_cready(n_cready[c]), .n_cwe(n_cwe[c]), .n_caddr(n_caddr[c]),
      .n_wvalid(n_wvalid[c]), .n_wready(n_wready[c]), .n_wdata(n_wdata[c]),
      .n_wmask(n_wmask[c]), .n_rvalid(n_rvalid[c]), .n_rdata(n_rdata[c]),
      .n_wdone(n_wdone[c]), .n_err(ch_err[c]),
      .xclk(ap_clk), .xrst(rst2),
      .x_awvalid(1'b0), .x_awready(), .x_awid(4'h0), .x_awaddr(32'h0), .x_awlen(8'h0),
      .x_wvalid(1'b0), .x_wready(), .x_wdata(128'h0), .x_wstrb(16'h0), .x_wlast(1'b0),
      .x_bvalid(), .x_bready(1'b1), .x_bid(), .x_bresp(),
      .x_arvalid(1'b0), .x_arready(), .x_arid(4'h0), .x_araddr(32'h0), .x_arlen(8'h0),
      .x_rvalid(), .x_rready(1'b1), .x_rid(), .x_rdata(), .x_rresp(), .x_rlast(),
      .uclk(ap_clk), .urst(rst2),
      .c_cmd_valid(ccv), .c_cmd_ready(ccr), .c_cmd_we(ccwe), .c_cmd_addr(cca),
      .c_wdata_valid(cwv), .c_wdata_ready(cwr), .c_wdata_data(cwd), .c_wdata_we(cwe),
      .c_rdata_valid(crv), .c_rdata_data(crd)
    );

    otpu_axi_dram #(.CDEPTH(64), .WDEPTH(16), .ROUT(128), .WOUT(16), .MAXB(4), .WMAXB(32))
    u_axi (
      .clk(ap_clk), .rst(rst1), .base(dram_base[c]), .win(pool_win[c]),
      .c_cmd_valid(ccv), .c_cmd_ready(ccr), .c_cmd_we(ccwe), .c_cmd_addr(cca),
      .c_wdata_valid(cwv), .c_wdata_ready(cwr), .c_wdata_data(cwd), .c_wdata_we(cwe),
      .c_rdata_valid(crv), .c_rdata_data(crd), .err(br_err),
      .dbg_outstanding(br_dbg_outstanding[c]), .dbg_wout_pending(),
      .dbg_err_code(br_err_code[c]),
      .dbg_w_state(br_dbg_w_state[c]), .dbg_w_idx(br_dbg_w_idx[c]),
      .dbg_w_blen(br_dbg_w_blen[c]), .dbg_w_win_n(br_dbg_w_win_n[c]),
      .dbg_cmd_count(br_dbg_cmd_count[c]), .dbg_wd_count0(br_dbg_wd0[c]),
      .dbg_wd_count1(br_dbg_wd1[c]), .dbg_tag_pend(br_dbg_tag_pend[c]),
      .m_axi_AWADDR(ax_awaddr[c]), .m_axi_AWLEN(ax_awlen[c]), .m_axi_AWSIZE(ax_awsize[c]),
      .m_axi_AWBURST(ax_awburst[c]), .m_axi_AWVALID(ax_awvalid[c]),
      .m_axi_AWREADY(ax_awready[c]),
      .m_axi_WDATA(ax_wdata[c]), .m_axi_WSTRB(ax_wstrb[c]), .m_axi_WLAST(ax_wlast[c]),
      .m_axi_WVALID(ax_wvalid[c]), .m_axi_WREADY(ax_wready[c]),
      .m_axi_BRESP(ax_bresp[c]), .m_axi_BVALID(ax_bvalid[c]), .m_axi_BREADY(ax_bready[c]),
      .m_axi_ARADDR(ax_araddr[c]), .m_axi_ARLEN(ax_arlen[c]), .m_axi_ARSIZE(ax_arsize[c]),
      .m_axi_ARBURST(ax_arburst[c]), .m_axi_ARVALID(ax_arvalid[c]),
      .m_axi_ARREADY(ax_arready[c]),
      .m_axi_RDATA(ax_rdata[c]), .m_axi_RRESP(ax_rresp[c]), .m_axi_RVALID(ax_rvalid[c]),
      .m_axi_RREADY(ax_rready[c]), .m_axi_RLAST(ax_rlast[c])
    );
    assign n_err[c] = br_err;
    assign br_err_c[c] = br_err;
  end


  // the kernel's AXI master ports (Verilog cannot index a port name)
  // the ports beyond NCH (a one-slice build's banks 2 and 3): idle, never asserting
  for (genvar c = NCH; c < NPORT; c++) begin : g_tie
    assign ax_awaddr[c] = '0;     assign ax_awlen[c] = '0;    assign ax_awsize[c] = '0;
    assign ax_awburst[c] = '0;    assign ax_awvalid[c] = '0;  assign ax_wdata[c] = '0;
    assign ax_wstrb[c] = '0;      assign ax_wlast[c] = '0;    assign ax_wvalid[c] = '0;
    assign ax_bready[c] = '0;     assign ax_araddr[c] = '0;   assign ax_arlen[c] = '0;
    assign ax_arsize[c] = '0;     assign ax_arburst[c] = '0;  assign ax_arvalid[c] = '0;
    assign ax_rready[c] = '0;
  end

  // bank 0
  assign m_axi_bank_0_AWADDR = ax_awaddr[0];
  assign m_axi_bank_0_AWLEN = ax_awlen[0];
  assign m_axi_bank_0_AWSIZE = ax_awsize[0];
  assign m_axi_bank_0_AWBURST = ax_awburst[0];
  assign m_axi_bank_0_AWVALID = ax_awvalid[0];
  assign m_axi_bank_0_WDATA = ax_wdata[0];
  assign m_axi_bank_0_WSTRB = ax_wstrb[0];
  assign m_axi_bank_0_WLAST = ax_wlast[0];
  assign m_axi_bank_0_WVALID = ax_wvalid[0];
  assign m_axi_bank_0_BREADY = ax_bready[0];
  assign m_axi_bank_0_ARADDR = ax_araddr[0];
  assign m_axi_bank_0_ARLEN = ax_arlen[0];
  assign m_axi_bank_0_ARSIZE = ax_arsize[0];
  assign m_axi_bank_0_ARBURST = ax_arburst[0];
  assign m_axi_bank_0_ARVALID = ax_arvalid[0];
  assign m_axi_bank_0_RREADY = ax_rready[0];
  assign ax_awready[0] = m_axi_bank_0_AWREADY;
  assign ax_wready[0] = m_axi_bank_0_WREADY;
  assign ax_bresp[0] = m_axi_bank_0_BRESP;
  assign ax_bvalid[0] = m_axi_bank_0_BVALID;
  assign ax_arready[0] = m_axi_bank_0_ARREADY;
  assign ax_rdata[0] = m_axi_bank_0_RDATA;
  assign ax_rresp[0] = m_axi_bank_0_RRESP;
  assign ax_rvalid[0] = m_axi_bank_0_RVALID;
  assign ax_rlast[0] = m_axi_bank_0_RLAST;
  // bank 1
  assign m_axi_bank_1_AWADDR = ax_awaddr[1];
  assign m_axi_bank_1_AWLEN = ax_awlen[1];
  assign m_axi_bank_1_AWSIZE = ax_awsize[1];
  assign m_axi_bank_1_AWBURST = ax_awburst[1];
  assign m_axi_bank_1_AWVALID = ax_awvalid[1];
  assign m_axi_bank_1_WDATA = ax_wdata[1];
  assign m_axi_bank_1_WSTRB = ax_wstrb[1];
  assign m_axi_bank_1_WLAST = ax_wlast[1];
  assign m_axi_bank_1_WVALID = ax_wvalid[1];
  assign m_axi_bank_1_BREADY = ax_bready[1];
  assign m_axi_bank_1_ARADDR = ax_araddr[1];
  assign m_axi_bank_1_ARLEN = ax_arlen[1];
  assign m_axi_bank_1_ARSIZE = ax_arsize[1];
  assign m_axi_bank_1_ARBURST = ax_arburst[1];
  assign m_axi_bank_1_ARVALID = ax_arvalid[1];
  assign m_axi_bank_1_RREADY = ax_rready[1];
  assign ax_awready[1] = m_axi_bank_1_AWREADY;
  assign ax_wready[1] = m_axi_bank_1_WREADY;
  assign ax_bresp[1] = m_axi_bank_1_BRESP;
  assign ax_bvalid[1] = m_axi_bank_1_BVALID;
  assign ax_arready[1] = m_axi_bank_1_ARREADY;
  assign ax_rdata[1] = m_axi_bank_1_RDATA;
  assign ax_rresp[1] = m_axi_bank_1_RRESP;
  assign ax_rvalid[1] = m_axi_bank_1_RVALID;
  assign ax_rlast[1] = m_axi_bank_1_RLAST;
  // bank 2
  assign m_axi_bank_2_AWADDR = ax_awaddr[2];
  assign m_axi_bank_2_AWLEN = ax_awlen[2];
  assign m_axi_bank_2_AWSIZE = ax_awsize[2];
  assign m_axi_bank_2_AWBURST = ax_awburst[2];
  assign m_axi_bank_2_AWVALID = ax_awvalid[2];
  assign m_axi_bank_2_WDATA = ax_wdata[2];
  assign m_axi_bank_2_WSTRB = ax_wstrb[2];
  assign m_axi_bank_2_WLAST = ax_wlast[2];
  assign m_axi_bank_2_WVALID = ax_wvalid[2];
  assign m_axi_bank_2_BREADY = ax_bready[2];
  assign m_axi_bank_2_ARADDR = ax_araddr[2];
  assign m_axi_bank_2_ARLEN = ax_arlen[2];
  assign m_axi_bank_2_ARSIZE = ax_arsize[2];
  assign m_axi_bank_2_ARBURST = ax_arburst[2];
  assign m_axi_bank_2_ARVALID = ax_arvalid[2];
  assign m_axi_bank_2_RREADY = ax_rready[2];
  assign ax_awready[2] = m_axi_bank_2_AWREADY;
  assign ax_wready[2] = m_axi_bank_2_WREADY;
  assign ax_bresp[2] = m_axi_bank_2_BRESP;
  assign ax_bvalid[2] = m_axi_bank_2_BVALID;
  assign ax_arready[2] = m_axi_bank_2_ARREADY;
  assign ax_rdata[2] = m_axi_bank_2_RDATA;
  assign ax_rresp[2] = m_axi_bank_2_RRESP;
  assign ax_rvalid[2] = m_axi_bank_2_RVALID;
  assign ax_rlast[2] = m_axi_bank_2_RLAST;
  // bank 3
  assign m_axi_bank_3_AWADDR = ax_awaddr[3];
  assign m_axi_bank_3_AWLEN = ax_awlen[3];
  assign m_axi_bank_3_AWSIZE = ax_awsize[3];
  assign m_axi_bank_3_AWBURST = ax_awburst[3];
  assign m_axi_bank_3_AWVALID = ax_awvalid[3];
  assign m_axi_bank_3_WDATA = ax_wdata[3];
  assign m_axi_bank_3_WSTRB = ax_wstrb[3];
  assign m_axi_bank_3_WLAST = ax_wlast[3];
  assign m_axi_bank_3_WVALID = ax_wvalid[3];
  assign m_axi_bank_3_BREADY = ax_bready[3];
  assign m_axi_bank_3_ARADDR = ax_araddr[3];
  assign m_axi_bank_3_ARLEN = ax_arlen[3];
  assign m_axi_bank_3_ARSIZE = ax_arsize[3];
  assign m_axi_bank_3_ARBURST = ax_arburst[3];
  assign m_axi_bank_3_ARVALID = ax_arvalid[3];
  assign m_axi_bank_3_RREADY = ax_rready[3];
  assign ax_awready[3] = m_axi_bank_3_AWREADY;
  assign ax_wready[3] = m_axi_bank_3_WREADY;
  assign ax_bresp[3] = m_axi_bank_3_BRESP;
  assign ax_bvalid[3] = m_axi_bank_3_BVALID;
  assign ax_arready[3] = m_axi_bank_3_ARREADY;
  assign ax_rdata[3] = m_axi_bank_3_RDATA;
  assign ax_rresp[3] = m_axi_bank_3_RRESP;
  assign ax_rvalid[3] = m_axi_bank_3_RVALID;
  assign ax_rlast[3] = m_axi_bank_3_RLAST;
endmodule
