// ascon_core.v - Ascon (NIST SP 800-232): authenticated encryption, hash and XOFs in one core
//
// Modes:
//   0  Ascon-AEAD128 encrypt     key + nonce + associated data + plaintext  -> ciphertext + tag
//   1  Ascon-AEAD128 decrypt     ... + ciphertext + expected tag            -> plaintext + tag_ok
//   2  Ascon-Hash256             message -> 32-byte hash
//   3  Ascon-XOF128              message -> out_len bytes
//   4  Ascon-CXOF128             customization string + message -> out_len bytes
//
// All five are the same "sponge": a 320-bit state, of which the first 8 or 16 bytes (the
// "rate") touch the data. Data is XORed into the rate, then the whole state is scrambled by
// the permutation, and so on block after block. Only the start value, the rate and the number
// of rounds differ, so one datapath and one state machine serve every mode.
//
// How to drive it:
//   1. Pulse start (while ready) with mode, and key / nonce for the AEAD modes.
//   2. Send the input as beats on din (valid / ready). A beat carries up to 16 bytes in the
//      AEAD modes and up to 8 in the hash modes; byte 0 of the stream is din_data[7:0].
//      A stream ends with a beat that has din_last = 1. Only that beat may be short
//      (0 bytes is fine: an empty stream is one beat with din_bytes = 0, din_last = 1).
//        AEAD : first the associated-data stream, then the message stream
//        Hash, XOF : the message stream only
//        CXOF : first 8 bytes holding the bit length of the customization string followed
//               by the string itself (as one stream), then the message stream
//   3. Take the output on dout (valid / ready). AEAD gives one output beat for every message
//      beat. The hash modes give 8 bytes per beat.
//   4. done pulses for one cycle. tag (encrypt) or tag_ok (decrypt) stay until the next start.
//
// RPC = permutation rounds computed per clock cycle (1, 2 or 4). More rounds per cycle means
// fewer cycles per block but more logic and a longer critical path: the area / speed knob.
//
// Security choices:
//   - How long an operation takes depends only on the data lengths, never on the key or the
//     data values, so timing leaks nothing.
//   - In decrypt mode the computed tag never leaves the core, only the 1-bit result of the
//     compare. Otherwise an attacker could ask the core for the right tag of a forged message.
//   - The state and the key copy are cleared when an operation ends.
//   - The plaintext of a decrypt comes out before the tag is checked (it has to: the tag is
//     only known at the end). The user must throw it away if tag_ok is 0.

module ascon_core #(
    parameter RPC = 1
) (
    input              clk, reset,
    // command
    input              start,
    input      [  2:0] mode,
    input      [127:0] key, nonce,
    input      [ 31:0] out_len,         // XOF / CXOF: number of output bytes
    output             ready,
    // input stream
    input              din_valid,
    output             din_ready,
    input      [127:0] din_data,
    input      [  4:0] din_bytes,
    input              din_last,
    // output stream
    output reg         dout_valid,
    input              dout_ready,
    output reg [127:0] dout_data,
    output reg [  4:0] dout_bytes,
    output reg         dout_last,
    // result
    input      [127:0] tag_in,          // decrypt: the tag to check against, stable when done rises
    output reg         done,
    output reg [127:0] tag,
    output reg         tag_ok
);

localparam MODE_ENC = 3'd0, MODE_DEC = 3'd1, MODE_HASH = 3'd2, MODE_XOF = 3'd3;     // 4 = CXOF

// Start values of x0 (SP 800-232). They encode the variant, the round counts, the tag or
// hash size and the rate, so two modes can never produce the same output from the same input.
localparam [63:0] IV_AEAD = 64'h0000_1000_808c_0001,
                  IV_HASH = 64'h0000_0801_00cc_0002,
                  IV_XOF  = 64'h0000_0800_00cc_0003,
                  IV_CXOF = 64'h0000_0800_00cc_0004;

// Flipped after the associated data, so "AD = x, message = y" can never be confused with
// some other split of the same bytes.
localparam [63:0] DSEP = 64'h8000_0000_0000_0000;

localparam [3:0] S_IDLE  = 4'd0,
                 S_INIT  = 4'd1,        // permuting the start value
                 S_AD    = 4'd2,        // waiting for an associated-data beat
                 S_AD_P  = 4'd3,        // permuting after an associated-data block
                 S_MSG   = 4'd4,        // waiting for a message beat
                 S_MSG_P = 4'd5,        // permuting after a message block
                 S_FIN   = 4'd6,        // AEAD: last permutation, then the tag
                 S_SQZ   = 4'd7,        // hash modes: give out 8 bytes
                 S_SQZ_P = 4'd8;        // hash modes: permuting between output blocks

reg [ 3:0] st;
reg [ 2:0] mode_r;
reg [63:0] x0, x1, x2, x3, x4;          // the sponge state
reg [63:0] k0, k1;                      // key copy for the two later key additions
reg [ 3:0] rnd;                         // number of the round(s) computed this cycle
reg        pad_pend;                    // the stream ended on a full block: its padding
                                        // still has to go in as a block of its own
