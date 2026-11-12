// branch_predictor.v - branch target buffer (BTB) with a 2-bit counter per entry
//
// Without prediction the CPU always fetches PC + 4, and only finds out in Execute that a
// branch or jump was taken. By then two wrong instructions have been fetched and must be
// thrown away (2 lost cycles). Loops take their branch almost every time, so this adds up.
//
// The BTB remembers branches and jal instructions that were taken: where they are (PC)
// and where they go (target). In Fetch, if the current PC is in the BTB and its counter says
// "taken", the next PC is the stored target instead of PC + 4. Execute checks the guess and
// fixes it if it was wrong (see datapath.v).
//
// 2-bit counter: 00, 01 = predict not taken; 10, 11 = predict taken. Taken -> count up,
// not taken -> count down. One unusual result (the last pass of a loop) moves it from
// 11 to 10, which still predicts taken, so the loop is predicted right the next time it runs.
//
// jalr is not stored: its target comes from a register and can change every time
// (function returns), so a stored target would often be wrong.
//
// Only the bits that address the 16 KB instruction memory are stored. PCs or targets
// outside that range are never stored and never predicted, so a partial match can
// never give a wrong prediction.

module branch_predictor #(
    parameter ENTRIES    = 32,
    parameter IMEM_WORDS = 4096
) (
    input         clk, reset,
    // lookup in Fetch
    input  [31:0] pc_f,
    output        pred_taken_f,
    output [31:0] pred_target_f,
    // update from Execute (one branch or jal)
    input         update,
    input  [31:0] pc_e,
    input         taken_e,
    input  [31:0] target_e
);

localparam IW = $clog2(ENTRIES);          // index bits
localparam AW = $clog2(IMEM_WORDS);       // instruction memory word address bits
localparam TW = AW - IW;                  // tag bits

// Small enough to keep in flip-flops, so the lookup is combinational and fits in Fetch
reg          valid  [0:ENTRIES-1];
reg [TW-1:0] tag    [0:ENTRIES-1];
reg [AW-1:0] target [0:ENTRIES-1];        // word address of the target
reg [1:0]    cnt    [0:ENTRIES-1];

integer i;
initial begin
    for (i = 0; i < ENTRIES; i = i + 1) begin
        valid[i] = 0; tag[i] = 0; target[i] = 0; cnt[i] = 0;
    end
end

// PC bits: [31 : AW+2] must be 0 | [AW+1 : IW+2] tag | [IW+1 : 2] index | [1:0] always 0
function in_imem(input [31:0] a);
    in_imem = (a[31:AW+2] == 0);
endfunction

// Lookup
wire [IW-1:0] idx_f = pc_f[IW+1:2];
wire          hit_f = valid[idx_f] && (tag[idx_f] == pc_f[AW+1:IW+2]) && in_imem(pc_f);

assign pred_taken_f  = hit_f && cnt[idx_f][1];
assign pred_target_f = {{(30-AW){1'b0}}, target[idx_f], 2'b00};

// Update
wire [IW-1:0] idx_e = pc_e[IW+1:2];
wire          hit_e = valid[idx_e] && (tag[idx_e] == pc_e[AW+1:IW+2]);
wire          can_store = in_imem(pc_e) && in_imem(target_e);

always @(posedge clk) begin
    if (reset) begin
        for (i = 0; i < ENTRIES; i = i + 1)
            valid[i] <= 0;
    end else if (update && can_store) begin
        if (hit_e) begin
            // known branch: move the counter toward what really happened
            if (taken_e && cnt[idx_e] != 2'b11) cnt[idx_e] <= cnt[idx_e] + 1'b1;
            if (!taken_e && cnt[idx_e] != 2'b00) cnt[idx_e] <= cnt[idx_e] - 1'b1;
        end else if (taken_e) begin
            // new taken branch: store it as "weakly taken". Branches that are never taken
            // are not stored, they would only push out useful entries.
            valid[idx_e]  <= 1'b1;
            tag[idx_e]    <= pc_e[AW+1:IW+2];
            target[idx_e] <= target_e[AW+1:2];
            cnt[idx_e]    <= 2'b10;
        end
    end
end

endmodule
