// Kernel-top testbench: replays the host's AXI-Lite register sequence against the real
// OtpuKernel + AXI memory model, with AXI4 protocol checks. This covers the layer the
// bridge-only unit TBs miss: kernel port widths, control mux, reset, and the host order.
`timescale 1ns/1ps
module tb_kernel_bw;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0;

  // AXI-Lite control
  logic [11:0] awaddr = 0, araddr = 0;
  logic        awvalid = 0, wvalid = 0, arvalid = 0;
  logic [31:0] wdata = 0;
  logic [3:0]  wstrb = 4'hF;
  wire         awready, wready, bvalid, arready, rvalid;
  wire [1:0]   bresp, rresp;
  wire [31:0]  rdata;

  // AXI master
  wire [63:0]  m_awaddr, m_araddr;
  wire [7:0]   m_awlen, m_arlen;
  wire [2:0]   m_awsize, m_awburst, m_arsize, m_arburst;
  wire         m_awvalid, m_awready, m_wvalid, m_wready, m_wlast;
  wire [511:0] m_wdata;
  wire [63:0]  m_wstrb;
  wire [1:0]   m_bresp, m_rresp;
  wire         m_bvalid, m_bready, m_arvalid, m_arready, m_rvalid, m_rready, m_rlast;
  wire [511:0] m_rdata;

  OtpuKernel dut (
    .ap_clk(clk), .ap_rst_n(rst_n),
    .s_axi_control_AWADDR(awaddr), .s_axi_control_AWVALID(awvalid),
    .s_axi_control_AWREADY(awready), .s_axi_control_WDATA(wdata),
    .s_axi_control_WSTRB(wstrb), .s_axi_control_WVALID(wvalid),
    .s_axi_control_WREADY(wready), .s_axi_control_BRESP(bresp),
    .s_axi_control_BVALID(bvalid), .s_axi_control_BREADY(1'b1),
    .s_axi_control_ARADDR(araddr), .s_axi_control_ARVALID(arvalid),
    .s_axi_control_ARREADY(arready), .s_axi_control_RDATA(rdata),
    .s_axi_control_RRESP(rresp), .s_axi_control_RVALID(rvalid),
    .s_axi_control_RREADY(1'b1),
    .m_axi_bank_0_AWADDR(m_awaddr), .m_axi_bank_0_AWLEN(m_awlen),
    .m_axi_bank_0_AWSIZE(m_awsize), .m_axi_bank_0_AWBURST(m_awburst),
    .m_axi_bank_0_AWVALID(m_awvalid), .m_axi_bank_0_AWREADY(m_awready),
    .m_axi_bank_0_WDATA(m_wdata), .m_axi_bank_0_WSTRB(m_wstrb),
    .m_axi_bank_0_WLAST(m_wlast), .m_axi_bank_0_WVALID(m_wvalid),
    .m_axi_bank_0_WREADY(m_wready), .m_axi_bank_0_BRESP(m_bresp),
    .m_axi_bank_0_BVALID(m_bvalid), .m_axi_bank_0_BREADY(m_bready),
    .m_axi_bank_0_ARADDR(m_araddr), .m_axi_bank_0_ARLEN(m_arlen),
    .m_axi_bank_0_ARSIZE(m_arsize), .m_axi_bank_0_ARBURST(m_arburst),
    .m_axi_bank_0_ARVALID(m_arvalid), .m_axi_bank_0_ARREADY(m_arready),
    .m_axi_bank_0_RDATA(m_rdata), .m_axi_bank_0_RRESP(m_rresp),
    .m_axi_bank_0_RVALID(m_rvalid), .m_axi_bank_0_RREADY(m_rready),
    .m_axi_bank_0_RLAST(m_rlast));

  axi_mem_model #(.WORDS(1<<16)) mem (
    .clk(clk), .rst(!rst_n),
    .s_awaddr(m_awaddr), .s_awlen(m_awlen), .s_awsize(m_awsize),
    .s_awburst(m_awburst), .s_awvalid(m_awvalid), .s_awready(m_awready),
    .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast),
    .s_wvalid(m_wvalid), .s_wready(m_wready),
    .s_bresp(m_bresp), .s_bvalid(m_bvalid), .s_bready(m_bready),
    .s_araddr(m_araddr), .s_arlen(m_arlen), .s_arsize(m_arsize),
    .s_arburst(m_arburst), .s_arvalid(m_arvalid), .s_arready(m_arready),
    .s_rdata(m_rdata), .s_rresp(m_rresp), .s_rlast(m_rlast),
    .s_rvalid(m_rvalid), .s_rready(m_rready));

  int errors = 0;
  task automatic fail(input string msg);
    begin errors++; $display("FAIL: %s @%0t", msg, $time); end
  endtask

  // AXI4 protocol checks on the master side
  logic        aw_stall = 0, w_stall = 0, ar_stall = 0;
  logic [63:0] aw_addr_q; logic [7:0] aw_len_q;
  logic        aw_seen = 0;
  int          wbeats = 0;
  always @(posedge clk) begin
    if (!rst_n) begin aw_seen <= 0; wbeats <= 0; aw_stall <= 0; w_stall <= 0; ar_stall <= 0; end
    else begin
      if (aw_stall && !m_awvalid) fail("AWVALID dropped before AWREADY");
      if (w_stall  && !m_wvalid)  fail("WVALID dropped before WREADY");
      if (ar_stall && !m_arvalid) fail("ARVALID dropped before ARREADY");
      aw_stall <= m_awvalid && !m_awready;
      w_stall  <= m_wvalid  && !m_wready;
      ar_stall <= m_arvalid && !m_arready;

      if (m_awvalid && m_awready) begin
        if (^{m_awaddr, m_awlen, m_awsize, m_awburst} === 1'bx) fail("X on AW");
        aw_addr_q <= m_awaddr; aw_len_q <= m_awlen; aw_seen <= 1; wbeats <= 0;
      end
      if (m_wvalid && m_wready) begin
        if (^{m_wdata, m_wstrb, m_wlast} === 1'bx) fail("X on W");
        if (!aw_seen) fail("W beat before AW");
        wbeats <= wbeats + 1;
        if (m_wlast && (wbeats != aw_len_q))
          fail($sformatf("WLAST at beat %0d, AWLEN=%0d", wbeats, aw_len_q));
        if (m_wlast) aw_seen <= 0;
      end
      if (m_arvalid && m_arready) begin
        if (^{m_araddr, m_arlen, m_arsize, m_arburst} === 1'bx) fail("X on AR");
      end
      if (m_rvalid && m_rready && (^{m_rdata, m_rresp, m_rlast} === 1'bx)) fail("X on R");
    end
  end

  // ---------------- AXI-Lite host tasks ----------------
  task automatic axil_write(input [11:0] addr, input [31:0] data);
    begin
      @(negedge clk);
      awaddr = addr; awvalid = 1; wdata = data; wvalid = 1;
      while (!(awready && wready)) @(negedge clk);
      @(posedge clk);
      awvalid = 0; wvalid = 0;
      while (!bvalid) @(negedge clk);
      @(posedge clk);
    end
  endtask

  task automatic axil_read(input [11:0] addr, output [31:0] data);
    begin
      @(negedge clk);
      araddr = addr; arvalid = 1;
      while (!arready) @(negedge clk);
      @(posedge clk);
      arvalid = 0;
      while (!rvalid) @(negedge clk);
      data = rdata;
      @(posedge clk);
    end
  endtask

  task automatic wait_done(input [31:0] max_cycles, output [31:0] status,
                           output [31:0] cycles, output [31:0] beats);
    int i;
    begin
      status = 0;
      for (i = 0; i < max_cycles; i++) begin
        axil_read(12'h030, status);
        if (status[0] || status[1]) break;
      end
      axil_read(12'h034, cycles);
      axil_read(12'h038, beats);
    end
  endtask

  task automatic dump_dbg(input string tag);
    logic [31:0] v0, v1, iss, wdi, rstb, st, cyc, bts, cst, ec;
    begin
      axil_read(12'h030, st); axil_read(12'h034, cyc); axil_read(12'h038, bts);
      axil_read(12'h048, cst); axil_read(12'h050, ec);
      axil_read(12'h05C, v0); axil_read(12'h060, v1);
      axil_read(12'h064, iss); axil_read(12'h068, wdi); axil_read(12'h06C, rstb);
      $display("%s: status=%h cycles=%0d beats=%0d cmd_stall=%0d err=%0d",
               tag, st, cyc, bts, cst, ec);
      $display("  dbg0=%h dbg1=%h issued=%0d wdata_issued=%0d rst_busy=%0d",
               v0, v1, iss, wdi, rstb);
      $display("  dbg0: w_state=%b w_blen=%0d w_idx=%0d w_win_n=%0d",
               v0[31], v0[30:25], v0[24:19], v0[18:13]);
      $display("  dbg1: wout=%0d tag_pend=%0d cmd_count=%0d wd0=%0d wd1=%0d",
               v1[31:27], v1[26:21], v1[20:14], v1[13:7], v1[6:0]);
      $display("  kern: busy=%b write=%b wdv=%b wdr=%b nlat=%0d wdi=%0d",
               dut.bw_busy, dut.bw_write[0], dut.bw_wdata_valid, dut.bw_wdata_ready,
               dut.bw_n_lat, dut.bw_wdata_issued);
      $display("  bridge: wport=%0d ports=%h wd0=%0d wdav=%b wvalid=%b awv=%b awr=%b",
               dut.u_dram.w_port, dut.u_dram.w_burst_ports, dut.u_dram.wd_count[0],
               dut.u_dram.w_data_avail, dut.u_dram.m_axi_WVALID,
               dut.u_dram.m_axi_AWVALID, dut.u_dram.m_axi_AWREADY);
    end
  endtask

  task automatic run_mode(input string name, input int is_write, input int n);
    logic [31:0] st, cyc, bts;
    begin
      $display("== %s run: n=%0d ==", name, n);
      // full kernel reset between modes (matches a fresh xclbin/host invocation)
      rst_n = 0; repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);
      axil_write(12'h058, 1);          // bridge soft reset
      repeat (30) @(posedge clk);
      axil_write(12'h010, 0); axil_write(12'h014, 0);
      axil_write(12'h03C, 1);          // bridge owns m_axi_bank_0
      axil_write(12'h054, is_write);
      axil_write(12'h028, n);
      axil_write(12'h02C, 0);
      axil_write(12'h024, 1);
      wait_done(200000, st, cyc, bts);
      if (st[1]) fail($sformatf("%s: status error", name));
      if (!st[0]) fail($sformatf("%s: timeout", name));
      if (bts != n) fail($sformatf("%s: beats %0d != %0d", name, bts, n));
      dump_dbg(name);
      $display("%s: %.2f GB/s at 100 MHz sim clk (cycles=%0d)", name,
               (cyc != 0) ? real'(bts) * 64.0 * 100e6 / real'(cyc) / 1e9 : 0.0, cyc);
    end
  endtask

  initial begin
    // reset
    rst_n = 0; repeat (10) @(posedge clk); rst_n = 1; repeat (10) @(posedge clk);
    $display("kernel-top bandwidth TB: reset done");

    run_mode("write", 1, 4096);
    run_mode("read",  0, 4096);

    if (errors == 0) $display("PASS: kernel-top bandwidth TB");
    else             $display("FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #5000000;
    $display("FAIL: global timeout");
    $finish;
  end
endmodule