reg        last_blk;                    // the block being permuted is the last of its stream
reg        ad_seen;                     // some associated data has been absorbed
reg [31:0] out_left;                    // hash modes: output bytes still to give

wire aead = (mode_r == MODE_ENC) || (mode_r == MODE_DEC);
wire dec  = (mode_r == MODE_DEC);
wire cxof = mode_r[2];

// The permutation: RPC rounds chained, working on the state registers
wire [63:0] r0 [0:RPC], r1 [0:RPC], r2 [0:RPC], r3 [0:RPC], r4 [0:RPC];
assign r0[0] = x0;
assign r1[0] = x1;
assign r2[0] = x2;
assign r3[0] = x3;
assign r4[0] = x4;

genvar g;
generate
    for (g = 0; g < RPC; g = g + 1) begin : round
        wire [3:0] idx = rnd + g;
        ascon_round r (
            .i(idx),
            .x0(r0[g]),   .x1(r1[g]),   .x2(r2[g]),   .x3(r3[g]),   .x4(r4[g]),
            .y0(r0[g+1]), .y1(r1[g+1]), .y2(r2[g+1]), .y3(r3[g+1]), .y4(r4[g+1])
        );
    end
endgenerate

wire [63:0] p0 = r0[RPC], p1 = r1[RPC], p2 = r2[RPC], p3 = r3[RPC], p4 = r4[RPC];

