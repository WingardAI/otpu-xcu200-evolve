// openTPU on the Alveo U200 as a Vitis RTL kernel: Phase 1 control/scratch + Phase 2 bandwidth test.
//
// Interfaces (Vitis conventions):
//   s_axi_control  AXI4-Lite 32-bit, 4 KB:
//     0x10/0x14 MemBase0 (64-bit BO address; scratch and the AXI bridge's base)
//     0x18    ScratchCtrl (bit0 start the 1 KiB scratch copy)
//     0x1C    ScratchStatus (bit0 done, bit1 error)
//     0x20    ScratchPattern
//     0x24    BwCtrl (bit0 start the read traffic generator)
//     0x28    BwN (beats, 64 B each)
//     0x2C    BwStart (first beat)
//     0x30    BwStatus (bit0 done, bit1 error)
//     0x34    BwCycles (ap_clk cycles, start..done)
//     0x38    BwBeats (read beats returned)
//     0x3C    BwMode (1: the AXI bridge owns m_axi_bank_0; 0: the scratch master)
//     0x40    BwArIssued (AR burst handshakes)
//     0x44    BwArStall (cycles ARVALID && !ARREADY)
//     0x48    BwCmdStall (cycles generator command valid && !ready)
//     0x4C    BwMaxOut (max read beats in flight)
//     0x50    BwErrCode (bridge error cause: 1 no tag, 2 RLAST, 3 RRESP, 4 BRESP)
//     0x54    BwWrite (1: the generator issues writes; 0: reads)
//     0x58    BwReset (write 1: hold the AXI bridge in reset for 16 ap_clk cycles)
//     0x5C    BwDbg0  {w_state, w_blen[5:0], w_idx[5:0], w_win_n[5:0]}
//     0x60    BwDbg1  {wout[4:0], tag_pend[5:0], cmd_count[6:0], wd0[6:0], wd1[6:0]}
//     0x64    BwIssued, 0x68 BwWdataIssued, 0x6C BwRstBusy
//     0x100+  otpu_ctrl (address - 0x100)
//   m_axi_bank_0   AXI4 master 512-bit        the shell's DDR4 bank (DDR[1])
//   ap_clk 300 MHz, ap_rst_n active low
//
// The bandwidth generator issues BwN read commands to otpu_axi_dram as fast as its command FIFO
// accepts them; the bridge turns them into 512-bit AXI reads at MemBase0 + beat*64. BwCycles and
// BwBeats give the sustained rate: BwBeats*64 / (BwCycles/300e6) bytes/s. The scratch master is
// kept for the Phase 1 control/DDR test (BwMode=0).

