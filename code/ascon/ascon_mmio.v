// ascon_mmio.v - ascon_core as a memory-mapped peripheral of the RV32IM SoC
//
// Same bus as the SoC's other blocks (mmio.v, matmul_accel.v): a write strobe, an address,
// write data, and read data that follows the address with no clock in between.
// Software use: sw/ascon.h.
//
// Registers (word offsets from the base, 0x3000_0000 in the SoC):
//   0x00  CTRL     write: bits 2:0 = mode (see ascon_core.v), bit 8 = start,
//                         bit 31 = reset the core (drops whatever it was doing)
//         STATUS   read : bit 0 = busy          an operation is running
//                         bit 1 = din_full      the last beat written has not been taken yet
//                         bit 2 = dout_valid    an output beat is waiting in DOUT
//                         bit 3 = done          the operation started last has finished
//                         bit 4 = tag_ok        decrypt: the tag was right
//                         bits 12:8 = number of bytes in the waiting output beat
//                         bit 13 = it is the last beat of the output
//   0x04  OUT_LEN  write: XOF / CXOF output bytes
//   0x10  KEY[0..3]     write only
//   0x20  NONCE[0..3]   write only
//   0x30  DIN[0..3]     data of the next input beat (byte 0 of the stream = low byte of DIN[0])
//   0x40  DIN_CTRL write: bits 4:0 = bytes in the beat, bit 8 = last beat of the stream.
//                         This write sends the beat.
//   0x50  DOUT[0..3]    read: the waiting output beat
//   0x60  DOUT_ACK write: anything = the output beat has been read, give the next one
//   0x70  TAG[0..3]     read: the tag (after an encrypt). write: the tag to check (decrypt).
//
// Reads never change anything (the output beat is released by a write to DOUT_ACK, not by
// reading it). That is the SoC's rule: a load that the pipeline repeats or throws away must
// be harmless.
//
// The key cannot be read back, and after a decrypt TAG reads as zero: software gets the
// yes / no answer in STATUS, never the tag it would need to forge a message.

module ascon_mmio #(
    parameter RPC = 1
) (
    input             clk, reset,
    input             wr_en,
    input      [31:0] addr, wr_data,
    output reg [31:0] rd_data
);

wire [3:0] region = addr[7:4];
wire [1:0] word   = addr[3:2];

localparam R_CTRL = 4'h0, R_KEY = 4'h1, R_NONCE = 4'h2, R_DIN = 4'h3, R_DIN_CTRL = 4'h4,
           R_DOUT = 4'h5, R_DOUT_ACK = 4'h6, R_TAG = 4'h7;

reg [127:0] key, nonce, din, tag_exp;
reg [ 31:0] out_len;
reg         din_valid, din_last;
reg [  4:0] din_bytes;
reg         done_seen;

wire         ready, din_ready, dout_valid, dout_last, done, tag_ok;
wire [127:0] dout, tag;
wire [  4:0] dout_bytes;

wire ctrl_wr    = wr_en && region == R_CTRL && word == 2'd0;
wire start      = ctrl_wr && wr_data[8] && ready;
wire soft_reset = ctrl_wr && wr_data[31];
wire dout_ack   = wr_en && region == R_DOUT_ACK;

always @(posedge clk) begin
    if (reset || soft_reset) begin
        din_valid <= 1'b0;
        done_seen <= 1'b0;
        if (reset) begin
            key <= 128'b0; nonce <= 128'b0; din <= 128'b0; tag_exp <= 128'b0;
            out_len <= 32'b0; din_bytes <= 5'b0; din_last <= 1'b0;
        end
    end else begin
        if (din_valid && din_ready) din_valid <= 1'b0;      // the core took the beat
        if (done)                   done_seen <= 1'b1;

        if (wr_en) begin
            case (region)
                R_CTRL: begin
                    if (word == 2'd1) out_len <= wr_data;
                    if (start) done_seen <= 1'b0;
                end
                R_KEY:      key    [32*word +: 32] <= wr_data;
                R_NONCE:    nonce  [32*word +: 32] <= wr_data;
                R_DIN:      din    [32*word +: 32] <= wr_data;
                R_TAG:      tag_exp[32*word +: 32] <= wr_data;
                R_DIN_CTRL: begin
                    din_valid <= 1'b1;
                    din_bytes <= wr_data[4:0];
                    din_last  <= wr_data[8];
                end
                default: ;
            endcase
        end
    end
end

ascon_core #(.RPC(RPC)) core (
    .clk(clk), .reset(reset | soft_reset),
    .start(start), .mode(wr_data[2:0]), .key(key), .nonce(nonce), .out_len(out_len),
    .ready(ready),
    .din_valid(din_valid), .din_ready(din_ready), .din_data(din),
    .din_bytes(din_bytes), .din_last(din_last),
    .dout_valid(dout_valid), .dout_ready(dout_ack), .dout_data(dout),
    .dout_bytes(dout_bytes), .dout_last(dout_last),
    .tag_in(tag_exp), .done(done), .tag(tag), .tag_ok(tag_ok)
);

always @(*) begin
    case (region)
        R_CTRL:  rd_data = (word == 2'd0) ? {18'b0, dout_last, dout_bytes, 3'b0,
                                             tag_ok, done_seen, dout_valid, din_valid, !ready}
                                          : 32'b0;
        R_DOUT:  rd_data = dout[32*word +: 32];
        R_TAG:   rd_data = tag [32*word +: 32];
        default: rd_data = 32'b0;           // key, nonce and input data are write-only
    endcase
end

endmodule