wire [3:0] rnd_next  = rnd + RPC;
wire       perm_last = (rnd_next == 4'd12);

// AEAD data blocks use the 8-round permutation (the last 8 of the 12 rounds), everything
// else uses all 12
wire [3:0] pb_first = aead ? 4'd4 : 4'd0;

// One input beat. n bytes are valid; a short block gets the padding byte 0x01 right after
// its data, which marks where the data ended.
wire [4:0] rate_bytes = aead ? 5'd16 : 5'd8;
wire [4:0] n          = din_bytes;
wire       full       = (n == rate_bytes);

reg [127:0] mask, padv;
integer b;
always @(*) begin
    for (b = 0; b < 16; b = b + 1) begin
        mask[8*b +: 8] = (b <  n) ? 8'hff : 8'h00;
        padv[8*b +: 8] = (b[4:0] == n) ? 8'h01 : 8'h00;
    end
    if (full) padv = 128'b0;
end

wire [127:0] rate   = {x1, x0};
wire [127:0] dout_w = (rate ^ din_data) & mask;     // ciphertext (encrypt) or plaintext (decrypt)

// What is XORed into the rate. Decrypt has to leave the CIPHERTEXT in the rate (as encrypt
// does): rate ^ plaintext = ciphertext for the n data bytes, and the others stay unchanged.
wire [127:0] absorb = (dec && st == S_MSG) ? dout_w : (din_data & mask);
wire [127:0] rate_n = rate ^ absorb ^ padv;

wire out_free = !dout_valid || dout_ready;

assign ready     = (st == S_IDLE);
assign din_ready = (st == S_AD) || (st == S_MSG && (out_free || !aead));

wire [63:0] t0 = p3 ^ k0;               // the tag, valid in the last cycle of S_FIN
wire [63:0] t1 = p4 ^ k1;

// last output block of a hash: only the bytes that were asked for
wire [3:0]  sqz_bytes = (out_left > 32'd8) ? 4'd8 : out_left[3:0];
reg  [63:0] sqz_mask;
always @(*)
    for (b = 0; b < 8; b = b + 1)
        sqz_mask[8*b +: 8] = (b < sqz_bytes) ? 8'hff : 8'h00;

always @(posedge clk) begin
    done <= 1'b0;
    if (dout_valid && dout_ready)
        dout_valid <= 1'b0;

    if (reset) begin
        st         <= S_IDLE;
        dout_valid <= 1'b0;
        tag        <= 128'b0;
        tag_ok     <= 1'b0;
        {x0, x1, x2, x3, x4} <= 320'b0;
        {k1, k0}   <= 128'b0;
    end else case (st)

        S_IDLE: if (start) begin
            mode_r <= mode;
            case (mode)
                MODE_ENC, MODE_DEC: begin
                    x0 <= IV_AEAD;
                    {x2, x1} <= key;
                    {x4, x3} <= nonce;
                    {k1, k0} <= key;
                end
                MODE_HASH: begin x0 <= IV_HASH; {x4, x3, x2, x1} <= 256'b0; {k1, k0} <= 128'b0; end
                MODE_XOF:  begin x0 <= IV_XOF;  {x4, x3, x2, x1} <= 256'b0; {k1, k0} <= 128'b0; end
                default:   begin x0 <= IV_CXOF; {x4, x3, x2, x1} <= 256'b0; {k1, k0} <= 128'b0; end
            endcase
            out_left <= (mode == MODE_HASH) ? 32'd32 : out_len;
            rnd      <= 4'd0;
            pad_pend <= 1'b0;
            last_blk <= 1'b0;
            ad_seen  <= 1'b0;
            tag      <= 128'b0;
            tag_ok   <= 1'b0;
            st       <= S_INIT;
        end

        S_INIT: begin
            {x0, x1, x2, x3, x4} <= {p0, p1, p2, p3, p4};
            rnd <= rnd_next;
            if (perm_last) begin
                // key added again after the first permutation (k = 0 in the hash modes):
                // knowing the state later is then not enough to run backwards to the key
                x3 <= p3 ^ k0;
                x4 <= p4 ^ k1;
                st <= (aead || cxof) ? S_AD : S_MSG;
            end
        end

        S_AD: if (din_valid) begin
            if (aead && din_last && n == 5'd0 && !ad_seen) begin
                // no associated data at all: nothing is absorbed, not even padding
                x4 <= x4 ^ DSEP;
                st <= S_MSG;
            end else begin
                x0 <= rate_n[63:0];
                if (aead) x1 <= rate_n[127:64];
                ad_seen  <= 1'b1;
                pad_pend <= din_last && full;
                last_blk <= din_last && !full;
                rnd      <= pb_first;
                st       <= S_AD_P;
            end
        end

        S_AD_P: begin
            {x0, x1, x2, x3, x4} <= {p0, p1, p2, p3, p4};
            rnd <= rnd_next;
            if (perm_last) begin
                if (pad_pend) begin
                    x0       <= p0 ^ 64'h01;        // a block that is only padding
                    pad_pend <= 1'b0;
                    last_blk <= 1'b1;
                    rnd      <= pb_first;
                end else if (last_blk) begin
                    if (aead) x4 <= p4 ^ DSEP;
                    last_blk <= 1'b0;
                    st       <= S_MSG;
                end else
                    st <= S_AD;
            end
        end

        S_MSG: if (din_valid && din_ready) begin
            x0 <= rate_n[63:0];
            if (aead) begin
                x1         <= rate_n[127:64];
                dout_valid <= 1'b1;
                dout_data  <= dout_w;
                dout_bytes <= n;
                dout_last  <= din_last;
                if (din_last && !full) begin
                    // the last block is not permuted: the final permutation follows directly,
                    // with the key added first so the tag depends on it
                    x2  <= x2 ^ k0;
                    x3  <= x3 ^ k1;
                    rnd <= 4'd0;
                    st  <= S_FIN;
                end else begin
                    pad_pend <= din_last;
                    rnd      <= pb_first;
                    st       <= S_MSG_P;
                end
            end else begin
                pad_pend <= din_last && full;
                last_blk <= din_last && !full;
                rnd      <= 4'd0;
                st       <= S_MSG_P;
            end
        end

        S_MSG_P: begin
            {x0, x1, x2, x3, x4} <= {p0, p1, p2, p3, p4};
            rnd <= rnd_next;
            if (perm_last) begin
                if (pad_pend && aead) begin
                    x0       <= p0 ^ 64'h01;
                    x2       <= p2 ^ k0;
                    x3       <= p3 ^ k1;
                    pad_pend <= 1'b0;
                    rnd      <= 4'd0;
                    st       <= S_FIN;
                end else if (pad_pend) begin
                    x0       <= p0 ^ 64'h01;
                    pad_pend <= 1'b0;
                    last_blk <= 1'b1;
                    rnd      <= 4'd0;
                end else if (last_blk) begin
                    last_blk <= 1'b0;
                    st       <= S_SQZ;
                end else
                    st <= S_MSG;
            end
        end

        S_FIN: begin
            {x0, x1, x2, x3, x4} <= {p0, p1, p2, p3, p4};
            rnd <= rnd_next;
            if (perm_last) begin
                tag    <= dec ? 128'b0 : {t1, t0};
                tag_ok <= dec && ({t1, t0} == tag_in);
                done   <= 1'b1;
                {x0, x1, x2, x3, x4} <= 320'b0;
                {k1, k0} <= 128'b0;
                st     <= S_IDLE;
            end
        end

        S_SQZ: begin
            if (out_left == 32'd0) begin                // XOF asked for 0 bytes
                done <= 1'b1;
                {x0, x1, x2, x3, x4} <= 320'b0;
                st   <= S_IDLE;
            end else if (out_free) begin
                dout_valid <= 1'b1;
                dout_data  <= {64'b0, x0 & sqz_mask};
                dout_bytes <= {1'b0, sqz_bytes};
                dout_last  <= (out_left <= 32'd8);
                if (out_left <= 32'd8) begin
                    done <= 1'b1;
                    {x0, x1, x2, x3, x4} <= 320'b0;
                    st   <= S_IDLE;
                end else begin
                    out_left <= out_left - 32'd8;
                    rnd      <= 4'd0;
                    st       <= S_SQZ_P;
                end
            end
        end

        S_SQZ_P: begin
            {x0, x1, x2, x3, x4} <= {p0, p1, p2, p3, p4};
            rnd <= rnd_next;
            if (perm_last)
                st <= S_SQZ;
        end

        default: st <= S_IDLE;
    endcase
end

// synthesis translate_off
initial
    if (RPC != 1 && RPC != 2 && RPC != 4) begin
        $display("ascon_core: RPC must be 1, 2 or 4 (it has to divide both 12 and 8)");
        $finish;
    end
// synthesis translate_on

endmodule
