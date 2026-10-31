// Two DDR controllers, as the U200 core kernel's SLR1 has them: one otpu_mem_ch + one
// otpu_axi_dram + one AXI DDR model per channel (0 and 1), both channels driven together the way
// the board's slice drives them (a stream of commands per channel, read data consumed in order),
// with the two controllers given DIFFERENT read latency, between-beat gaps, jitter and B latency --
// which is what two independent DDR4 controllers have and what one controller (the fp11 image)
// does not.
//
// The point is the mem_ch's controller-side contract: one read beat a cycle at most, and only on
// a port with a read outstanding (otpu_mem_ch's n_err). The fp13 card image set that error under
// long workloads while both bridges reported no AXI error; this test looks for it.
//
//   iverilog -g2012 -o /tmp/tb_2ch_axi sim/verilator/tb_2ch_axi.sv sim/verilator/axi_mem_model.sv \
//       rtl/mem/otpu_axi_dram.sv rtl/shell/otpu_mem_ch.sv rtl/shell/otpu_afifo.sv
//   vvp /tmp/tb_2ch_axi [+seed=N] [+scen=all|read|alt|mixed|page|dir] [+verbose]
//   (the two controllers' timings are iverilog parameters:
//    -Ptb_2ch_axi.RLAT0=8 -Ptb_2ch_axi.RGAP0=0 -Ptb_2ch_axi.WLAT0=4 -Ptb_2ch_axi.RLAT1=40 ...)
//
// Prints "PASS: two channels" or the failures (and the first contract violation).
`timescale 1ns/1ps

module tb_2ch_axi;
  logic clk = 0;
  logic rst = 1;
  always #5 clk = ~clk;

  parameter int RLAT0 = 8,  RGAP0 = 0,  WLAT0 = 4;     // controller 0
  parameter int RLAT1 = 40, RGAP1 = 2,  WLAT1 = 16;    // controller 1
  parameter int RJIT  = 0;                             // extra random cycles per transaction
  int seed = 1;
  string scen = "all";
  bit verbose = 0;

  // the accelerator's native ports, per channel
  logic [1:0]        n_cvalid, n_cready, n_cwe;
  logic [1:0][24:0]  n_caddr;
  logic [1:0]        n_wvalid, n_wready;
  logic [1:0][511:0] n_wdata;
  logic [1:0][63:0]  n_wmask;
  logic [1:0]        n_rvalid;
  logic [1:0][511:0] n_rdata;
  logic [1:0][15:0]  n_wdone;
  logic [1:0]        n_err;

  // controller-side native ports, per channel (otpu_mem_ch -> that channel's bridge)
  logic [1:0][1:0]        c_cmd_valid, c_cmd_ready, c_cmd_we;
  logic [1:0][1:0][24:0]  c_cmd_addr;
  logic [1:0][1:0]        c_wdata_valid, c_wdata_ready;
  logic [1:0][1:0][511:0] c_wdata_data;
  logic [1:0][1:0][63:0]  c_wdata_we;
  logic [1:0][1:0]        c_rdata_valid;
  logic [1:0][1:0][511:0] c_rdata_data;

  // AXI, per channel
  logic [1:0][63:0]  m_awaddr, m_araddr;
  logic [1:0][7:0]   m_awlen, m_arlen;
  logic [1:0][2:0]   m_awsize, m_awburst, m_arsize, m_arburst;
  logic [1:0]        m_awvalid, m_awready, m_arvalid, m_arready;
  logic [1:0][511:0] m_wdata;
  logic [1:0][63:0]  m_wstrb;
  logic [1:0]        m_wlast, m_wvalid, m_wready;
  logic [1:0][1:0]   m_bresp;
  logic [1:0]        m_bvalid, m_bready;
  logic [1:0][511:0] m_rdata;
  logic [1:0][1:0]   m_rresp;
  logic [1:0]        m_rvalid, m_rready, m_rlast;

  logic [1:0]       br_err;
  logic [1:0][2:0]  br_code;

  genvar g;
  generate
    for (g = 0; g < 2; g++) begin : g_ch
      otpu_mem_ch #(.XIDW(4)) u_ch (
        .clk, .rst,
        .n_cvalid(n_cvalid[g]), .n_cready(n_cready[g]), .n_cwe(n_cwe[g]),
        .n_caddr(n_caddr[g]),
        .n_wvalid(n_wvalid[g]), .n_wready(n_wready[g]), .n_wdata(n_wdata[g]),
        .n_wmask(n_wmask[g]),
        .n_rvalid(n_rvalid[g]), .n_rdata(n_rdata[g]), .n_wdone(n_wdone[g]), .n_err(n_err[g]),
        .xclk(clk), .xrst(rst),
        .x_awvalid(1'b0), .x_awready(), .x_awid(4'h0), .x_awaddr(32'h0), .x_awlen(8'h0),
        .x_wvalid(1'b0), .x_wready(), .x_wdata(128'h0), .x_wstrb(16'h0), .x_wlast(1'b0),
        .x_bvalid(), .x_bready(1'b1), .x_bid(), .x_bresp(),
        .x_arvalid(1'b0), .x_arready(), .x_arid(4'h0), .x_araddr(32'h0), .x_arlen(8'h0),
        .x_rvalid(), .x_rready(1'b1), .x_rid(), .x_rdata(), .x_rresp(), .x_rlast(),
        .uclk(clk), .urst(rst),
        .c_cmd_valid(c_cmd_valid[g]), .c_cmd_ready(c_cmd_ready[g]), .c_cmd_we(c_cmd_we[g]),
        .c_cmd_addr(c_cmd_addr[g]),
        .c_wdata_valid(c_wdata_valid[g]), .c_wdata_ready(c_wdata_ready[g]),
        .c_wdata_data(c_wdata_data[g]), .c_wdata_we(c_wdata_we[g]),
        .c_rdata_valid(c_rdata_valid[g]), .c_rdata_data(c_rdata_data[g])
      );

      otpu_axi_dram #(.CDEPTH(64), .WDEPTH(16), .ROUT(128), .WOUT(16)) u_axi (
        .clk, .rst, .base(64'd0), .win(64'd0),
        .c_cmd_valid(c_cmd_valid[g]), .c_cmd_ready(c_cmd_ready[g]), .c_cmd_we(c_cmd_we[g]),
        .c_cmd_addr(c_cmd_addr[g]),
        .c_wdata_valid(c_wdata_valid[g]), .c_wdata_ready(c_wdata_ready[g]),
        .c_wdata_data(c_wdata_data[g]), .c_wdata_we(c_wdata_we[g]),
        .c_rdata_valid(c_rdata_valid[g]), .c_rdata_data(c_rdata_data[g]), .err(br_err[g]),
        .dbg_outstanding(), .dbg_wout_pending(), .dbg_err_code(br_code[g]),
        .m_axi_AWADDR(m_awaddr[g]), .m_axi_AWLEN(m_awlen[g]), .m_axi_AWSIZE(m_awsize[g]),
        .m_axi_AWBURST(m_awburst[g]), .m_axi_AWVALID(m_awvalid[g]),
        .m_axi_AWREADY(m_awready[g]),
        .m_axi_WDATA(m_wdata[g]), .m_axi_WSTRB(m_wstrb[g]), .m_axi_WLAST(m_wlast[g]),
        .m_axi_WVALID(m_wvalid[g]), .m_axi_WREADY(m_wready[g]),
        .m_axi_BRESP(m_bresp[g]), .m_axi_BVALID(m_bvalid[g]), .m_axi_BREADY(m_bready[g]),
        .m_axi_ARADDR(m_araddr[g]), .m_axi_ARLEN(m_arlen[g]), .m_axi_ARSIZE(m_arsize[g]),
        .m_axi_ARBURST(m_arburst[g]), .m_axi_ARVALID(m_arvalid[g]),
        .m_axi_ARREADY(m_arready[g]),
        .m_axi_RDATA(m_rdata[g]), .m_axi_RRESP(m_rresp[g]), .m_axi_RVALID(m_rvalid[g]),
        .m_axi_RREADY(m_rready[g]), .m_axi_RLAST(m_rlast[g])
      );
    end
  endgenerate

  // the two controllers: different read latency, between-beat gaps and B latency
  axi_mem_model #(.WORDS(1 << 13), .RQD(64), .RLAT(RLAT0), .RGAP(RGAP0), .RJIT(RJIT),
                  .WLAT(WLAT0)) u_mem0 (
    .clk, .rst,
    .s_awaddr(m_awaddr[0]), .s_awlen(m_awlen[0]), .s_awsize(m_awsize[0]),
    .s_awburst(m_awburst[0]), .s_awvalid(m_awvalid[0]), .s_awready(m_awready[0]),
    .s_wdata(m_wdata[0]), .s_wstrb(m_wstrb[0]), .s_wlast(m_wlast[0]),
    .s_wvalid(m_wvalid[0]), .s_wready(m_wready[0]),
    .s_bresp(m_bresp[0]), .s_bvalid(m_bvalid[0]), .s_bready(m_bready[0]),
    .s_araddr(m_araddr[0]), .s_arlen(m_arlen[0]), .s_arsize(m_arsize[0]),
    .s_arburst(m_arburst[0]), .s_arvalid(m_arvalid[0]), .s_arready(m_arready[0]),
    .s_rdata(m_rdata[0]), .s_rresp(m_rresp[0]), .s_rvalid(m_rvalid[0]),
    .s_rready(m_rready[0]), .s_rlast(m_rlast[0]), .dump(1'b0)
  );
  axi_mem_model #(.WORDS(1 << 13), .RQD(64), .RLAT(RLAT1), .RGAP(RGAP1), .RJIT(RJIT),
                  .WLAT(WLAT1)) u_mem1 (
    .clk, .rst,
    .s_awaddr(m_awaddr[1]), .s_awlen(m_awlen[1]), .s_awsize(m_awsize[1]),
    .s_awburst(m_awburst[1]), .s_awvalid(m_awvalid[1]), .s_awready(m_awready[1]),
    .s_wdata(m_wdata[1]), .s_wstrb(m_wstrb[1]), .s_wlast(m_wlast[1]),
    .s_wvalid(m_wvalid[1]), .s_wready(m_wready[1]),
    .s_bresp(m_bresp[1]), .s_bvalid(m_bvalid[1]), .s_bready(m_bready[1]),
    .s_araddr(m_araddr[1]), .s_arlen(m_arlen[1]), .s_arsize(m_arsize[1]),
    .s_arburst(m_arburst[1]), .s_arvalid(m_arvalid[1]), .s_arready(m_arready[1]),
    .s_rdata(m_rdata[1]), .s_rresp(m_rresp[1]), .s_rvalid(m_rvalid[1]),
    .s_rready(m_rready[1]), .s_rlast(m_rlast[1]), .dump(1'b0)
  );

  // ---------------------------------------------------------------- scoreboard
  // expected read data per channel, in the order the read commands were issued: the mem_ch's
  // native port returns read data in command order
  localparam int EQ = 4096;                 // expected-data ring per channel
  logic [511:0] expq [0:1][0:EQ-1];
  int eq_head [0:1];
  int eq_tail [0:1];
  int failures = 0;
  int n_writes [1:0];
  int n_reads [1:0];
  bit done = 0;

  function automatic logic [511:0] data_for(input logic [24:0] a);
    return {16{32'hC0DE_0000 | {7'd0, a}}};
  endfunction

  task automatic check(input int ch, input string name, input logic [511:0] got,
                       input logic [511:0] exp);
    if (got !== exp) begin
      failures++;
      if (failures < 8) begin
        $display("FAIL ch%0d %s: got %h exp %h", ch, name, got, exp);
        for (int b = 0; b < 64; b++)
          if (got[8*b +: 8] !== exp[8*b +: 8])
            $display("   byte %0d: got %h exp %h", b, got[8*b +: 8], exp[8*b +: 8]);
      end
    end
  endtask

  function automatic int eq_size(input int ch);
    return eq_tail[ch] - eq_head[ch];
  endfunction
  task automatic push_exp(input int ch, input logic [511:0] exp);
    expq[ch][eq_tail[ch] % EQ] = exp;
    eq_tail[ch] = eq_tail[ch] + 1;
  endtask
  function automatic logic [511:0] pop_exp(input int ch);
    pop_exp = expq[ch][eq_head[ch] % EQ];
    eq_head[ch] = eq_head[ch] + 1;
  endfunction

  // one consumer per channel: read data arrives in command order, no backpressure
  generate
    for (g = 0; g < 2; g++) begin : g_rd
      initial begin
        forever begin
          @(negedge clk);
          if (n_rvalid[g]) begin
            if (eq_size(g) == 0) begin
              failures++;
              if (failures < 8) $display("FAIL ch%0d: read data with nothing expected", g);
            end else begin
              check(g, $sformatf("read #%0d", n_reads[g]), n_rdata[g], pop_exp(g));
              n_reads[g]++;
            end
          end
        end
      end
    end
  endgenerate

  // ---------------------------------------------------------------- command issue
  task automatic issue_rd(input int ch, input logic [24:0] addr, input logic [511:0] exp);
    begin
      push_exp(ch, exp);
      @(negedge clk);
      n_cvalid[ch] = 1; n_cwe[ch] = 0; n_caddr[ch] = addr;
      n_wvalid[ch] = 0;
      while (!n_cready[ch]) @(negedge clk);
      @(posedge clk);
      n_cvalid[ch] = 0;
    end
  endtask

  task automatic issue_wr(input int ch, input logic [24:0] addr, input logic [511:0] data,
                          input logic [63:0] mask);
    logic cmd_done, w_done, cmd_go, w_go;
    begin
      @(negedge clk);
      n_cvalid[ch] = 1; n_cwe[ch] = 1; n_caddr[ch] = addr;
      n_wvalid[ch] = 1; n_wdata[ch] = data; n_wmask[ch] = mask;
      cmd_done = 0; w_done = 0;
      while (!(cmd_done && w_done)) begin
        cmd_go = !cmd_done && n_cready[ch];
        w_go   = !w_done   && n_wready[ch];
        if (cmd_go || w_go) begin
          @(posedge clk);
          if (cmd_go) begin n_cvalid[ch] = 0; cmd_done = 1; end
          if (w_go)   begin n_wvalid[ch] = 0; w_done = 1; end
        end
        if (!(cmd_done && w_done)) @(negedge clk);
      end
      n_writes[ch]++;
    end
  endtask

  // whole-beat read of addr, checking data_for(addr) (unless exp is given)
  task automatic rd(input int ch, input logic [24:0] addr);
    issue_rd(ch, addr, data_for(addr));
  endtask
  task automatic wr(input int ch, input logic [24:0] addr, input logic [63:0] mask);
    issue_wr(ch, addr, data_for(addr), mask);
  endtask

  // ---------------------------------------------------------------- the contract check
  // One read beat a cycle at most per channel, and only on a port with a read outstanding.
  logic [1:0] seen_both = '0;
  logic [1:0] seen_notag = '0;
  generate
    for (g = 0; g < 2; g++) begin : g_chk
      always @(posedge clk) if (!rst) begin
        if (&c_rdata_valid[g] && !seen_both[g]) begin
          seen_both[g] = 1'b1;
          $display("VIOLATION ch%0d t=%0t: read data on BOTH ports in one cycle", g, $time);
        end
        for (int p = 0; p < 2; p++)
          if (c_rdata_valid[g][p] && !g_ch[g].u_ch.tg_rv[p] && !seen_notag[g]) begin
            seen_notag[g] = 1'b1;
            $display("VIOLATION ch%0d port%0d t=%0t: read beat with no tag outstanding",
                     g, p, $time);
          end
      end
    end
  endgenerate

  // ---------------------------------------------------------------- scenarios
  // the beat a partial write leaves behind: the bytes its mask covers take the new data, the rest
  // keep the old (the convention the existing tb_memch_axi partial test uses: mask bit b = byte b)
  function automatic logic [511:0] merge(input logic [511:0] old, input logic [511:0] newd,
                                         input logic [63:0] mask);
    logic [511:0] e;
    for (int b = 0; b < 64; b++)
      e[8*b +: 8] = mask[b] ? newd[8*b +: 8] : old[8*b +: 8];
    return e;
  endfunction

  // fill n beats on both channels, then read them back, both ports in turn
  task automatic scen_read();
    for (int i = 0; i < 192; i++) begin
      wr(0, 25'(i), {64{1'b1}});
      wr(1, 25'(i), {64{1'b1}});
    end
    fork
      for (int i = 0; i < 192; i++) rd(0, 25'(i));
      for (int i = 0; i < 192; i++) rd(1, 25'(i));
    join
  endtask

  // deep outstanding reads, alternating the bank-parity ports (bit 7 of the beat address)
  task automatic scen_alt();
    for (int i = 0; i < 256; i++) begin
      wr(0, 25'(i), {64{1'b1}});
      wr(1, 25'(i), {64{1'b1}});
    end
    fork
      for (int i = 0; i < 256; i++) rd(0, 25'(i / 2) + 25'((i % 2) ? 128 : 0));
      for (int i = 0; i < 256; i++) rd(1, 25'(i / 2) + 25'((i % 2) ? 128 : 0));
    join
    // again with writes mixed in (the attention's KV writes among its reads), one issuer a channel
    fork
      for (int i = 0; i < 96; i++) begin
        if (i % 3 == 0) wr(0, 25'(384 + i), {64{1'b1}});
        else            rd(0, 25'(i / 2) + 25'((i % 2) ? 128 : 0));
      end
      for (int i = 0; i < 96; i++) begin
        if (i % 3 == 0) wr(1, 25'(384 + i), {64{1'b1}});
        else            rd(1, 25'(i / 2) + 25'((i % 2) ? 128 : 0));
      end
    join
  endtask

  // burst runs with direction changes: reads to the page edge, writes, reads again
  task automatic scen_mixed();
    for (int r = 0; r < 8; r++) begin
      fork
        begin
          for (int i = 0; i < 24; i++) wr(0, 25'(512 + 24 * r + i), {64{1'b1}});
          for (int i = 0; i < 24; i++) rd(0, 25'(512 + 24 * r + i));
        end
        begin
          for (int i = 0; i < 24; i++) wr(1, 25'(512 + 24 * r + i), {64{1'b1}});
          for (int i = 0; i < 24; i++) rd(1, 25'(512 + 24 * r + i));
        end
      join
    end
  endtask

  // partial writes (the mem_ch read-modify-writes them) and reads across the 4 KB page boundary
  task automatic scen_page();
    for (int i = 0; i < 32; i++) begin
      issue_wr(0, 25'(896 + i), {16{32'hA000_0000}}, {64{1'b1}});
      issue_wr(1, 25'(896 + i), {16{32'hA000_0000}}, {64{1'b1}});
    end
    fork
      for (int i = 0; i < 8; i++)
        issue_wr(0, 25'(896 + 2 * i), {16{32'hB000_0000 | {7'd0, 25'(2 * i)}}},
                 64'h0000_0000_0000_FFFF);
      for (int i = 0; i < 8; i++)
        issue_wr(1, 25'(896 + 2 * i), {16{32'hB000_0000 | {7'd0, 25'(2 * i)}}},
                 64'h00FF_0000_0000_0000);
    join
    fork
      for (int i = 0; i < 8; i++)
        issue_rd(0, 25'(896 + 2 * i),
                 merge({16{32'hA000_0000}}, {16{32'hB000_0000 | {7'd0, 25'(2 * i)}}},
                       64'h0000_0000_0000_FFFF));
      for (int i = 0; i < 8; i++)
        issue_rd(1, 25'(896 + 2 * i),
                 merge({16{32'hA000_0000}}, {16{32'hB000_0000 | {7'd0, 25'(2 * i)}}},
                       64'h00FF_0000_0000_0000));
    join
    // beats 1000..1023 straddle the 4 KB page (64 beats): fill and read across it
    for (int i = 992; i < 1088; i++) begin
      wr(0, 25'(i), {64{1'b1}});
      wr(1, 25'(i), {64{1'b1}});
    end
    fork
      for (int i = 992; i < 1088; i++) rd(0, 25'(i));
      for (int i = 992; i < 1088; i++) rd(1, 25'(i));
    join
  endtask

  // shadow memory per channel: what a read must return, kept by the issuer
  logic [511:0] shadow [0:1][0:4095];
  int rand_n = 20000;
  int rand_seed = 3;

  // a long random run: reads, writes and partial writes (RMW) on both channels, random ports,
  // addresses and masks, checked against the shadow
  task automatic scen_rand();
    int ch, a, kind, mlen, mpos;
    logic [511:0] d;
    logic [63:0]  m;
    for (int ch0 = 0; ch0 < 2; ch0++)
      for (int i = 0; i < 4096; i++) shadow[ch0][i] = data_for(25'(i));
    // prime the memory so reads have something to compare against
    for (int ch0 = 0; ch0 < 2; ch0++)
      for (int i = 0; i < 4096; i++) issue_wr(ch0, 25'(i), data_for(25'(i)), {64{1'b1}});
    for (int n = 0; n < rand_n; n++) begin
      ch   = $urandom_range(0, 1);
      a    = $urandom_range(0, 4095);
      kind = $urandom_range(0, 9);
      if (kind < 6) begin                       // read
        issue_rd(ch, 25'(a), shadow[ch][a]);
      end else if (kind < 8) begin              // full write
        d = {16{$urandom}};
        issue_wr(ch, 25'(a), d, {64{1'b1}});
        shadow[ch][a] = d;
      end else begin                            // partial write (read-modify-write)
        d = {16{$urandom}};
        mlen = $urandom_range(1, 63);
        mpos = $urandom_range(0, 63 - mlen);
        m = '0;
        for (int b = 0; b < mlen; b++) m[mpos + b] = 1'b1;
        issue_wr(ch, 25'(a), d, m);
        shadow[ch][a] = merge(shadow[ch][a], d, m);
      end
    end
  endtask

  // a short reset pulse while traffic is in flight (the mem_ch's hold/restart path), then traffic
  // again: nothing may be mis-routed afterwards (the data before the pulse is not checked)
  task automatic scen_dir();
    fork
      for (int i = 0; i < 64; i++) rd(0, 25'(i));
      for (int i = 0; i < 64; i++) rd(1, 25'(i));
    join_none
    repeat (20) @(negedge clk);
    rst = 1;
    repeat (3) @(negedge clk);
    rst = 0;
    repeat (400) @(negedge clk);
    eq_head[0] = eq_tail[0];
    eq_head[1] = eq_tail[1];
    repeat (200) @(negedge clk);
    // and a clean run afterwards
    for (int i = 0; i < 32; i++) begin
      wr(0, 25'(2048 + i), {64{1'b1}});
      wr(1, 25'(2048 + i), {64{1'b1}});
    end
    fork
      for (int i = 0; i < 32; i++) rd(0, 25'(2048 + i));
      for (int i = 0; i < 32; i++) rd(1, 25'(2048 + i));
    join
  endtask

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("scen=%s", scen));
    void'($value$plusargs("n=%d", rand_n));
    void'($value$plusargs("rseed=%d", rand_seed));
    if ($test$plusargs("verbose")) verbose = 1'b1;
    if (RJIT != 0) void'($urandom(seed));
    void'($urandom(rand_seed));
    $display("tb_2ch_axi: ch0 lat=%0d gap=%0d wlat=%0d | ch1 lat=%0d gap=%0d wlat=%0d | jit=%0d scen=%s",
             RLAT0, RGAP0, WLAT0, RLAT1, RGAP1, WLAT1, RJIT, scen);

    for (int ch = 0; ch < 2; ch++) begin
      n_cvalid[ch] = 0; n_cwe[ch] = 0; n_caddr[ch] = '0;
      n_wvalid[ch] = 0; n_wdata[ch] = '0; n_wmask[ch] = '0;
      n_writes[ch] = 0; n_reads[ch] = 0; eq_head[ch] = 0; eq_tail[ch] = 0;
    end
    repeat (6) @(negedge clk);
    rst = 0;
    repeat (4) @(negedge clk);

    if (scen == "all" || scen == "read")  scen_read();
    if (scen == "all" || scen == "alt")   scen_alt();
    if (scen == "all" || scen == "mixed") scen_mixed();
    if (scen == "all" || scen == "page")  scen_page();
    if (scen == "rand")                   scen_rand();
    if (scen == "dir")                    scen_dir();

    // drain, then check the counts and the contract (long enough for the deepest latency + gaps)
    for (int i = 0; i < 200000 && (eq_size(0) != 0 || eq_size(1) != 0); i++) @(negedge clk);
    repeat (200) @(negedge clk);
    for (int ch = 0; ch < 2; ch++) begin
      if (scen != "dir" && eq_size(ch) != 0) begin
        failures++;
        $display("FAIL ch%0d: %0d read(s) never returned", ch, eq_size(ch));
      end
      if (scen != "dir" && n_wdone[ch] !== n_writes[ch][15:0]) begin
        failures++;
        $display("FAIL ch%0d n_wdone: %0d, expected %0d", ch, n_wdone[ch], n_writes[ch]);
      end
      if (n_err[ch]) begin failures++; $display("FAIL ch%0d: n_err set", ch); end
      if (br_err[ch] || br_code[ch] != 3'd0) begin
        failures++;
        $display("FAIL ch%0d: bridge err=%b code=%0d", ch, br_err[ch], br_code[ch]);
      end
      if (seen_both[ch] || seen_notag[ch]) begin
        failures++;
        $display("FAIL ch%0d: mem_ch contract violation (both=%b notag=%b)",
                 ch, seen_both[ch], seen_notag[ch]);
      end
    end
    $display("reads ch0=%0d ch1=%0d, writes ch0=%0d ch1=%0d",
             n_reads[0], n_reads[1], n_writes[0], n_writes[1]);
    if (failures == 0) $display("PASS: two channels");
    else $display("FAIL: %0d failure(s)", failures);
    $finish;
  end

  initial begin
    #20000000;
    $display("FAIL: timeout");
    $finish;
  end
endmodule
