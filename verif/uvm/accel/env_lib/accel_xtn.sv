// accel_xtn.sv - one tile job: C (+)= A x B for a 4 x K A and a K x 4 B
//
// The driver uses the rand fields as stimulus. The monitor builds its own accel_xtn from
// what it saw on the bus (the operands that were really in the buffers, the 16 results
// that were read, how long the run took), and that one goes to the scoreboard.

class accel_xtn extends uvm_sequence_item;

    rand int unsigned     k;          // 1 .. 64 steps
    rand bit              clear;      // 0: add onto the previous C (long sums in pieces)
    rand bit              reload_a;   // 0: keep the A buffer from the previous job, as accel.h does
    rand int unsigned     gap;        // idle cycles before the job; 0 = back to back
    rand bit              poke;       // write start again while busy; it must be ignored
    rand int unsigned     poke_at;
    rand bit signed [7:0] a [4][64];
    rand bit signed [7:0] b [64][4];

    // weight of each edge value (-128, 127, -1, 0) against 100 for the rest; set before randomize
    int unsigned edge_w = 10;

    // filled in by the monitor
    int          c [4][4];
    int unsigned cycles;
    bit          poked;

    constraint c_k     { k dist { 1 := 5, [2:63] :/ 80, 64 := 15 }; }
    constraint c_gap   { gap dist { 0 := 30, [1:3] :/ 50, [4:20] :/ 20 }; }
    constraint c_flags { clear    dist { 1 := 75, 0 := 25 };
                         reload_a dist { 1 := 80, 0 := 20 };
                         poke     dist { 0 := 90, 1 := 10 }; }
    // k + 4 keeps the poke inside the run with a cycle to spare (the run is k + 6 long)
    constraint c_poke  { poke_at inside {[1:k+4]}; solve k before poke_at; }
    constraint c_vals  {
        foreach (a[i, kk]) a[i][kk] dist { -128 := edge_w, 127 := edge_w, -1 := edge_w, 0 := edge_w,
                                           [-127:-2] :/ 50, [1:126] :/ 50 };
        foreach (b[kk, j]) b[kk][j] dist { -128 := edge_w, 127 := edge_w, -1 := edge_w, 0 := edge_w,
                                           [-127:-2] :/ 50, [1:126] :/ 50 };
    }

    `uvm_object_utils_begin(accel_xtn)
        `uvm_field_int(k,        UVM_ALL_ON | UVM_DEC)
        `uvm_field_int(clear,    UVM_ALL_ON)
        `uvm_field_int(reload_a, UVM_ALL_ON)
        `uvm_field_int(gap,      UVM_ALL_ON | UVM_DEC)
        `uvm_field_int(poke,     UVM_ALL_ON)
        `uvm_field_int(cycles,   UVM_ALL_ON | UVM_DEC)
    `uvm_object_utils_end

    function new(string name = "accel_xtn");
        super.new(name);
    endfunction

    // the bus words: byte i of A_COL[kk] is row i, byte j of B_ROW[kk] is column j
    function bit [31:0] a_word(int kk);
        return {a[3][kk], a[2][kk], a[1][kk], a[0][kk]};
    endfunction
    function bit [31:0] b_word(int kk);
        return {b[kk][3], b[kk][2], b[kk][1], b[kk][0]};
    endfunction

endclass
