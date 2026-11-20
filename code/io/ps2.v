// ps2.v - PS/2 port for the mouse on the Basys 3 USB host connector (the board's PIC24 turns a
// USB mouse into a PS/2 device)
//
// Registers (base 0x4000_0000):
//   0x00  RX      read: bit 8 = a byte is waiting, bits 7:0 = the oldest byte;
//                 write (any value): drop that byte (the next one moves up)
//   0x04  TX      write: send a byte to the mouse (a command such as 0xFF reset, 0xF4 enable)
//   0x08  STATUS  read: bit 0 = byte waiting, bit 1 = sending, bit 2 = the last send got no
//                 acknowledge, bit 3 = a received byte had a parity or framing error (bits 2
//                 and 3 stay set until STATUS is written)
//
// Received bytes wait in a 32-byte FIFO, so mouse packets are kept while the CPU is busy.
// Both lines are open-drain: the module only pulls them low (clk_oe / data_oe) or lets the
// pull-ups hold them high; the board top level turns that into tri-state pins.

`default_nettype none

module ps2 #(
    parameter integer INHIBIT = 6000,          // clock held low before a send: 120 us at 50 MHz
    parameter integer TIMEOUT = 1500000,       // 30 ms: give up on a send
    parameter integer RX_IDLE = 10000          // 200 us of clock silence ends a broken byte
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        wr_en,
    input  wire [31:0] addr,
    input  wire [31:0] wr_data,
    output reg  [31:0] rd_data,
    input  wire        ps2_clk_in,
    input  wire        ps2_data_in,
    output reg         clk_oe,                 // 1 = pull the clock line low
    output reg         data_oe                 // 1 = pull the data line low
);
    wire [1:0] sel = addr[3:2];

    // synchronise and de-glitch the clock: it counts as changed after 16 stable cycles
    reg [1:0] cs, ds;
    reg [3:0] stable;
    reg       c_f, c_prev;
    always @(posedge clk) begin
        cs <= {cs[0], ps2_clk_in};
        ds <= {ds[0], ps2_data_in};
        if (cs[1] == c_f) stable <= 4'd0;
        else if (stable == 4'd15) begin c_f <= cs[1]; stable <= 4'd0; end
        else stable <= stable + 4'd1;
        c_prev <= c_f;
    end
    wire fall = c_prev && !c_f;
    initial begin cs = 2'b11; ds = 2'b11; stable = 0; c_f = 1'b1; c_prev = 1'b1; end
    wire dat  = ds[1];

    // receive FIFO
    reg  [7:0] fifo [0:31];
    reg  [4:0] f_rd, f_wr;
    reg  [5:0] f_n;
    wire       f_push;

    // transmitter
    localparam T_IDLE = 2'd0, T_INH = 2'd1, T_BITS = 2'd2, T_END = 2'd3;
    reg  [1:0]  t_st;
    reg  [21:0] t_cnt;
    reg  [3:0]  t_k;                           // falling edges seen since the start bit
    reg  [8:0]  t_sh;                          // data bits, then parity
    reg         t_err;

    // receiver
    reg  [3:0]  r_k;
    reg  [10:0] r_sh;
    reg  [21:0] r_idle;
    reg         r_err;

    always @(*) begin
        case (sel)
            2'd0:    rd_data = {23'b0, f_n != 6'd0, fifo[f_rd]};
            2'd2:    rd_data = {28'b0, r_err, t_err, t_st != T_IDLE, f_n != 6'd0};
            default: rd_data = 32'b0;
        endcase
    end

    wire rx_done = (t_st == T_IDLE) && fall && (r_k == 4'd10);
    wire [10:0] frame = {dat, r_sh[10:1]};     // the 11th bit arrives now
    // frame: [0] start, [8:1] data, [9] parity (odd), [10] stop
    wire frame_ok = !frame[0] && frame[10] && (^frame[9:1]);
    assign f_push = rx_done && frame_ok && (f_n != 6'd32);

    wire pop = wr_en && sel == 2'd0 && f_n != 6'd0;

    always @(posedge clk) begin
        if (reset) begin
            f_rd <= 0;  f_wr <= 0;  f_n <= 0;
            t_st <= T_IDLE;  clk_oe <= 1'b0;  data_oe <= 1'b0;  t_err <= 1'b0;
            r_k <= 0;  r_idle <= 0;  r_err <= 1'b0;
        end else begin
            // FIFO
            if (f_push) begin fifo[f_wr] <= frame[8:1]; f_wr <= f_wr + 5'd1; end
            if (pop) f_rd <= f_rd + 5'd1;
            f_n <= f_n + (f_push ? 6'd1 : 6'd0) - (pop ? 6'd1 : 6'd0);
            if (wr_en && sel == 2'd2) begin t_err <= 1'b0; r_err <= 1'b0; end

            // receive: one bit per falling clock edge, while not sending
            if (t_st != T_IDLE) begin
                r_k <= 0;  r_idle <= 0;
            end else if (fall) begin
                r_idle <= 0;
                r_sh <= frame;
                if (r_k == 4'd10) begin
                    r_k <= 0;
                    if (!frame_ok) r_err <= 1'b1;
                end else r_k <= r_k + 4'd1;
            end else if (r_k != 0) begin
                // a byte's bits come at least every 100 us: longer silence means it was broken
                // (for example cut off by a send); start again with the next start bit
                if (r_idle == RX_IDLE[21:0]) begin r_k <= 0; r_idle <= 0; end
                else r_idle <= r_idle + 22'd1;
            end

            // send: hold the clock low, start bit, then a bit per falling edge
            case (t_st)
                T_IDLE: if (wr_en && sel == 2'd1) begin
                    t_sh   <= {~^wr_data[7:0], wr_data[7:0]};   // odd parity
                    t_st   <= T_INH;  t_cnt <= 0;  clk_oe <= 1'b1;  t_err <= 1'b0;
                end
                T_INH: if (t_cnt == INHIBIT) begin
                    data_oe <= 1'b1;                            // start bit
                    clk_oe  <= 1'b0;                            // the mouse clocks from now on
                    t_st <= T_BITS;  t_cnt <= 0;  t_k <= 0;
                end else t_cnt <= t_cnt + 22'd1;
                T_BITS: begin
                    t_cnt <= t_cnt + 22'd1;
                    if (fall) begin
                        t_k <= t_k + 4'd1;
                        if (t_k < 4'd9) begin                   // edges 1..9: data bits, parity
                            data_oe <= !t_sh[0];
                            t_sh <= t_sh >> 1;
                        end else if (t_k == 4'd9) data_oe <= 1'b0;   // edge 10: stop bit (released)
                        else begin                              // edge 11: the acknowledge
                            if (dat) t_err <= 1'b1;
                            t_st <= T_END;  t_cnt <= 0;
                        end
                    end
                    if (t_cnt == TIMEOUT) begin
                        data_oe <= 1'b0;  t_err <= 1'b1;  t_st <= T_IDLE;
                    end
                end
                // after the acknowledge, receive again as soon as the mouse releases the clock:
                // it may start its answer at once, so the data line need not go high first
                T_END: if (c_f) t_st <= T_IDLE;
                       else if (t_cnt == TIMEOUT) t_st <= T_IDLE;
                       else t_cnt <= t_cnt + 22'd1;
            endcase
        end
    end
endmodule

`default_nettype wire
