// openTPU's memory controller, replaced by an AXI4 master on the Alveo U200 (docs/u200.md).
// It sits where the LiteDRAM core (otpu_ld4) sat: on
// otpu_mem_ch's controller side (c_*, uclk), two native ports (bank parity 0 and 1, one 64-byte
// beat per command, 2 GiB per channel) and one AXI4 master to the shell's DDR.
//
// Native contract (otpu_mem_ch): per port, commands (we, beat) in order; one write-data beat per
// write command in write-command order (the data may be shown before or after its command); read
// data in command order, one port at a time, no backpressure, on a single 512-bit bus
// (otpu_mem_ch reads c_rdata_data[0]; c_rdata_valid[1] says the beat is port 1's).
//
// AXI mapping: address = base + (beat << 6), 512-bit beats (AWSIZE/ARSIZE 6), WSTRB =
// c_wdata_we. A beat whose address has bit 24 set -- the channel's top 1 GiB -- takes `win`
// instead of `base` plus its low 24 bits (the pool window: expert slots held on the card, one
// window a layer; docs/u200.md 3c). win == 0 maps every beat as before. Reads coalesce consecutive read commands into INCR bursts of up to MAXB beats;
// writes coalesce consecutive write commands into INCR bursts of up to WMAXB beats. Both are
// clamped at the 4 KB page boundary. The read tag FIFO carries {last, port} per beat so R data is
// routed back to the right native port and RLAST is checked only on the burst's last beat. The
// AXI AR is registered (the command-FIFO look-ahead must not feed m_axi pins combinationally).
//
// Ordering. The native controller processes a port's commands in stream order; the two ports are
// unordered against each other. This bridge accepts commands from both ports into one in-order
// command FIFO (one command a cycle, round-robin when both are valid), and processes that stream
// in order. It changes direction only when the stream changes: a write is issued only when every
// earlier read has returned its R data, and a read only when every earlier write has its B
// response. That keeps the memory order the native contract promises (a read after a write sees
// the write, a read before a write returns the old beat) without per-address tracking.
//
// The AXI W channel has one registered output stage (wq_*): the write-data FIFO's FF array is
// read by a WDEPTH:1 mux, and driving the kernel's WDATA pins from that mux put the mux, its
// selects and the crossing to the platform's AXI register in one cycle (fp13/fp14: 6.6 ns of a
// 6.7 ns period, the worst path). With the stage the pins come from a flop in the bridge's own
// SLR and the crossing is flop to flop; it costs one beat of W latency, which the FIFO covers.
//
// Reads: up to ROUT outstanding beats, up to MAXB beats per AR, a {last, port} tag per beat
// routes R data back in AR order. Writes: one AW/W burst at a time, up to WOUT outstanding B
// responses; the write-data FIFOs are per port and each W beat waits for its port's data. AXI
// errors and protocol violations set a sticky err and an error code (dbg_err_code): 1 = R data
// with no tag, 2 = RLAST mismatch, 3 = RRESP != OKAY, 4 = BRESP != OKAY.
module otpu_axi_dram #(
  parameter int CDEPTH = 64,             // command FIFO: {port, we, beat[24:0]}
  parameter int WDEPTH = 64,             // write-data FIFO per port: {data[511:0], we[63:0]}
  parameter int ROUT   = 256,            // outstanding read beats (tag slots)
  parameter int WOUT   = 16,             // outstanding writes (B responses)
  parameter int MAXB   = 4,              // max beats per coalesced read burst (<= 64)
  parameter int WMAXB  = 32              // max beats per coalesced write burst (<= 64)
) (
  input  logic                 clk,
  input  logic                 rst,
  input  logic [63:0]          base,
  input  logic [63:0]          win,     // the pool window's AXI base (0: no window)
  // otpu_mem_ch controller side (uclk)
  input  logic [1:0]           c_cmd_valid,
  output logic [1:0]           c_cmd_ready,
  input  logic [1:0]           c_cmd_we,
  input  logic [1:0][24:0]     c_cmd_addr,
  input  logic [1:0]           c_wdata_valid,
  output logic [1:0]           c_wdata_ready,
  input  logic [1:0][511:0]    c_wdata_data,
  input  logic [1:0][63:0]     c_wdata_we,
  output logic [1:0]           c_rdata_valid,
  output logic [1:0][511:0]    c_rdata_data,
  output logic                 err,
  output logic [9:0]           dbg_outstanding,   // current read beats in flight
  output logic [4:0]           dbg_wout_pending,  // current write B responses outstanding
  output logic [2:0]           dbg_err_code,      // first error cause (0 = none)
  // deep diagnostics (read-only, kernel debug registers)
  output logic                 dbg_w_state,
  output logic [5:0]           dbg_w_idx,
  output logic [5:0]           dbg_w_blen,
  output logic [5:0]           dbg_w_win_n,
  output logic [$clog2(CDEPTH+1)-1:0] dbg_cmd_count,
  output logic [$clog2(WDEPTH+1)-1:0] dbg_wd_count0,
  output logic [$clog2(WDEPTH+1)-1:0] dbg_wd_count1,
  output logic [5:0]           dbg_tag_pend,
  // AXI4 master (Vitis m_axi, no ID ports)
  output logic [63:0]          m_axi_AWADDR,
  output logic [7:0]           m_axi_AWLEN,
  output logic [2:0]           m_axi_AWSIZE,
  output logic [2:0]           m_axi_AWBURST,
  output logic                 m_axi_AWVALID,
  input  logic                 m_axi_AWREADY,
  output logic [511:0]         m_axi_WDATA,
  output logic [63:0]          m_axi_WSTRB,
  output logic                 m_axi_WLAST,
  output logic                 m_axi_WVALID,
  input  logic                 m_axi_WREADY,
  input  logic [1:0]           m_axi_BRESP,
  input  logic                 m_axi_BVALID,
  output logic                 m_axi_BREADY,
  output logic [63:0]          m_axi_ARADDR,
  output logic [7:0]           m_axi_ARLEN,
  output logic [2:0]           m_axi_ARSIZE,
  output logic [2:0]           m_axi_ARBURST,
  output logic                 m_axi_ARVALID,
  input  logic                 m_axi_ARREADY,
  input  logic [511:0]         m_axi_RDATA,
  input  logic [1:0]           m_axi_RRESP,
  input  logic                 m_axi_RVALID,
  output logic                 m_axi_RREADY,
  input  logic                 m_axi_RLAST
);

  localparam int CCW = $clog2(CDEPTH + 1);
  localparam int CPW = $clog2(CDEPTH);
  localparam int WCW = $clog2(WDEPTH + 1);
  localparam int WPW = $clog2(WDEPTH);
  localparam int RCW = $clog2(ROUT + 1);
  localparam int RPW = $clog2(ROUT);
  localparam int WOCW = $clog2(WOUT + 1);
  localparam logic [5:0]  MAXB6  = 6'(MAXB);
  localparam logic [5:0]  WMAXB6 = 6'(WMAXB);
  localparam logic [10:0] ROUT11 = 11'(ROUT);

  // A beat's AXI address. The pool window (docs/u200.md 3c): a beat in the channel's
  // top 1 GiB (bit 24) names a 1 GiB page of the window instead, so the host moves the window
  // (one register write) rather than the experts. win == 0 keeps every beat where it was.
  function automatic logic [63:0] ax_addr(input logic [24:0] beat);
    ax_addr = (win != 64'd0 && beat[24]) ? win + (64'(beat[23:0]) << 6)
                                        : base + (64'(beat) << 6);
  endfunction

  // ------------------------------------------------------------------ command FIFO
  logic [26:0]          cmd_mem [0:CDEPTH-1];   // {port, we, beat[24:0]}
  logic [CPW-1:0]       cmd_wr, cmd_rd;
  logic [CCW-1:0]       cmd_count;
  logic                 rr;
  logic [26:0]          cmd_out;
  wire                  cmd_room;
  wire                  take0, take1, take;
  wire [1:0]            take_port;
  wire                  take_we;
  wire [24:0]           take_addr;
  wire                  cmd_pop;

  assign cmd_out = cmd_mem[cmd_rd];
  assign cmd_room = (cmd_count < CDEPTH) || cmd_pop;
  assign take0 = cmd_room && c_cmd_valid[0] && (!c_cmd_valid[1] || !rr);
  assign take1 = cmd_room && c_cmd_valid[1] && (!c_cmd_valid[0] || rr);
  assign take  = take0 || take1;
  assign take_port = take1 ? 2'd1 : 2'd0;
  assign take_we   = take1 ? c_cmd_we[1]   : c_cmd_we[0];
  assign take_addr = take1 ? c_cmd_addr[1] : c_cmd_addr[0];
  assign c_cmd_ready[0] = cmd_room && (!c_cmd_valid[1] || !rr);
  assign c_cmd_ready[1] = cmd_room && (!c_cmd_valid[0] || rr);

  // ------------------------------------------------------------------ write-data FIFOs (per port)
  logic [575:0]         wd_mem [0:1][0:WDEPTH-1];  // {data[511:0], we[63:0]}
  logic [WPW-1:0]       wd_wr [0:1], wd_rd [0:1];
  logic [WCW-1:0]       wd_count [0:1];
  logic [1:0]           wd_push, wd_pop;
  logic [575:0]         wd_out [0:1];

  assign wd_push[0] = c_wdata_valid[0] && c_wdata_ready[0];
  assign wd_push[1] = c_wdata_valid[1] && c_wdata_ready[1];
  assign c_wdata_ready[0] = (wd_count[0] < WDEPTH) || wd_pop[0];
  assign c_wdata_ready[1] = (wd_count[1] < WDEPTH) || wd_pop[1];
  assign wd_out[0] = wd_mem[0][wd_rd[0]];
  assign wd_out[1] = wd_mem[1][wd_rd[1]];

  // ------------------------------------------------------------------ read burst tags {port, len}
  // One tag per AR (not per beat): a single write port, so this stays a LUTRAM. R beats are
  // routed by the tag's port and counted down; the tag pops on the burst's last beat.
  logic [6:0]           rtag_mem [0:ROUT-1];
  logic [RPW-1:0]       rtag_wr, rtag_rd;
  logic [RCW-1:0]       rtag_count;
  logic [5:0]           rbeat;
  logic [9:0]           rd_beats_out;
  wire                  rtag_pop;
  wire                  rtag_empty;
  wire [6:0]            rtag_out;
  wire                  rtag_last, rtag_port;
  wire [5:0]            rtag_len;

  assign rtag_empty = (rtag_count == 0);
  assign rtag_out   = rtag_mem[rtag_rd];
  assign rtag_port  = rtag_out[6];
  assign rtag_len   = rtag_out[5:0];
  assign rtag_last  = (rbeat == (rtag_len - 6'd1));
  assign rtag_pop   = m_axi_RVALID && m_axi_RREADY && !rtag_empty && rtag_last;
  assign m_axi_RREADY = !rtag_empty;

  // ------------------------------------------------------------------ read burst coalescing
  // Look ahead in the command FIFO from the head: consecutive reads at head+1, head+2, ...,
  // limited by MAXB, the room to the 4 KB page boundary, the command count and the free tag room.
  logic [5:0]  blen;
  logic        stop;
  logic [5:0]  max_len;
  wire  [5:0]  head_off   = cmd_out[5:0];                 // beat offset within the 4 KB page
  wire  [6:0]  page_room  = 7'd64 - {1'b0, head_off};      // beats left in this 4 KB page
  wire  [10:0] tag_room   = ROUT11 - {1'b0, rtag_count};   // free burst tags

  always_comb begin
    max_len = MAXB6;
    if (page_room < {1'b0, max_len}) max_len = page_room[5:0];
  end

  always_comb begin
    blen = 6'd1;
    stop = 1'b0;
    for (int i = 1; i < MAXB; i++) begin
      if (!stop) begin
        if ((i < max_len) && (i < cmd_count) &&
            !cmd_mem[(cmd_rd + i) % CDEPTH][25] &&
            (cmd_mem[(cmd_rd + i) % CDEPTH][26] == cmd_out[26]) &&
            (cmd_mem[(cmd_rd + i) % CDEPTH][24:6] == cmd_out[24:6]) &&
            (cmd_mem[(cmd_rd + i) % CDEPTH][5:0] == (cmd_out[5:0] + i[5:0]))) begin
          blen = i[5:0] + 6'd1;
        end else begin
          stop = 1'b1;
        end
      end
    end
  end

  // ------------------------------------------------------------------ write burst coalescing
  logic [5:0]  wblen;
  logic [5:0]  wmax_len;

  // Link mask: bit i (i>=1) = "window entry i is a write contiguous with entry i-1".
  // Computed once per entry at load time, so the burst-length path is a 32-bit priority
  // encoder on flops instead of 32 address adders/compare chains.
  logic [WMAXB-1:0] w_mask;
  logic [WMAXB-1:0] w_mask_sh, w_mask_nxt;
  logic [WMAXB-1:0] w_gap, w_lsb;
  logic [5:0]       w_ctz;
  logic [5:0]       w_n_after;
  logic             m_valid, m_bit;
  logic [WMAXB-1:0] m_onehot;
  wire              w_load;
  wire              w_new_bit;

  // Registered copy of the command-FIFO head (up to WMAXB entries). The write look-ahead
  // reads these flops, not 32 combinational ports of cmd_mem.
  logic [26:0] w_win [0:WMAXB-1];
  logic [5:0]  w_win_n;
  logic [4:0]  w_win_rd;

  always_comb begin
    wmax_len = WMAXB6;
    if (page_room < {1'b0, wmax_len}) wmax_len = page_room[5:0];
  end

  // ------------------------------------------------------------------ write issue state
  logic                 w_state;                 // 0 idle, 1 AW/W burst in flight
  logic                 aw_done, w_done;
  logic [63:0]          w_addr_q;
  logic [5:0]           w_blen_q, w_idx;
  logic [WMAXB-1:0]     w_burst_ports;
  logic [5:0]           w_pop_q;
  logic                 w_pop_pend;
  logic [WOCW-1:0]      wout_pending;
  wire                  wd_avail;
  wire                  wr_start, w_finish;
  wire [1:0]            w_port;
  wire [575:0]          w_wd;
  wire                  w_last;
  wire                  w_data_avail;

  logic [3:0]           idle_cnt;
  wire                  idle_ok = (idle_cnt >= 4'd8);

  assign wd_avail = (w_win_n != 0) && w_win[w_win_rd][25] &&
                    ((w_win[w_win_rd][26] == 1'b0) ? (wd_count[0] != 0) : (wd_count[1] != 0));
  // Start a write burst once the window has a backlog, or when the stream pauses (tail).
  assign wr_start = (w_win_n != 0) && w_win[w_win_rd][25] && wd_avail &&
                    ((w_win_n >= WMAXB) || idle_ok) &&
                    (rtag_count == 0) && (wout_pending < WOUT) && !w_state;

  assign w_port      = w_burst_ports[w_idx];
  assign w_wd        = wd_mem[w_port][wd_rd[w_port]];
  assign w_last      = (w_idx == (w_blen_q - 6'd1));
  assign w_data_avail = (wd_count[w_port] != 0);

  // AXI W output stage (one beat): the FIFO read feeds this flop, the pins come from it
  logic          wq_valid;
  logic [575:0]  wq_data;
  logic          wq_last;
  wire           wq_free   = !wq_valid || m_axi_WREADY;   // empty, or draining this cycle
  wire           wq_load   = w_state && !w_done && w_data_avail && wq_free;
  wire           wq_sent   = wq_valid && m_axi_WREADY;    // the staged beat is taken
  wire           w_last_sent = w_done && wq_sent;         // the burst's last beat is taken
  assign w_finish    = w_state && (aw_done || m_axi_AWREADY) && w_last_sent;

  // ------------------------------------------------------------------ read issue
  // A burst forms only once the command FIFO has a backlog (or the stream pauses). The AR is
  // captured into ar_*_q so the look-ahead is not on the m_axi path.
  logic                 ar_pending;
  logic [63:0]          ar_addr_q;
  logic [7:0]           ar_len_q;
  logic [5:0]           ar_blen_q;
  wire                  head_is_read;
  wire                  rd_issue, rd_fire;
  wire [5:0]            cmd_pop_n;
  wire [5:0]            w_win_n_post;
  assign head_is_read = (cmd_count != 0) && !cmd_out[25];
  assign rd_issue = !ar_pending && head_is_read &&
                    ((cmd_count >= 10'(MAXB)) || idle_ok) &&
                    ({1'b0, blen} <= w_win_n) && (tag_room != 0) &&
                    (wout_pending == 0) && !w_state;
  assign rd_fire = ar_pending && m_axi_ARREADY;
  assign cmd_pop_n = rd_fire ? ar_blen_q : (w_pop_pend ? w_pop_q : 6'd0);
  assign cmd_pop = rd_fire || w_pop_pend;
  assign w_win_n_post = (w_win_n >= cmd_pop_n) ? (w_win_n - cmd_pop_n) : 6'd0;

  // next command to mirror, and whether it extends the tail run
  wire [26:0] w_cmd_new  = cmd_mem[(cmd_rd + cmd_pop_n + w_win_n_post) % CDEPTH];
  wire [26:0] w_cmd_prev = w_win[(w_win_rd + cmd_pop_n + w_win_n_post - 1'b1) % WMAXB];
  assign w_load = (w_win_n_post < WMAXB) && ({1'b0, w_win_n_post} < (cmd_count - cmd_pop_n));
  assign w_new_bit = w_cmd_new[25] &&
                     ((w_win_n_post == 0) ? 1'b1 :
                      (w_cmd_prev[25] &&
                       (w_cmd_new[24:6] == w_cmd_prev[24:6]) &&
                       (w_cmd_new[5:0] == (w_cmd_prev[5:0] + 6'd1))));

  assign w_n_after = w_win_n_post + (w_load ? 1'b1 : 1'b0);
  assign w_mask_sh  = (cmd_pop_n == 0) ? w_mask : (w_mask >> cmd_pop_n);
  assign w_mask_nxt = w_mask_sh;

  // first zero in w_mask at or after bit 1 -> burst length; w_gap = 0 means 32 contiguous
  assign w_gap = ~(w_mask | {{(WMAXB-1){1'b0}}, 1'b1});
  assign w_lsb = w_gap & (~w_gap + 1'b1);

  always_comb begin
    w_ctz[0] = |(w_lsb & 32'hAAAA_AAAA);
    w_ctz[1] = |(w_lsb & 32'hCCCC_CCCC);
    w_ctz[2] = |(w_lsb & 32'hF0F0_F0F0);
    w_ctz[3] = |(w_lsb & 32'hFF00_FF00);
    w_ctz[4] = |(w_lsb & 32'hFFFF_0000);
    w_ctz[5] = 1'b0;
    if (w_lsb == {WMAXB{1'b0}}) w_ctz = 6'(WMAXB);
  end

  always_comb begin
    wblen = w_ctz;
    if (wblen > wmax_len) wblen = wmax_len;
    if (wblen == 0) wblen = 6'd1;
  end


  assign wd_pop[0] = wq_load && (w_port == 1'b0);
  assign wd_pop[1] = wq_load && (w_port == 1'b1);

  // ------------------------------------------------------------------ AXI outputs
  assign m_axi_AWADDR  = w_addr_q;
  assign m_axi_AWLEN   = 8'(w_blen_q - 6'd1);
  assign m_axi_AWSIZE  = 3'd6;      // 64 bytes
  assign m_axi_AWBURST = 2'b01;     // INCR
  assign m_axi_AWVALID = w_state && !aw_done;
  assign m_axi_WDATA   = wq_data[575:64];
  assign m_axi_WSTRB   = wq_data[63:0];
  assign m_axi_WLAST   = wq_last;
  assign m_axi_WVALID  = wq_valid;
  assign m_axi_BREADY  = 1'b1;

  assign m_axi_ARADDR  = ar_addr_q;
  assign m_axi_ARLEN   = ar_len_q;
  assign m_axi_ARSIZE  = 3'd6;      // 64 bytes
  assign m_axi_ARBURST = 2'b01;     // INCR
  assign m_axi_ARVALID = ar_pending;

  assign c_rdata_data[0] = m_axi_RDATA;
  assign c_rdata_data[1] = m_axi_RDATA;
  assign c_rdata_valid[0] = m_axi_RVALID && m_axi_RREADY && !rtag_empty && (rtag_port == 1'b0);
  assign c_rdata_valid[1] = m_axi_RVALID && m_axi_RREADY && !rtag_empty && (rtag_port == 1'b1);

  // ------------------------------------------------------------------ diagnostics
  logic [2:0] err_code_q;
  assign dbg_outstanding  = rd_beats_out;
  assign dbg_wout_pending = wout_pending;
  assign dbg_err_code     = err_code_q;
  assign dbg_w_state      = w_state;
  assign dbg_w_idx        = w_idx;
  assign dbg_w_blen       = w_blen_q;
  assign dbg_w_win_n      = w_win_n;
  assign dbg_cmd_count    = cmd_count;
  assign dbg_wd_count0    = wd_count[0];
  assign dbg_wd_count1    = wd_count[1];
  assign dbg_tag_pend     = {1'b0, rbeat};   // beat index within the current read burst

  // ------------------------------------------------------------------ state
  always_ff @(posedge clk) begin
    if (rst) begin
      cmd_wr <= '0; cmd_rd <= '0; cmd_count <= '0; rr <= 1'b0;
      wd_wr[0] <= '0; wd_wr[1] <= '0; wd_rd[0] <= '0; wd_rd[1] <= '0;
      wd_count[0] <= '0; wd_count[1] <= '0;
      rtag_wr <= '0; rtag_rd <= '0; rtag_count <= '0; rbeat <= '0; rd_beats_out <= '0;
      w_state <= 1'b0; aw_done <= 1'b0; w_done <= 1'b0;
      wq_valid <= 1'b0; wq_data <= '0; wq_last <= 1'b0;
      w_addr_q <= '0; w_blen_q <= '0; w_idx <= '0; w_burst_ports <= '0;
      w_pop_q <= '0; w_pop_pend <= 1'b0;
      wout_pending <= '0; err <= 1'b0; err_code_q <= '0; idle_cnt <= '0;
      w_win_n <= '0; w_win_rd <= '0; w_mask <= '0; m_valid <= 1'b0; m_bit <= 1'b0; m_onehot <= '0;
      ar_pending <= 1'b0; ar_addr_q <= '0; ar_len_q <= '0; ar_blen_q <= '0;
    end else begin
      // command FIFO
      if (take) begin
        cmd_mem[cmd_wr] <= {take_port[0], take_we, take_addr};
        cmd_wr <= cmd_wr + 1'b1;
        rr <= ~rr;
      end
      if (cmd_pop) begin
        cmd_rd   <= cmd_rd + cmd_pop_n;
        w_win_rd <= (w_win_rd + cmd_pop_n) % WMAXB;
      end
      cmd_count <= cmd_count + (take ? 1 : 0) - cmd_pop_n;
      // Refill the registered write window from the command FIFO (one entry/cycle). The
      // indices are post-pop so a large read/write pop simply shifts the window head and
      // the refill continues from the new FIFO head.
      if (w_load) begin
        w_win[(w_win_rd + cmd_pop_n + w_win_n_post) % WMAXB] <= w_cmd_new;
      end
      w_win_n <= w_n_after;
      w_mask   <= w_mask_nxt | (m_valid ? ((m_onehot >> cmd_pop_n) & {WMAXB{m_bit}}) : '0);
      m_valid  <= w_load;
      if (w_load) begin
        m_onehot <= {{(WMAXB-1){1'b0}}, 1'b1} << w_win_n_post;
        m_bit    <= w_new_bit;
      end
      if (take) idle_cnt <= '0;
      else if (idle_cnt != 4'hF) idle_cnt <= idle_cnt + 1'b1;

      // write-data FIFOs
      for (int p = 0; p < 2; p++) begin
        if (wd_push[p]) begin
          wd_mem[p][wd_wr[p]] <= {c_wdata_data[p], c_wdata_we[p]};
          wd_wr[p] <= wd_wr[p] + 1'b1;
        end
        if (wd_pop[p]) wd_rd[p] <= wd_rd[p] + 1'b1;
        wd_count[p] <= wd_count[p] + (wd_push[p] ? 1 : 0) - (wd_pop[p] ? 1 : 0);
      end

      // one burst tag per AR; pop it on the burst's last R beat
      if (rd_fire) begin
        rtag_mem[rtag_wr] <= {cmd_out[26], ar_blen_q};
        rtag_wr <= rtag_wr + 1'b1;
      end
      if (m_axi_RVALID && m_axi_RREADY && !rtag_empty) begin
        if (rtag_last) begin
          rbeat   <= '0;
          rtag_rd <= rtag_rd + 1'b1;
        end else begin
          rbeat <= rbeat + 1'b1;
        end
      end
      rtag_count  <= rtag_count + (rd_fire ? 1 : 0) - (rtag_pop ? 1 : 0);
      rd_beats_out <= rd_beats_out + (rd_fire ? {4'd0, ar_blen_q} : '0)
                      - ((m_axi_RVALID && m_axi_RREADY && !rtag_empty) ? 1 : 0);

      // capture one AR, then hold the AXI outputs stable until ARREADY
      if (rd_issue) begin
        ar_pending <= 1'b1;
        ar_addr_q  <= ax_addr(cmd_out[24:0]);
        ar_len_q   <= 8'(blen - 6'd1);
        ar_blen_q  <= blen;
      end
      if (rd_fire) ar_pending <= 1'b0;

      // write issue
      w_pop_pend <= 1'b0;
      if (wr_start) begin
        w_state  <= 1'b1;
        aw_done  <= 1'b0;
        w_done   <= 1'b0;
        w_addr_q <= ax_addr(w_win[w_win_rd][24:0]);
        w_blen_q <= wblen;
        w_idx    <= '0;
        w_pop_q  <= wblen;
        w_pop_pend <= 1'b1;
        for (int i = 0; i < WMAXB; i++)
          w_burst_ports[i] <= (i < wblen) ? w_win[(w_win_rd + i) % WMAXB][26] : 1'b0;
      end
      if (w_state) begin
        if (m_axi_AWREADY) aw_done <= 1'b1;
        // the beat leaves the FIFO when it is staged; WREADY only drains the stage
        if (wq_load) begin
          if (w_last) w_done <= 1'b1;
          else        w_idx  <= w_idx + 1'b1;
        end
        if (w_finish) begin
          w_state <= 1'b0;
          aw_done <= 1'b0;
          w_done  <= 1'b0;
        end
      end

      // the W output stage: load the next beat while it is empty or draining
      if (wq_free) begin
        wq_valid <= w_state && !w_done && w_data_avail;
        if (w_state && !w_done && w_data_avail) begin
          wq_data <= w_wd;
          wq_last <= w_last;
        end
      end

      // outstanding writes and AXI responses
      wout_pending <= wout_pending + (w_finish ? 1 : 0) - (m_axi_BVALID ? 1 : 0);
      if (m_axi_BVALID && (m_axi_BRESP != 2'b00) && !err) begin
        err <= 1'b1; err_code_q <= 3'd4;
      end

      // read responses: RLAST must match the tag's last-beat flag
      if (m_axi_RVALID && m_axi_RREADY && !rtag_empty && !err) begin
        if (m_axi_RLAST !== rtag_last) begin
          err <= 1'b1; err_code_q <= 3'd2;
        end else if (m_axi_RRESP != 2'b00) begin
          err <= 1'b1; err_code_q <= 3'd3;
        end
      end
    end
  end

endmodule
