// rv_mem.sv - memory model used by the instruction and data memory agents
// Sparse (an associative array of words), so any address works and unused memory costs
// nothing. Never-written words read as 0, the same as the reference model.

class rv_mem extends uvm_object;
    `uvm_object_utils(rv_mem)

    bit [31:0] words [bit [29:0]];      // key = word address (byte address / 4)

    function new(string name = "rv_mem");
        super.new(name);
    endfunction

    function void clear();
        words.delete();
    endfunction

    function bit [31:0] read_word(bit [31:0] addr);
        bit [29:0] wa = addr[31:2];
        return words.exists(wa) ? words[wa] : 32'h0;
    endfunction

    function void write_word(bit [31:0] addr, bit [31:0] data);
        words[addr[31:2]] = data;
    endfunction

    // store of 1, 2 or 4 bytes; size = funct3 of the store (0 sb, 1 sh, 2 sw)
    function void store(bit [31:0] addr, bit [31:0] data, bit [2:0] size);
        bit [31:0] w = read_word(addr);
        case (size[1:0])
            2'd0: w[8*addr[1:0] +: 8] = data[7:0];
            2'd1: w[16*addr[1] +: 16] = data[15:0];
            default: w = data;
        endcase
        write_word(addr, w);
    endfunction

endclass
