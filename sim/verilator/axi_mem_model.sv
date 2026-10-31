// New in the XCU200 port (WingardAI, 2026) for openTPU,
// https://github.com/FeSens/openTPU (Apache-2.0). See NOTICE.

// Simple AXI4 slave memory model for the otpu_axi_dram unit test (sim only).
// 512-bit beats; ARLEN read bursts are honored (RLAST on the last beat, in AR order), write
// strobes applied. Writes are still one beat per AW/W.
//
// Latency (RLAT/RGAP/RJIT/WLAT): a real DDR4 controller does not return a beat the cycle after
// AR (or one per cycle), and its B response comes later than the last W beat. With the defaults
// (0) the model behaves as before -- an infinite-room, zero-latency slave. Sets of the parameters
// model a DDR4 channel: RLAT cycles from AR to the first R beat, RGAP idle cycles between the
// beats of a burst, RJIT extra random cycles on each (per transaction), WLAT from the last W beat
// to B. Reads still return in AR order (one ID), as AXI promises and otpu_axi_dram relies on.
module axi_mem_model #(
  parameter int WORDS = 1 << 12,       // 512-bit words (4 KiB with the default)
  parameter int RQD   = 64,            // read-address queue
  parameter int CH    = 0,             // channel id for the image files
  parameter bit IMG   = 1'b0,          // load <dir>/ch<CH>.bin, dump ch<CH>_out.bin
  parameter int RLAT  = 0,             // AR -> first R beat, cycles
  parameter int RGAP  = 0,             // idle cycles between the beats of one burst
  parameter int RJIT  = 0,             // extra random cycles, 0 .. RJIT-1, per transaction
  parameter int WLAT  = 0              // last W beat -> B, cycles
) (
  input  logic          clk,
  input  logic          rst,
  // write address
  input  logic [63:0]   s_awaddr,
  input  logic [7:0]    s_awlen,
  input  logic [2:0]    s_awsize,
  input  logic [2:0]    s_awburst,
  input  logic          s_awvalid,
  output logic          s_awready,
  // write data
  input  logic [511:0]  s_wdata,
  input  logic [63:0]   s_wstrb,
  input  logic          s_wlast,
  input  logic          s_wvalid,
  output logic          s_wready,
  // write response
  output logic [1:0]    s_bresp,
  output logic          s_bvalid,
  input  logic          s_bready,
  // read address
  input  logic [63:0]   s_araddr,
  input  logic [7:0]    s_arlen,
  input  logic [2:0]    s_arsize,
  input  logic [2:0]    s_arburst,
  input  logic          s_arvalid,
  output logic          s_arready,
  // read data
  output logic [511:0]  s_rdata,
  output logic [1:0]    s_rresp,
  output logic          s_rvalid,
  input  logic          s_rready,
  output logic          s_rlast,
  input  logic          dump
);
  logic [511:0] mem [0:WORDS-1];

  logic [63:0] cyc = '0;                 // free-running, for the latency timers
  always_ff @(posedge clk) if (rst) cyc <= '0; else cyc <= cyc + 1'b1;

  // ---------------------------------------------------------------- write
  logic         aw_have;
  logic [63:0]  awaddr_l;
  logic [7:0]   awlen_l;
  logic [7:0]   wcnt_l;
  logic         bpend_q;                  // a B response is owed
  logic [63:0]  bdue_q;                   // and may be sent from this cycle
  assign s_awready = !aw_have && !bpend_q;   // one write in flight at a time
  assign s_wready  = aw_have;
  assign s_bvalid  = bpend_q && (cyc >= bdue_q);
  assign s_bresp   = 2'b00;

  // ---------------------------------------------------------------- read
  localparam int RP = $clog2(RQD);
  localparam int RC = $clog2(RQD + 1);
  logic [63:0]  rq_addr [0:RQD-1];
  logic [7:0]   rq_len  [0:RQD-1];
  logic [7:0]   rq_cnt  [0:RQD-1];
  logic [63:0]  rq_due  [0:RQD-1];
  logic [RP-1:0] rwr, rrd;
  logic [RC-1:0] rcount;
  logic [15:0]  gap_q;                    // idle cycles left before the next beat
  assign s_arready = (rcount < RQD);
  assign s_rvalid  = (rcount != 0) && (cyc >= rq_due[rrd]) && (gap_q == 0);
  assign s_rdata   = mem[((rq_addr[rrd] >> 6) + rq_cnt[rrd]) % WORDS];
  assign s_rresp   = 2'b00;
  assign s_rlast   = (rq_cnt[rrd] == rq_len[rrd]);

  wire rbeat = s_rvalid && s_rready;
  always_ff @(posedge clk)
    if (rst) gap_q <= '0;
    else if (rbeat) gap_q <= RGAP + (RJIT ? $urandom_range(0, RJIT - 1) : 0);
    else if (gap_q != 0) gap_q <= gap_q - 1'b1;

  // image / dump (same files as otpu_ldn_model: 32-bit words, 16 per 512-bit beat)
  string  dir;
  integer fd, nread;
  logic [31:0] words [WORDS * 16];
  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = '0;
    if (IMG && $value$plusargs("dir=%s", dir)) begin
      for (int i = 0; i < WORDS * 16; i++) words[i] = '0;
      fd = $fopen($sformatf("%s/ch%0d.bin", dir, CH), "rb");
      if (fd != 0) begin
        nread = $fread(words, fd);
        $fclose(fd);
      end
      for (int i = 0; i < WORDS * 16; i++)
        mem[i / 16][32 * (i % 16) +: 32] = words[i];
    end
  end
  logic dump_q = 1'b0;
  always_ff @(posedge clk) dump_q <= dump;
  always_ff @(posedge clk) if (dump && !dump_q) begin
    $display("AXIMEM ch%0d", CH);
    if (IMG) begin
      fd = $fopen($sformatf("%s/ch%0d_out.bin", dir, CH), "wb");
      for (int i = 0; i < WORDS * 16; i++) $fwrite(fd, "%u", mem[i / 16][32 * (i % 16) +: 32]);
      $fclose(fd);
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      aw_have <= 1'b0; awaddr_l <= '0; awlen_l <= '0; wcnt_l <= '0; bpend_q <= 1'b0;
      bdue_q <= '0;
      rwr <= '0; rrd <= '0; rcount <= '0;
    end else begin
      if (s_awvalid && s_awready) begin
        aw_have  <= 1'b1;
        awaddr_l <= s_awaddr;
        awlen_l  <= s_awlen;
        wcnt_l   <= '0;
      end
      if (s_wvalid && s_wready) begin
        for (int b = 0; b < 64; b++)
          if (s_wstrb[b])
            mem[((awaddr_l >> 6) + wcnt_l) % WORDS][b*8 +: 8] <= s_wdata[b*8 +: 8];
        if (s_wlast || (wcnt_l == awlen_l)) begin
          aw_have  <= 1'b0;
          bpend_q  <= 1'b1;
          bdue_q   <= cyc + WLAT + (RJIT ? $urandom_range(0, RJIT - 1) : 0);
        end else begin
          wcnt_l <= wcnt_l + 1'b1;
        end
      end
      if (s_bvalid && s_bready) bpend_q <= 1'b0;

      if (s_arvalid && s_arready) begin
        rq_addr[rwr] <= s_araddr;
        rq_len[rwr]  <= s_arlen;
        rq_cnt[rwr]  <= '0;
        rq_due[rwr]  <= cyc + RLAT + (RJIT ? $urandom_range(0, RJIT - 1) : 0);
        rwr          <= rwr + 1'b1;
      end
      if (rbeat) begin
        if (s_rlast) begin
          rrd    <= rrd + 1'b1;
          rcount <= rcount - 1'b1;
        end else begin
          rq_cnt[rrd] <= rq_cnt[rrd] + 1'b1;
        end
      end
      rcount <= rcount + (s_arvalid && s_arready ? 1 : 0) - (s_rvalid && s_rready && s_rlast ? 1 : 0);
    end
  end
endmodule
