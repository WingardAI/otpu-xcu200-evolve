// New in the XCU200 port (WingardAI, 2026) for openTPU,
// https://github.com/FeSens/openTPU (Apache-2.0). See NOTICE.

// Unit testbench for otpu_axi_dram: native-port commands/data vs the AXI memory model.
//   iverilog -g2012 -o /tmp/tb_axi_dram sim/verilator/tb_axi_dram.sv \
//       sim/verilator/axi_mem_model.sv rtl/mem/otpu_axi_dram.sv && vvp /tmp/tb_axi_dram
//
// Tests: port-0 / port-1 writes then reads; interleaved ports; back-to-back reads (outstanding
// ARs and the port-tag FIFO); a partial WSTRB; direction changes (write/read/write); the pool
// window (a beat in the top 1 GiB of a channel names `win` instead of `base`: docs/u200.md
// 3c).
`timescale 1ns/1ps

module tb_axi_dram;
  logic clk = 0;
  logic rst = 1;
  always #5 clk = ~clk;

  // native (controller side)
  logic [1:0]        c_cmd_valid;
  logic [1:0]        c_cmd_ready;
  logic [1:0]        c_cmd_we;
  logic [1:0][24:0]  c_cmd_addr;
  logic [1:0]        c_wdata_valid;
  logic [1:0]        c_wdata_ready;
  logic [1:0][511:0] c_wdata_data;
  logic [1:0][63:0]  c_wdata_we;
  logic [1:0]        c_rdata_valid;
  logic [1:0][511:0] c_rdata_data;
  logic              err;
  logic [9:0]        dbg_out;
  logic [4:0]        dbg_wout;
  logic [2:0]        dbg_err;

  // AXI
  logic [63:0]  m_awaddr;  logic [7:0] m_awlen; logic [2:0] m_awsize;
  logic [2:0]   m_awburst; logic       m_awvalid, m_awready;
  logic [511:0] m_wdata;   logic [63:0] m_wstrb; logic m_wlast, m_wvalid, m_wready;
  logic [1:0]   m_bresp;   logic m_bvalid, m_bready;
  logic [63:0]  m_araddr;  logic [7:0] m_arlen; logic [2:0] m_arsize;
  logic [2:0]   m_arburst; logic m_arvalid, m_arready;
  logic [511:0] m_rdata;   logic [1:0] m_rresp; logic m_rvalid, m_rready, m_rlast;

  logic [63:0] win_addr = 64'd0;
  otpu_axi_dram #(.CDEPTH(16), .WDEPTH(8), .ROUT(8), .WOUT(4)) dut (
    .clk, .rst, .base(64'd0), .win(win_addr),
    .c_cmd_valid, .c_cmd_ready, .c_cmd_we, .c_cmd_addr,
    .c_wdata_valid, .c_wdata_ready, .c_wdata_data, .c_wdata_we,
    .c_rdata_valid, .c_rdata_data, .err,
    .dbg_outstanding(dbg_out), .dbg_wout_pending(dbg_wout), .dbg_err_code(dbg_err),
    .m_axi_AWADDR(m_awaddr), .m_axi_AWLEN(m_awlen), .m_axi_AWSIZE(m_awsize),
    .m_axi_AWBURST(m_awburst), .m_axi_AWVALID(m_awvalid), .m_axi_AWREADY(m_awready),
    .m_axi_WDATA(m_wdata), .m_axi_WSTRB(m_wstrb), .m_axi_WLAST(m_wlast),
    .m_axi_WVALID(m_wvalid), .m_axi_WREADY(m_wready),
    .m_axi_BRESP(m_bresp), .m_axi_BVALID(m_bvalid), .m_axi_BREADY(m_bready),
    .m_axi_ARADDR(m_araddr), .m_axi_ARLEN(m_arlen), .m_axi_ARSIZE(m_arsize),
    .m_axi_ARBURST(m_arburst), .m_axi_ARVALID(m_arvalid), .m_axi_ARREADY(m_arready),
    .m_axi_RDATA(m_rdata), .m_axi_RRESP(m_rresp), .m_axi_RVALID(m_rvalid),
    .m_axi_RREADY(m_rready), .m_axi_RLAST(m_rlast)
  );

  axi_mem_model #(.WORDS(1 << 12), .RQD(64)) u_mem (
    .clk, .rst,
    .s_awaddr(m_awaddr), .s_awlen(m_awlen), .s_awsize(m_awsize),
    .s_awburst(m_awburst), .s_awvalid(m_awvalid), .s_awready(m_awready),
    .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast),
    .s_wvalid(m_wvalid), .s_wready(m_wready),
    .s_bresp(m_bresp), .s_bvalid(m_bvalid), .s_bready(m_bready),
    .s_araddr(m_araddr), .s_arlen(m_arlen), .s_arsize(m_arsize),
    .s_arburst(m_arburst), .s_arvalid(m_arvalid), .s_arready(m_arready),
    .s_rdata(m_rdata), .s_rresp(m_rresp), .s_rvalid(m_rvalid),
    .s_rready(m_rready), .s_rlast(m_rlast), .dump(1'b0)
  );

  function automatic logic [511:0] data_for(input logic [24:0] a);
    return {16{32'hA5A5_0000 | {7'd0, a}}};
  endfunction

  // AXI read-burst monitor: proves the bridge coalesces (fewer ARs than native reads).
  int ar_count = 0;
  int ar_beats = 0;
  logic [63:0] seen_aw = 'x, seen_ar = 'x;    // the last AXI address the bridge drove
  always @(posedge clk) begin
    if (m_awvalid && m_awready) seen_aw <= m_awaddr;
    if (m_arvalid && m_arready) seen_ar <= m_araddr;
  end
  always @(posedge clk) begin
    if (m_arvalid && m_arready) begin
      ar_count++;
      ar_beats += m_arlen + 1;
      if (m_arlen != 0) $display("INFO: AR burst addr=%h beats=%0d", m_araddr, m_arlen + 1);
    end
  end

  int failures = 0;
  always @(posedge clk) begin
    if (dut.w_state)
      $display("WDBG st=%0d idx=%0d blen=%0d wd0=%0d wd1=%0d wout=%0d cready=%b wready=%b awv=%b awr=%b wv=%b wr=%b bv=%b",
               dut.w_state, dut.w_idx, dut.w_blen_q, dut.wd_count[0], dut.wd_count[1],
               dut.wout_pending, dut.c_cmd_ready, dut.c_wdata_ready,
               dut.m_axi_AWVALID, dut.m_axi_AWREADY,
               dut.m_axi_WVALID, dut.m_axi_WREADY, dut.m_axi_BVALID);
  end
  // the bridge drives AXI a cycle or two after it takes a command: wait for the address
  task automatic want_aw(input logic [63:0] exp, input string name);
    int i = 0;
    begin
      while (seen_aw !== exp && i < 400) begin @(posedge clk); i++; end
      if (seen_aw !== exp) begin
        failures++; $display("FAIL %s: aw got %h exp %h", name, seen_aw, exp);
      end
    end
  endtask
  task automatic want_ar(input logic [63:0] exp, input string name);
    int i = 0;
    begin
      while (seen_ar !== exp && i < 400) begin @(posedge clk); i++; end
      if (seen_ar !== exp) begin
        failures++; $display("FAIL %s: ar got %h exp %h", name, seen_ar, exp);
      end
    end
  endtask
  task automatic check(input string name, input logic [511:0] got, input logic [511:0] exp);
    begin
      if (got !== exp) begin
        failures++;
        $display("FAIL %s: got %h exp %h", name, got, exp);
      end
    end
  endtask

  // drive one write; command and data may be accepted in different cycles
  task automatic wr(input int port, input logic [24:0] addr, input logic [511:0] data,
                    input logic [63:0] mask);
    logic cmd_done, w_done, cmd_go, w_go;
    begin
      @(negedge clk);
      c_cmd_valid[port] = 1; c_cmd_we[port] = 1; c_cmd_addr[port] = addr;
      c_wdata_valid[port] = 1; c_wdata_data[port] = data; c_wdata_we[port] = mask;
      cmd_done = 0; w_done = 0;
      while (!(cmd_done && w_done)) begin
        cmd_go = !cmd_done && c_cmd_ready[port];
        w_go   = !w_done   && c_wdata_ready[port];
        if (cmd_go || w_go) begin
          @(posedge clk);
          if (cmd_go) begin c_cmd_valid[port] = 0; cmd_done = 1; end
          if (w_go)   begin c_wdata_valid[port] = 0; w_done = 1; end
        end
        if (!(cmd_done && w_done)) @(negedge clk);
      end
    end
  endtask

  // issue one read and return its data
  task automatic rd(input int port, input logic [24:0] addr, output logic [511:0] data);
    begin
      @(negedge clk);
      c_cmd_valid[port] = 1; c_cmd_we[port] = 0; c_cmd_addr[port] = addr;
      while (!c_cmd_ready[port]) @(negedge clk);
      @(posedge clk);
      c_cmd_valid[port] = 0;
      @(negedge clk);
      while (!c_rdata_valid[port]) @(negedge clk);
      data = c_rdata_data[port];
    end
  endtask

  // issue N back-to-back writes; the bridge should coalesce them into AW/W bursts
  task automatic wr_burst(input int port, input int n, input logic [24:0] first);
    logic cmd_done, w_done, cmd_go, w_go;
    begin
      for (int i = 0; i < n; i++) begin
        @(negedge clk);
        c_cmd_valid[port] = 1; c_cmd_we[port] = 1; c_cmd_addr[port] = first + i;
        c_wdata_valid[port] = 1; c_wdata_data[port] = data_for(first + i);
        c_wdata_we[port] = {64{1'b1}};
        cmd_done = 0; w_done = 0;
        while (!(cmd_done && w_done)) begin
          cmd_go = !cmd_done && c_cmd_ready[port];
          w_go   = !w_done   && c_wdata_ready[port];
          if (cmd_go || w_go) begin
            @(posedge clk);
            if (cmd_go) begin c_cmd_valid[port] = 0; cmd_done = 1; end
            if (w_go)   begin c_wdata_valid[port] = 0; w_done = 1; end
          end
          if (!(cmd_done && w_done)) @(negedge clk);
        end
      end
    end
  endtask

  // issue N reads back-to-back on one port, then collect them in order
  task automatic rd_burst(input int port, input int n, input logic [24:0] first);
    logic [511:0] d;
    begin
      fork
        begin
          for (int i = 0; i < n; i++) begin
            @(negedge clk);
            c_cmd_valid[port] = 1; c_cmd_we[port] = 0; c_cmd_addr[port] = first + i;
            while (!c_cmd_ready[port]) @(negedge clk);
            @(posedge clk);
            c_cmd_valid[port] = 0;
          end
        end
        begin
          for (int i = 0; i < n; i++) begin
            @(negedge clk);
            while (!c_rdata_valid[port]) @(negedge clk);
            d = c_rdata_data[port];
            check($sformatf("rd_burst p%0d [%0d]", port, i), d, data_for(first + i));
          end
        end
      join
    end
  endtask

  initial begin
    c_cmd_valid = '0; c_cmd_we = '0; c_cmd_addr = '0;
    c_wdata_valid = '0; c_wdata_data = '0; c_wdata_we = '0;
    repeat (4) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    // 1. port 0: write then read 16 beats
    for (int i = 0; i < 16; i++) wr(0, i[24:0], data_for(i), {64{1'b1}});
    for (int i = 0; i < 16; i++) begin
      logic [511:0] d;
      rd(0, i[24:0], d);
      check($sformatf("p0 w/r [%0d]", i), d, data_for(i));
    end

    // 2. port 1: write then read 8 beats
    for (int i = 0; i < 8; i++) wr(1, 25'd32 + i[24:0], data_for(25'd32 + i[24:0]), {64{1'b1}});
    for (int i = 0; i < 8; i++) begin
      logic [511:0] d;
      rd(1, 25'd32 + i[24:0], d);
      check($sformatf("p1 w/r [%0d]", i), d, data_for(25'd32 + i[24:0]));
    end

    // 3. interleaved ports
    wr(0, 25'd64, data_for(25'd64), {64{1'b1}});
    wr(1, 25'd65, data_for(25'd65), {64{1'b1}});
    begin
      logic [511:0] d0, d1;
      rd(0, 25'd64, d0);
      rd(1, 25'd65, d1);
      check("interleave p0", d0, data_for(25'd64));
      check("interleave p1", d1, data_for(25'd65));
    end

    // 4. back-to-back reads (outstanding ARs, tag order, burst coalescing)
    for (int i = 0; i < 16; i++) wr(0, 25'd96 + i[24:0], data_for(25'd96 + i[24:0]), {64{1'b1}});
    rd_burst(0, 16, 25'd96);

    // 4b. coalescing must clamp at the 4 KB page boundary: beat 63 is the last beat of a page
    for (int i = 0; i < 16; i++) wr(0, 25'd63 + i[24:0], data_for(25'd63 + i[24:0]), {64{1'b1}});
    rd_burst(0, 16, 25'd63);

    // 4c. write-burst coalescing (16 beats, and a 4 KB boundary at beat 63)
    wr_burst(0, 16, 25'd256);
    for (int i = 0; i < 16; i++) begin
      logic [511:0] d;
      rd(0, 25'd256 + i[24:0], d);
      check($sformatf("wr_burst [%0d]", i), d, data_for(25'd256 + i[24:0]));
    end
    wr_burst(0, 16, 25'd63);
    for (int i = 0; i < 16; i++) begin
      logic [511:0] d;
      rd(0, 25'd63 + i[24:0], d);
      check($sformatf("wr_burst 4k [%0d]", i), d, data_for(25'd63 + i[24:0]));
    end

    // 5. partial WSTRB: full pattern A, then B in the first 8 bytes
    wr(0, 25'd128, data_for(25'd128), {64{1'b1}});
    wr(0, 25'd128, {16{32'hB00B_0000}}, 64'h0000_0000_0000_00FF);
    begin
      logic [511:0] d, exp;
      rd(0, 25'd128, d);
      exp = data_for(25'd128);
      exp[63:0] = {32'hB00B_0000, 32'hB00B_0000};  // WSTRB[7:0]: low 8 bytes replaced
      check("partial strb", d, exp);
    end

    // 6. direction changes
    wr(0, 25'd160, data_for(25'd160), {64{1'b1}});
    begin
      logic [511:0] d;
      rd(0, 25'd160, d);
      check("dir w/r", d, data_for(25'd160));
    end
    wr(0, 25'd161, data_for(25'd161), {64{1'b1}});
    begin
      logic [511:0] d;
      rd(0, 25'd161, d);
      check("dir w/r 2", d, data_for(25'd161));
    end

    // 7. the pool window: a beat with bit 24 set goes to win + (low 24 bits << 6), a beat
    // without it to base + (beat << 6) as ever, and two windows are two places
    win_addr = 64'h0000_0000_0000_8000;
    wr(0, 25'h100_0000, data_for(25'h100_0000), {64{1'b1}});
    want_aw(64'h0000_0000_0000_8000, "win aw");
    begin
      logic [511:0] d;
      rd(0, 25'h100_0000, d);
      check("win w/r [0]", d, data_for(25'h100_0000));
      want_ar(64'h0000_0000_0000_8000, "win ar");
    end
    wr(0, 25'd200, data_for(25'd200), {64{1'b1}});
    want_aw(64'd200 * 64, "no-win aw");               // bit 24 clear: the channel's own beat
    win_addr = 64'h0000_0000_0001_0000;               // the next layer's window, same beat
    wr(0, 25'h100_0000, {16{32'hB00B_0000}}, {64{1'b1}});
    want_aw(64'h0000_0000_0001_0000, "win2 aw");
    begin
      logic [511:0] d;
      rd(0, 25'h100_0000, d);
      check("win2 w/r", d, {16{32'hB00B_0000}});
      win_addr = 64'h0000_0000_0000_8000;             // back: the first window kept its own
      rd(0, 25'h100_0000, d);
      check("win separation", d, data_for(25'h100_0000));
    end
    win_addr = 64'd0;                                 // and off again: bit 24 means the channel

    if (err || dbg_err != 3'd0 || dbg_wout != 5'd0) begin
      failures++; $display("FAIL: err=%b code=%0d wout=%0d", err, dbg_err, dbg_wout);
    end
    $display("INFO: %0d read beats in %0d ARs (%.2f beats/AR)", ar_beats, ar_count,
             ar_count ? real'(ar_beats) / real'(ar_count) : 0.0);
    if (ar_count >= ar_beats) begin
      failures++; $display("FAIL: no read bursts coalesced (%0d ARs, %0d beats)", ar_count, ar_beats);
    end
    if (failures == 0) $display("PASS: otpu_axi_dram unit tests");
    else $display("FAIL: %0d failure(s)", failures);
    $finish;
  end

  initial begin
    #200000;
    $display("FAIL: timeout");
    $finish;
  end
endmodule
