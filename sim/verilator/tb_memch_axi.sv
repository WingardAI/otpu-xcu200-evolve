// Integration test: otpu_mem_ch (the real channel bridge) + otpu_axi_dram + AXI memory model.
//   iverilog -g2012 -o /tmp/tb_memch_axi sim/verilator/tb_memch_axi.sv \
//       sim/verilator/axi_mem_model.sv rtl/mem/otpu_axi_dram.sv rtl/shell/otpu_mem_ch.sv
//   vvp /tmp/tb_memch_axi
//
// Drives the accelerator's native port (n_*) with writes/reads on both bank-parity ports, a
// partial write (otpu_mem_ch read-modify-writes it), and back-to-back reads; checks every beat,
// n_wdone, and n_err. The AXI memory model is the shell DDR.
`timescale 1ns/1ps

module tb_memch_axi;
  logic clk = 0;
  logic rst = 1;
  always #5 clk = ~clk;

  // accelerator native port
  logic         n_cvalid, n_cready, n_cwe;
  logic [24:0]  n_caddr;
  logic         n_wvalid, n_wready;
  logic [511:0] n_wdata;
  logic [63:0]  n_wmask;
  logic         n_rvalid;
  logic [511:0] n_rdata;
  logic [15:0]  n_wdone;
  logic         n_err;

  // controller-side native ports (otpu_mem_ch -> bridge)
  logic [1:0]        c_cmd_valid, c_cmd_ready, c_cmd_we;
  logic [1:0][24:0]  c_cmd_addr;
  logic [1:0]        c_wdata_valid, c_wdata_ready;
  logic [1:0][511:0] c_wdata_data;
  logic [1:0][63:0]  c_wdata_we;
  logic [1:0]        c_rdata_valid;
  logic [1:0][511:0] c_rdata_data;
  logic              bridge_err;
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

  otpu_mem_ch #(.XIDW(4)) u_ch (
    .clk, .rst,
    .n_cvalid, .n_cready, .n_cwe, .n_caddr,
    .n_wvalid, .n_wready, .n_wdata, .n_wmask,
    .n_rvalid, .n_rdata, .n_wdone, .n_err,
    .xclk(clk), .xrst(rst),
    .x_awvalid(1'b0), .x_awready(), .x_awid(4'h0), .x_awaddr(32'h0), .x_awlen(8'h0),
    .x_wvalid(1'b0), .x_wready(), .x_wdata(128'h0), .x_wstrb(16'h0), .x_wlast(1'b0),
    .x_bvalid(), .x_bready(1'b1), .x_bid(), .x_bresp(),
    .x_arvalid(1'b0), .x_arready(), .x_arid(4'h0), .x_araddr(32'h0), .x_arlen(8'h0),
    .x_rvalid(), .x_rready(1'b1), .x_rid(), .x_rdata(), .x_rresp(), .x_rlast(),
    .uclk(clk), .urst(rst),
    .c_cmd_valid(c_cmd_valid), .c_cmd_ready(c_cmd_ready), .c_cmd_we(c_cmd_we),
    .c_cmd_addr(c_cmd_addr),
    .c_wdata_valid(c_wdata_valid), .c_wdata_ready(c_wdata_ready),
    .c_wdata_data(c_wdata_data), .c_wdata_we(c_wdata_we),
    .c_rdata_valid(c_rdata_valid), .c_rdata_data(c_rdata_data)
  );

  otpu_axi_dram #(.CDEPTH(32), .WDEPTH(16), .ROUT(16), .WOUT(8)) u_axi (
    .clk, .rst, .base(64'd0), .win(64'd0),
    .c_cmd_valid, .c_cmd_ready, .c_cmd_we, .c_cmd_addr,
    .c_wdata_valid, .c_wdata_ready, .c_wdata_data, .c_wdata_we,
    .c_rdata_valid, .c_rdata_data, .err(bridge_err),
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
    return {16{32'hC0DE_0000 | {7'd0, a}}};
  endfunction

  int failures = 0;
  int n_writes = 0;
  task automatic check(input string name, input logic [511:0] got, input logic [511:0] exp);
    begin
      if (got !== exp) begin
        failures++;
        $display("FAIL %s: got %h exp %h", name, got, exp);
      end
    end
  endtask

  task automatic wr(input logic [24:0] addr, input logic [511:0] data, input logic [63:0] mask);
    logic cmd_done, w_done, cmd_go, w_go;
    begin
      @(negedge clk);
      n_cvalid = 1; n_cwe = 1; n_caddr = addr;
      n_wvalid = 1; n_wdata = data; n_wmask = mask;
      cmd_done = 0; w_done = 0;
      while (!(cmd_done && w_done)) begin
        cmd_go = !cmd_done && n_cready;
        w_go   = !w_done   && n_wready;
        if (cmd_go || w_go) begin
          @(posedge clk);
          if (cmd_go) begin n_cvalid = 0; cmd_done = 1; end
          if (w_go)   begin n_wvalid = 0; w_done = 1; end
        end
        if (!(cmd_done && w_done)) @(negedge clk);
      end
      n_writes++;
    end
  endtask

  task automatic rd(input logic [24:0] addr, output logic [511:0] data);
    begin
      @(negedge clk);
      n_cvalid = 1; n_cwe = 0; n_caddr = addr;
      while (!n_cready) @(negedge clk);
      @(posedge clk);
      n_cvalid = 0;
      @(negedge clk);
      while (!n_rvalid) @(negedge clk);
      data = n_rdata;
    end
  endtask

  task automatic wr_burst(input int n, input logic [24:0] first);
    logic cmd_done, w_done, cmd_go, w_go;
    begin
      for (int i = 0; i < n; i++) begin
        @(negedge clk);
        n_cvalid = 1; n_cwe = 1; n_caddr = first + i;
        n_wvalid = 1; n_wdata = data_for(first + i); n_wmask = {64{1'b1}};
        cmd_done = 0; w_done = 0;
        while (!(cmd_done && w_done)) begin
          cmd_go = !cmd_done && n_cready;
          w_go   = !w_done   && n_wready;
          if (cmd_go || w_go) begin
            @(posedge clk);
            if (cmd_go) begin n_cvalid = 0; cmd_done = 1; end
            if (w_go)   begin n_wvalid = 0; w_done = 1; end
          end
          if (!(cmd_done && w_done)) @(negedge clk);
        end
        n_writes++;
      end
    end
  endtask

  task automatic rd_burst(input int n, input logic [24:0] first);
    logic [511:0] d;
    begin
      fork
        begin
          for (int i = 0; i < n; i++) begin
            @(negedge clk);
            n_cvalid = 1; n_cwe = 0; n_caddr = first + i;
            while (!n_cready) @(negedge clk);
            @(posedge clk);
            n_cvalid = 0;
          end
        end
        begin
          for (int i = 0; i < n; i++) begin
            @(negedge clk);
            while (!n_rvalid) @(negedge clk);
            d = n_rdata;
            check($sformatf("memch rd_burst [%0d]", i), d, data_for(first + i));
          end
        end
      join
    end
  endtask

  initial begin
    n_cvalid = 0; n_cwe = 0; n_caddr = '0;
    n_wvalid = 0; n_wdata = '0; n_wmask = '0;
    repeat (4) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    // port 0 (beat bit 7 = 0): 16 writes/reads
    for (int i = 0; i < 16; i++) wr(i[24:0], data_for(i), {64{1'b1}});
    for (int i = 0; i < 16; i++) begin
      logic [511:0] d;
      rd(i[24:0], d);
      check($sformatf("p0 w/r [%0d]", i), d, data_for(i));
    end

    // port 1 (beat bit 7 = 1): 8 writes/reads
    for (int i = 0; i < 8; i++) wr(25'd128 + i[24:0], data_for(25'd128 + i[24:0]), {64{1'b1}});
    for (int i = 0; i < 8; i++) begin
      logic [511:0] d;
      rd(25'd128 + i[24:0], d);
      check($sformatf("p1 w/r [%0d]", i), d, data_for(25'd128 + i[24:0]));
    end

    // write-burst coalescing through otpu_mem_ch
    wr_burst(16, 25'd256);
    for (int i = 0; i < 16; i++) begin
      logic [511:0] d;
      rd(25'd256 + i[24:0], d);
      check($sformatf("wr_burst [%0d]", i), d, data_for(25'd256 + i[24:0]));
    end

    // partial write (otpu_mem_ch read-modify-writes) at beat 32
    wr(25'd32, data_for(25'd32), {64{1'b1}});
    wr(25'd32, {16{32'hB00B_0000}}, 64'h0000_0000_0000_00FF);
    begin
      logic [511:0] d, exp;
      rd(25'd32, d);
      exp = data_for(25'd32);
      exp[63:0] = {32'hB00B_0000, 32'hB00B_0000};
      check("partial", d, exp);
    end

    // back-to-back reads (outstanding ARs, both ports)
    for (int i = 0; i < 16; i++) wr(25'd64 + i[24:0], data_for(25'd64 + i[24:0]), {64{1'b1}});
    rd_burst(16, 25'd64);

    // n_wdone must count every write once; no controller errors
    repeat (200) @(negedge clk);
    if (n_wdone !== n_writes[15:0]) begin
      failures++;
      $display("FAIL n_wdone: %0d, expected %0d", n_wdone, n_writes);
    end
    if (n_err) begin failures++; $display("FAIL: n_err set"); end
    if (bridge_err || dbg_err != 3'd0 || dbg_wout != 5'd0) begin
      failures++; $display("FAIL: bridge err=%b code=%0d wout=%0d", bridge_err, dbg_err, dbg_wout);
    end

    if (failures == 0) $display("PASS: otpu_mem_ch + otpu_axi_dram");
    else $display("FAIL: %0d failure(s)", failures);
    $finish;
  end

  initial begin
    #2000000;
    $display("FAIL: timeout");
    $finish;
  end
endmodule
