// prog_seqs.sv - sequences of programs
//
// rand_prog_seq : n random programs. Tests change the mix through knobs or by replacing
//                 rv_program with an extended class (factory override, see core_test_lib.sv).
// file_prog_seq : programs loaded from image files, e.g. the official riscv-tests.

class rand_prog_seq extends uvm_sequence #(rv_program);
    `uvm_object_utils(rand_prog_seq)

    int unsigned n_programs = 10;

    function new(string name = "rand_prog_seq");
        super.new(name);
    endfunction

    task body();
        for (int i = 0; i < n_programs; i++) begin
            req = rv_program::type_id::create($sformatf("prog%0d", i));
            start_item(req);
            if (!req.randomize())
                `uvm_fatal("SEQ", "program randomize failed")
            req.name_tag = $sformatf("random program %0d", i);
            finish_item(req);
        end
    endtask

endclass

class file_prog_seq extends uvm_sequence #(rv_program);
    `uvm_object_utils(file_prog_seq)

    string dir;              // folder with <name>.img files and list.txt
    string names[$];         // empty: read them from dir/list.txt

    function new(string name = "file_prog_seq");
        super.new(name);
    endfunction

    task body();
        if (names.size() == 0) begin
            int fd = $fopen({dir, "/list.txt"}, "r");
            string n;
            if (fd == 0)
                `uvm_fatal("SEQ", {"cannot open ", dir, "/list.txt"})
            while ($fscanf(fd, "%s", n) == 1)
                names.push_back(n);
            $fclose(fd);
        end
        foreach (names[i]) begin
            req = rv_program::type_id::create(names[i]);
            start_item(req);
            req.img_file = {dir, "/", names[i], ".img"};
            req.name_tag = names[i];
            if (!req.load_image(req.img_file))
                `uvm_fatal("SEQ", {"cannot open ", req.img_file})
            finish_item(req);
        end
    endtask

endclass
