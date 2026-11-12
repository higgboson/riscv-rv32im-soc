// uart_loader.v - loads a new program over the UART, so changing programs does not need
// a new bitstream (Vivado takes minutes, this takes about a second).
//
// It listens to every received byte. When it sees "RVLD" it holds the CPU in reset and
// expects (all numbers little-endian):
//   n_imem  : 2 bytes, number of 32-bit words for instruction memory
//   n_dmem  : 2 bytes, number of 32-bit words for data memory
//   words   : n_imem words, then n_dmem words, 4 bytes each
//   check   : 4 bytes, sum of all words (32-bit, wraps around)
// If the sum matches it answers 'K' and lets the CPU start from address 0.
// If not it answers 'E' and keeps the CPU stopped, so a damaged program never runs.
// Pressing reset (btnC) always brings the loader back to listening.
// sw/load.py on the PC sends this packet.

module uart_loader #(parameter AW = 12) (     // AW = word-address bits of each memory
    input             clk, reset,
    input             rx_valid,
    input      [7:0]  rx_data,
    output reg        active,                 // receiving a program: CPU held in reset
    output reg        hold,                   // last load failed: CPU stays stopped
    output reg        imem_we, dmem_we,       // one-cycle write pulses
    output reg [AW-1:0] waddr,                // word address in that memory
    output reg [31:0] wdata,
    output reg        tx_we,                  // reply byte for the PC
    output reg [7:0]  tx_data
);

localparam S_IDLE = 3'd0, S_HDR = 3'd1, S_IMEM = 3'd2, S_DMEM = 3'd3, S_CHECK = 3'd4;

reg [2:0]  state;
reg [1:0]  match;          // how many bytes of "RVLD" have been seen in a row
reg [1:0]  byte_idx;       // byte position inside the current 32-bit word
reg [31:0] word;           // the word being collected
reg [15:0] n_imem, n_dmem;
reg [15:0] count;          // words done in the current section
reg [31:0] sum;

// the 4-byte word including the byte arriving now
wire [31:0] word_next = {rx_data, word[31:8]};
wire        word_done = (byte_idx == 2'd3);

function [7:0] magic(input [1:0] i);
    case (i)
        2'd0: magic = "R";
        2'd1: magic = "V";
        2'd2: magic = "L";
        default: magic = "D";
    endcase
endfunction

always @(posedge clk) begin
    imem_we <= 1'b0;
    dmem_we <= 1'b0;
    tx_we   <= 1'b0;

    if (reset) begin
        state    <= S_IDLE;
        active   <= 1'b0;
        hold     <= 1'b0;
        match    <= 0;
        byte_idx <= 0;
    end else if (rx_valid) begin
        word     <= word_next;
        byte_idx <= byte_idx + 1'b1;

        case (state)
            S_IDLE: begin
                byte_idx <= 0;
                if (rx_data == magic(match)) begin
                    match <= match + 1'b1;
                    if (match == 2'd3) begin
                        state  <= S_HDR;
                        active <= 1'b1;
                        sum    <= 0;
                    end
                end else begin
                    // a wrong byte can still be the start of a new "RVLD"
                    match <= (rx_data == "R") ? 2'd1 : 2'd0;
                end
            end

            S_HDR: if (word_done) begin
                n_imem <= word_next[15:0];
                n_dmem <= word_next[31:16];
                count  <= 0;
                state  <= (word_next[15:0]  != 0) ? S_IMEM :
                          (word_next[31:16] != 0) ? S_DMEM : S_CHECK;
            end

            S_IMEM: if (word_done) begin
                imem_we <= 1'b1;
                waddr   <= count[AW-1:0];
                wdata   <= word_next;
                sum     <= sum + word_next;
                if (count == n_imem - 1'b1) begin
                    count <= 0;
                    state <= (n_dmem != 0) ? S_DMEM : S_CHECK;
                end else
                    count <= count + 1'b1;
            end

            S_DMEM: if (word_done) begin
                dmem_we <= 1'b1;
                waddr   <= count[AW-1:0];
                wdata   <= word_next;
                sum     <= sum + word_next;
                if (count == n_dmem - 1'b1)
                    state <= S_CHECK;
                else
                    count <= count + 1'b1;
            end

            default: if (word_done) begin          // S_CHECK
                tx_we   <= 1'b1;
                tx_data <= (word_next == sum) ? "K" : "E";
                hold    <= (word_next != sum);
                active  <= 1'b0;
                match   <= 0;
                state   <= S_IDLE;
            end
        endcase
    end
end

endmodule