module OtpuKernel (
  input  logic         ap_clk,
  input  logic         ap_rst_n,

  // ---- AXI4-Lite control ----
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

  // ---- AXI4 master to the shell DDR ----
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
  input  logic         m_axi_bank_0_RLAST
);

  // ------------------------------------------------------------------ local registers
  logic [31:0] mem_lo, mem_hi, pattern_q, ctrl_q, status_q;
  logic        local_bvalid, local_rvalid;
  logic [11:0] raddr_lat;
  logic [31:0] local_rdata;
  logic        sel_b, sel_r;

  // ------------------------------------------------------------------ otpu_ctrl AXI-Lite
  logic [11:0] ctrl_awaddr, ctrl_araddr;
  logic        ctrl_awvalid, ctrl_wvalid, ctrl_arvalid;
  logic        ctrl_awready, ctrl_wready, ctrl_bvalid, ctrl_arready, ctrl_rvalid;
  logic [1:0]  ctrl_bresp, ctrl_rresp;
  logic [31:0] ctrl_rdata;
  wire in_aw = (s_axi_control_AWADDR >= 12'h100);
  wire in_ar = (s_axi_control_ARADDR >= 12'h100);

  assign ctrl_awaddr  = s_axi_control_AWADDR - 12'h100;
  assign ctrl_araddr  = s_axi_control_ARADDR - 12'h100;
  assign ctrl_awvalid = s_axi_control_AWVALID && s_axi_control_WVALID && in_aw;
  assign ctrl_wvalid  = ctrl_awvalid;
  assign ctrl_arvalid = s_axi_control_ARVALID && in_ar;

  assign s_axi_control_AWREADY = in_aw
      ? ctrl_awready
      : (s_axi_control_AWVALID && s_axi_control_WVALID && !local_bvalid);
  assign s_axi_control_WREADY  = in_aw
      ? ctrl_wready
      : (s_axi_control_AWVALID && s_axi_control_WVALID && !local_bvalid);
  assign s_axi_control_ARREADY = in_ar ? ctrl_arready : !local_rvalid;
  assign s_axi_control_BVALID  = sel_b ? ctrl_bvalid : local_bvalid;
  assign s_axi_control_BRESP   = sel_b ? ctrl_bresp : 2'b00;
  assign s_axi_control_RVALID  = sel_r ? ctrl_rvalid : local_rvalid;
  assign s_axi_control_RRESP   = sel_r ? ctrl_rresp : 2'b00;
  assign s_axi_control_RDATA   = sel_r ? ctrl_rdata : local_rdata;

  wire local_bgo = !in_aw && s_axi_control_AWVALID && s_axi_control_WVALID && !local_bvalid;
  wire local_rgo = !in_ar && s_axi_control_ARVALID && !local_rvalid;

  // ------------------------------------------------------------------ scratch AXI master
  typedef enum logic [2:0] {S_IDLE, S_AW, S_B, S_AR, S_R, S_DONE} state_t;
  state_t      st;
  logic [4:0]  idx;
  logic [63:0] base;
  logic [31:0] pat;
  logic        err, aw_done, w_done;

  logic [63:0]  sc_awaddr;  logic [7:0] sc_awlen;  logic [2:0] sc_awsize, sc_awburst;
  logic         sc_awvalid; logic       sc_awready;
  logic [511:0] sc_wdata;   logic [63:0] sc_wstrb; logic sc_wlast, sc_wvalid, sc_wready;
  logic [1:0]   sc_bresp;   logic sc_bvalid, sc_bready;
  logic [63:0]  sc_araddr;  logic [7:0] sc_arlen;  logic [2:0] sc_arsize, sc_arburst;
  logic         sc_arvalid; logic       sc_arready;
  logic [511:0] sc_rdata;   logic [1:0] sc_rresp;  logic sc_rvalid, sc_rready, sc_rlast;

  assign sc_awaddr  = base + (64'(idx) << 6);
  assign sc_awlen   = 8'd0;
  assign sc_awsize  = 3'd6;
  assign sc_awburst = 2'b01;
  assign sc_awvalid = (st == S_AW) && !aw_done;
  assign sc_wdata   = {16{pat}};
  assign sc_wstrb   = {64{1'b1}};
  assign sc_wlast   = 1'b1;
  assign sc_wvalid  = (st == S_AW) && !w_done;
  assign sc_bready  = (st == S_B);
  assign sc_araddr  = base + (64'(idx) << 6);
  assign sc_arlen   = 8'd0;
  assign sc_arsize  = 3'd6;
  assign sc_arburst = 2'b01;
  assign sc_arvalid = (st == S_AR);
  assign sc_rready  = (st == S_R);

  // ------------------------------------------------------------------ bandwidth registers
  logic [31:0] bw_ctrl, bw_n, bw_start, bw_status, bw_cycles, bw_beats, bw_mode, bw_write;
  logic [31:0] bw_n_lat, bw_start_lat, bw_issued, bw_returned, bw_cyc;
  logic [31:0] bw_ar_issued, bw_ar_stall, bw_cmd_stall, bw_max_out, bw_err_code_q;
  logic        bw_busy;
  logic [9:0]  bw_outstanding;
  logic [4:0]  bw_wout_pending;
  logic [2:0]  bw_err_code;
  logic        bw_wdata_valid, bw_wdata_ready;
  logic [511:0] bw_wdata_data;
  logic [63:0] bw_wdata_we;
  logic [31:0] bw_wdata_issued;
  logic        bw_cmd_valid, bw_cmd_ready, bw_cmd_we;
  logic [1:0]  bw_cmd_valid2, bw_cmd_ready2;
  logic [24:0] bw_cmd_addr;
  logic [1:0]  bw_wdata_valid2, bw_wdata_ready2;
  assign bw_cmd_valid2   = {1'b0, bw_cmd_valid};
  assign bw_wdata_valid2 = {1'b0, bw_wdata_valid};
  assign bw_cmd_ready    = bw_cmd_ready2[0];
  assign bw_wdata_ready  = bw_wdata_ready2[0];
  logic [1:0]  bw_rvalid;
  logic [1:0][511:0] bw_rdata;
  logic        bw_err;
  logic        bw_soft_rst;
  logic [3:0]  bw_rst_cnt;
  logic        bw_dbg_w_state;
  logic [5:0]  bw_dbg_w_idx, bw_dbg_w_blen, bw_dbg_w_win_n, bw_dbg_tag_pend;
  logic [6:0]  bw_dbg_cmd_count, bw_dbg_wd0, bw_dbg_wd1;

  // bridge AXI outputs
  logic [63:0]  bw_awaddr;  logic [7:0] bw_awlen;  logic [2:0] bw_awsize, bw_awburst;
  logic         bw_awvalid, bw_awready;
  logic [511:0] bw_wdata;   logic [63:0] bw_wstrb; logic bw_wlast, bw_wvalid, bw_wready;
  logic [1:0]   bw_bresp;   logic bw_bvalid, bw_bready;
  logic [63:0]  bw_araddr;  logic [7:0] bw_arlen;  logic [2:0] bw_arsize, bw_arburst;
  logic         bw_arvalid, bw_arready;
  logic [511:0] bw_rdata_axi; logic [1:0] bw_rresp; logic bw_rvalid_axi, bw_rready, bw_rlast;

  // ------------------------------------------------------------------ AXI mux: scratch or bridge
  assign m_axi_bank_0_AWADDR  = bw_mode[0] ? bw_awaddr  : sc_awaddr;
  assign m_axi_bank_0_AWLEN   = bw_mode[0] ? bw_awlen   : sc_awlen;
  assign m_axi_bank_0_AWSIZE  = bw_mode[0] ? bw_awsize  : sc_awsize;
  assign m_axi_bank_0_AWBURST = bw_mode[0] ? bw_awburst : sc_awburst;
  assign m_axi_bank_0_AWVALID = bw_mode[0] ? bw_awvalid : sc_awvalid;
  assign m_axi_bank_0_WDATA   = bw_mode[0] ? bw_wdata   : sc_wdata;
  assign m_axi_bank_0_WSTRB   = bw_mode[0] ? bw_wstrb   : sc_wstrb;
  assign m_axi_bank_0_WLAST   = bw_mode[0] ? bw_wlast   : sc_wlast;
  assign m_axi_bank_0_WVALID  = bw_mode[0] ? bw_wvalid  : sc_wvalid;
  assign m_axi_bank_0_BREADY  = bw_mode[0] ? bw_bready  : sc_bready;
  assign m_axi_bank_0_ARADDR  = bw_mode[0] ? bw_araddr  : sc_araddr;
  assign m_axi_bank_0_ARLEN   = bw_mode[0] ? bw_arlen   : sc_arlen;
  assign m_axi_bank_0_ARSIZE  = bw_mode[0] ? bw_arsize  : sc_arsize;
  assign m_axi_bank_0_ARBURST = bw_mode[0] ? bw_arburst : sc_arburst;
  assign m_axi_bank_0_ARVALID = bw_mode[0] ? bw_arvalid : sc_arvalid;
  assign m_axi_bank_0_RREADY  = bw_mode[0] ? bw_rready  : sc_rready;

  assign sc_awready  = !bw_mode[0] && m_axi_bank_0_AWREADY;
  assign sc_wready   = !bw_mode[0] && m_axi_bank_0_WREADY;
  assign sc_arready  = !bw_mode[0] && m_axi_bank_0_ARREADY;
  assign sc_bvalid   = !bw_mode[0] && m_axi_bank_0_BVALID;
  assign sc_bresp    = m_axi_bank_0_BRESP;
  assign sc_rvalid   = !bw_mode[0] && m_axi_bank_0_RVALID;
  assign sc_rdata    = m_axi_bank_0_RDATA;
  assign sc_rresp    = m_axi_bank_0_RRESP;
  assign sc_rlast    = m_axi_bank_0_RLAST;

  assign bw_awready  = bw_mode[0] && m_axi_bank_0_AWREADY;
  assign bw_wready   = bw_mode[0] && m_axi_bank_0_WREADY;
  assign bw_arready  = bw_mode[0] && m_axi_bank_0_ARREADY;
  assign bw_bvalid   = bw_mode[0] && m_axi_bank_0_BVALID;
  assign bw_bresp    = m_axi_bank_0_BRESP;
  assign bw_rvalid_axi = bw_mode[0] && m_axi_bank_0_RVALID;
  assign bw_rdata_axi  = m_axi_bank_0_RDATA;
  assign bw_rresp      = m_axi_bank_0_RRESP;
  assign bw_rlast      = m_axi_bank_0_RLAST;

  // ------------------------------------------------------------------ the AXI bridge
  otpu_axi_dram #(.CDEPTH(64), .WDEPTH(64), .ROUT(128), .WOUT(16), .MAXB(4), .WMAXB(32)) u_dram (
    .clk(ap_clk), .rst(!ap_rst_n || bw_soft_rst), .base({mem_hi, mem_lo}), .win(64'd0),
    .c_cmd_valid(bw_cmd_valid2), .c_cmd_ready(bw_cmd_ready2), .c_cmd_we(bw_cmd_we),
    .c_cmd_addr({bw_cmd_addr, bw_cmd_addr}),
    .c_wdata_valid(bw_wdata_valid2), .c_wdata_ready(bw_wdata_ready2),
    .c_wdata_data({bw_wdata_data, bw_wdata_data}), .c_wdata_we({bw_wdata_we, bw_wdata_we}),
    .c_rdata_valid(bw_rvalid), .c_rdata_data(bw_rdata), .err(bw_err),
    .dbg_outstanding(bw_outstanding), .dbg_wout_pending(bw_wout_pending),
    .dbg_err_code(bw_err_code),
    .dbg_w_state(bw_dbg_w_state), .dbg_w_idx(bw_dbg_w_idx), .dbg_w_blen(bw_dbg_w_blen),
    .dbg_w_win_n(bw_dbg_w_win_n), .dbg_cmd_count(bw_dbg_cmd_count),
    .dbg_wd_count0(bw_dbg_wd0), .dbg_wd_count1(bw_dbg_wd1), .dbg_tag_pend(bw_dbg_tag_pend),
    .m_axi_AWADDR(bw_awaddr), .m_axi_AWLEN(bw_awlen), .m_axi_AWSIZE(bw_awsize),
    .m_axi_AWBURST(bw_awburst), .m_axi_AWVALID(bw_awvalid), .m_axi_AWREADY(bw_awready),
    .m_axi_WDATA(bw_wdata), .m_axi_WSTRB(bw_wstrb), .m_axi_WLAST(bw_wlast),
    .m_axi_WVALID(bw_wvalid), .m_axi_WREADY(bw_wready),
    .m_axi_BRESP(bw_bresp), .m_axi_BVALID(bw_bvalid), .m_axi_BREADY(bw_bready),
    .m_axi_ARADDR(bw_araddr), .m_axi_ARLEN(bw_arlen), .m_axi_ARSIZE(bw_arsize),
    .m_axi_ARBURST(bw_arburst), .m_axi_ARVALID(bw_arvalid), .m_axi_ARREADY(bw_arready),
    .m_axi_RDATA(bw_rdata_axi), .m_axi_RRESP(bw_rresp), .m_axi_RVALID(bw_rvalid_axi),
    .m_axi_RREADY(bw_rready), .m_axi_RLAST(bw_rlast)
  );

  // ------------------------------------------------------------------ read traffic generator
  assign bw_cmd_valid = bw_busy && (bw_issued < bw_n_lat);
  assign bw_cmd_we    = bw_write[0];
  assign bw_cmd_addr  = bw_start_lat[24:0] + bw_issued[24:0];

  // Write data: a proper held stream. VALID/DATA stay stable until READY, and the beat
  // counter only advances on the handshake (the previous version changed DATA with bw_issued
  // while waiting, so backpressure could drop a beat and hang the last write burst).
  assign bw_wdata_valid = bw_busy && bw_write[0] && (bw_wdata_issued < bw_n_lat);
  assign bw_wdata_data  = {16{32'hA5A5_0000 | bw_wdata_issued[15:0]}};
  assign bw_wdata_we    = {64{1'b1}};

  // ------------------------------------------------------------------ registers + FSMs
  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n) begin
      mem_lo <= '0; mem_hi <= '0; pattern_q <= '0; ctrl_q <= '0; status_q <= '0;
      local_bvalid <= 1'b0; local_rvalid <= 1'b0; raddr_lat <= '0;
      sel_b <= 1'b0; sel_r <= 1'b0;
      st <= S_IDLE; idx <= '0; base <= '0; pat <= '0; err <= 1'b0;
      aw_done <= 1'b0; w_done <= 1'b0;
      bw_ctrl <= '0; bw_n <= '0; bw_start <= '0; bw_status <= '0;
      bw_cycles <= '0; bw_beats <= '0; bw_mode <= '0;
      bw_n_lat <= '0; bw_start_lat <= '0; bw_issued <= '0; bw_returned <= '0;
      bw_cyc <= '0; bw_busy <= 1'b0;
      bw_ar_issued <= '0; bw_ar_stall <= '0; bw_cmd_stall <= '0;
      bw_max_out <= '0; bw_err_code_q <= '0;
      bw_wdata_issued <= '0; bw_write <= '0;
      bw_soft_rst <= 1'b0; bw_rst_cnt <= '0;
    end else begin
      // AXI-Lite B/R completion and selection latches
      if (local_bvalid && s_axi_control_BREADY) local_bvalid <= 1'b0;
      if (local_rvalid && s_axi_control_RREADY) local_rvalid <= 1'b0;
      if (ctrl_awvalid && ctrl_awready) sel_b <= 1'b1;
      if (ctrl_arvalid && ctrl_arready) sel_r <= 1'b1;

      // bridge soft reset: hold for 16 cycles after a write to 0x58
      if (bw_rst_cnt != 4'd0) begin
        bw_rst_cnt <= bw_rst_cnt - 1'b1;
        if (bw_rst_cnt == 4'd1) bw_soft_rst <= 1'b0;
      end
      if (bw_soft_rst) begin
        bw_busy <= 1'b0;
        bw_ctrl[0] <= 1'b0;
      end

      // local control writes (0x10..0x3C)
      if (local_bgo) begin
        local_bvalid <= 1'b1;
        sel_b <= 1'b0;
        case (s_axi_control_AWADDR[7:2])
          6'h04: mem_lo    <= s_axi_control_WDATA;   // 0x10
          6'h05: mem_hi    <= s_axi_control_WDATA;   // 0x14
          6'h06: ctrl_q    <= s_axi_control_WDATA;   // 0x18
          6'h08: pattern_q <= s_axi_control_WDATA;   // 0x20
          6'h09: bw_ctrl   <= s_axi_control_WDATA;   // 0x24
          6'h0A: bw_n      <= s_axi_control_WDATA;   // 0x28
          6'h0B: bw_start  <= s_axi_control_WDATA;   // 0x2C
          6'h0F: bw_mode   <= s_axi_control_WDATA;   // 0x3C
          6'h15: bw_write  <= s_axi_control_WDATA;   // 0x54
          6'h16: begin bw_soft_rst <= 1'b1; bw_rst_cnt <= 4'hF; end  // 0x58
          default: ;
        endcase
      end
      if (local_rgo) begin
        local_rvalid <= 1'b1;
        raddr_lat <= s_axi_control_ARADDR;
        sel_r <= 1'b0;
      end

      // scratch engine
      case (st)
        S_IDLE: begin
          if (ctrl_q[0]) begin
            base    <= {mem_hi, mem_lo};
            pat     <= pattern_q;
            idx     <= '0;
            err     <= 1'b0;
            aw_done <= 1'b0;
            w_done  <= 1'b0;
            status_q <= '0;
            ctrl_q[0] <= 1'b0;
            st      <= S_AW;
          end
        end
        S_AW: begin
          if (sc_awready) aw_done <= 1'b1;
          if (sc_wready)  w_done  <= 1'b1;
          if ((aw_done || sc_awready) && (w_done || sc_wready)) st <= S_B;
        end
        S_B: begin
          if (sc_bvalid) begin
            if (sc_bresp != 2'b00) err <= 1'b1;
            st <= S_AR;
          end
        end
        S_AR: begin
          if (sc_arready) st <= S_R;
        end
        S_R: begin
          if (sc_rvalid) begin
            if (sc_rresp != 2'b00 || sc_rdata != {16{pat}}) err <= 1'b1;
            if (idx == 5'd15) begin
              st <= S_DONE;
            end else begin
              idx     <= idx + 1'b1;
              aw_done <= 1'b0;
              w_done  <= 1'b0;
              st      <= S_AW;
            end
          end
        end
        S_DONE: begin
          status_q <= 32'h1 | (err ? 32'h2 : 32'h0);
          st <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase

      // read traffic generator
      if (bw_ctrl[0] && !bw_busy) begin
        bw_busy       <= 1'b1;
        bw_n_lat      <= bw_n;
        bw_start_lat  <= bw_start;
        bw_issued     <= '0;
        bw_returned   <= '0;
        bw_cyc        <= '0;
        bw_status     <= '0;
        bw_ar_issued  <= '0;
        bw_ar_stall   <= '0;
        bw_cmd_stall  <= '0;
        bw_max_out    <= '0;
        bw_err_code_q <= '0;
        bw_wdata_issued <= '0;
        bw_ctrl[0]    <= 1'b0;
      end else if (bw_busy) begin
        bw_cyc <= bw_cyc + 1'b1;
        if (bw_cmd_valid && bw_cmd_ready) bw_issued <= bw_issued + 1'b1;
        if (bw_arvalid && bw_arready)  bw_ar_issued  <= bw_ar_issued + 1'b1;
        if (bw_arvalid && !bw_arready) bw_ar_stall   <= bw_ar_stall + 1'b1;
        if (bw_cmd_valid && !bw_cmd_ready) bw_cmd_stall <= bw_cmd_stall + 1'b1;
        if ({22'd0, bw_outstanding} > bw_max_out) bw_max_out <= {22'd0, bw_outstanding};
        bw_err_code_q <= {29'd0, bw_err_code};
        if (bw_wdata_valid && bw_wdata_ready) bw_wdata_issued <= bw_wdata_issued + 1'b1;
        if (bw_write[0]) begin
          if ((bw_issued == bw_n_lat) && (bw_wdata_issued == bw_n_lat) &&
              (bw_wout_pending == 5'd0)) begin
            bw_busy   <= 1'b0;
            bw_status[0] <= 1'b1;
            bw_cycles <= bw_cyc + 1'b1;
            bw_beats  <= bw_issued;
          end
        end else if (bw_rvalid[0] || bw_rvalid[1]) begin
          if (bw_returned + 1'b1 == bw_n_lat) begin
            bw_busy   <= 1'b0;
            bw_status[0] <= 1'b1;
            bw_cycles <= bw_cyc + 1'b1;
            bw_beats  <= bw_returned + 1'b1;
          end
          bw_returned <= bw_returned + 1'b1;
        end
      end
      if (bw_err) bw_status[1] <= 1'b1;
    end
  end

  // local read mux
  always_comb begin
    case (raddr_lat[7:2])
      6'h04:   local_rdata = mem_lo;
      6'h05:   local_rdata = mem_hi;
      6'h06:   local_rdata = ctrl_q;
      6'h07:   local_rdata = status_q;
      6'h08:   local_rdata = pattern_q;
      6'h09:   local_rdata = bw_ctrl;
      6'h0A:   local_rdata = bw_n;
      6'h0B:   local_rdata = bw_start;
      6'h0C:   local_rdata = bw_status;
      6'h0D:   local_rdata = bw_cycles;
      6'h0E:   local_rdata = bw_beats;
      6'h0F:   local_rdata = bw_mode;
      6'h10:   local_rdata = bw_ar_issued;
      6'h11:   local_rdata = bw_ar_stall;
      6'h12:   local_rdata = bw_cmd_stall;
      6'h13:   local_rdata = bw_max_out;
      6'h14:   local_rdata = bw_err_code_q;
      6'h15:   local_rdata = bw_write;
      6'h17:   local_rdata = {bw_dbg_w_state, bw_dbg_w_blen, bw_dbg_w_idx,
                              bw_dbg_w_win_n, 13'd0};
      6'h18:   local_rdata = {bw_wout_pending, bw_dbg_tag_pend, bw_dbg_cmd_count,
                              bw_dbg_wd0, bw_dbg_wd1};
      6'h19:   local_rdata = bw_issued;
      6'h1A:   local_rdata = bw_wdata_issued;
      6'h1B:   local_rdata = {31'd0, bw_soft_rst};
      default: local_rdata = 32'h0;
    endcase
  end

  // ------------------------------------------------------------------ otpu_ctrl at 0x100
  logic [31:0] unused_arg [8];
  logic        unused_run, unused_ld_start, unused_tr_en, unused_tr_stop, unused_tr_clear;
  logic [31:0] unused_ld_addr, unused_ld_n, unused_tr_addr;
  logic [3:0]  unused_i2c_lo;

  otpu_ctrl #(
    .D(128), .MCOLS(4), .LANES(8), .ACT_ROWS(4),
    .CORE_KHZ(300000), .BUILD_ID(32'h0), .DDR_MTS(2400),
    .TRACE_DEPTH(0), .PQ_WIN(1024),
    .HAS_TEMP(1'b0), .HAS_I2C(1'b0), .CHASH(1'b1), .DSTEP(1'b1), .HOSTCAL(1'b0),
    .COLL_GATHER(1'b0), .LDP(2),
    .S(1), .TMEM_WORDS(65536), .IMEM_WORDS(32768), .ACT_BLOCKS(128),
    .DRAM_LOG2(32), .NCH(2), .CH_LOG2(31),
    .MXU_IMPL(2), .TMEM_IMPL(0), .VPU_CL(2), .ULANES(8),
    .SEQ_WC(1'b0), .PLATFORM(4), .ARCH_HASH(32'h0)
  ) u_ctrl (
    .clk(ap_clk), .rst(!ap_rst_n),
    .s_awaddr(ctrl_awaddr), .s_awvalid(ctrl_awvalid), .s_awready(ctrl_awready),
    .s_wdata(s_axi_control_WDATA), .s_wstrb(s_axi_control_WSTRB),
    .s_wvalid(ctrl_wvalid), .s_wready(ctrl_wready),
    .s_bresp(ctrl_bresp), .s_bvalid(ctrl_bvalid), .s_bready(s_axi_control_BREADY),
    .s_araddr(ctrl_araddr), .s_arvalid(ctrl_arvalid), .s_arready(ctrl_arready),
    .s_rdata(ctrl_rdata), .s_rresp(ctrl_rresp), .s_rvalid(ctrl_rvalid),
    .s_rready(s_axi_control_RREADY),
    .run(unused_run), .ld_start(unused_ld_start), .arg(unused_arg),
    .ld_addr(unused_ld_addr), .ld_n(unused_ld_n),
    .ld_busy(1'b0), .halted(1'b0), .error(1'b0), .wait_to(1'b0),
    .icount('0), .wr_idle(1'b1), .axi_err(1'b0), .calib(2'b11), .ecc_ded(1'b0),
    .b_rd(1'b0), .b_wr(1'b0), .a_rd(1'b0), .a_wr(1'b0), .b_wait(1'b0),
    .temp_v(1'b0), .temp(12'd0),
    .mxu_busy(1'b0), .mxu_mac(1'b0), .vpu_busy(1'b0), .qnt_busy(1'b0),
    .dma_busy(1'b0), .tmem_deny(1'b0), .mxu_starve(1'b0),
    .dram_rd('0), .dram_wr('0), .dram_wait(1'b0), .instr('0),
    .tr_en(unused_tr_en), .tr_stop(unused_tr_stop), .tr_clear(unused_tr_clear),
    .tr_addr(unused_tr_addr), .tr_count(32'd0), .tr_drop(32'd0),
    .tr_busy(1'b0), .tr_rdata(64'd0),
    .i2c_lo(unused_i2c_lo), .i2c_in(5'd0)
  );

endmodule
