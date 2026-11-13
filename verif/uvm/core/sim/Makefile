# Makefile - UVM verification of the RV32IM core with Cadence Xcelium + IMC
#
#   make compile                      compile and elaborate once
#   make run TEST=core_hazard_test    run one test (SEED=, NPROG=, VERB= optional)
#   make gui TEST=core_rand_test      same, with SimVision waveforms
#   make riscv_tests                  the 48 official ISA tests inside UVM
#   make regress                      every test in regress.list, then a pass / fail summary
#   make cov_merge cov_report         merge all coverage runs, write reports/ (IMC)
#   make cov_gui                      open the merged coverage in IMC
#   make clean
#
# UVMHOME: CDNS-1.2 (UVM 1.2, default) or CDNS-IEEE (IEEE 1800.2), both ship with Xcelium.
# BPRED=0 builds the core without the branch predictor (same as the RTL's NO_BPRED switch).

TEST    ?= core_rand_test
SEED    ?= 1
NPROG   ?= 20
VERB    ?= UVM_LOW
BPRED   ?= 1
UVMHOME ?= CDNS-1.2

DEFS =
ifeq ($(BPRED),0)
DEFS += -define NO_BPRED
endif

# -coverage all: code coverage (block, expression, toggle, FSM) on the DUT, functional
# coverage (covergroups) and assertion coverage; -covdut limits code coverage to the CPU
COMPILE_OPTS = -64bit -sv -uvm -uvmhome $(UVMHOME) -timescale 1ns/1ps -access +rwc \
               -f rtl.f -f tb.f ../ref/rv32im_iss.c -top top $(DEFS) \
               -coverage all -covdut riscv_cpu

RUN_OPTS = -R -64bit +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) +NPROG=$(NPROG) \
           -svseed $(SEED) -covworkdir cov_work -covscope scope \
           -covtest $(TEST)_s$(SEED) -covoverwrite

.PHONY: help compile run gui riscv_tests regress cov_merge cov_report cov_gui clean

help:
	@sed -n '3,15p' Makefile

compile:
	mkdir -p logs
	xrun -elaborate $(COMPILE_OPTS) -l logs/compile.log

run: compile
	xrun $(RUN_OPTS) -l logs/$(TEST)_s$(SEED).log
	@grep -E "TEST (PASSED|FAILED)" logs/$(TEST)_s$(SEED).log || echo "no result line: check logs/$(TEST)_s$(SEED).log"

gui: compile
	xrun $(RUN_OPTS) -gui -l logs/$(TEST)_s$(SEED)_gui.log

riscv_tests:
	$(MAKE) run TEST=core_riscv_tests SEED=1

# regress.list: one "test seed nprog" per line
regress: compile
	@rm -f logs/regress_summary.txt
	@while read t s n; do \
	    case "$$t" in ""|\#*) continue ;; esac; \
	    echo "== $$t seed $$s"; \
	    xrun -R -64bit +UVM_TESTNAME=$$t +UVM_VERBOSITY=UVM_LOW +NPROG=$$n -svseed $$s \
	         -covworkdir cov_work -covscope scope -covtest $${t}_s$$s -covoverwrite \
	         -l logs/$${t}_s$$s.log > /dev/null; \
	    r=$$(grep -hoE "TEST (PASSED|FAILED)" logs/$${t}_s$$s.log | head -1); \
	    printf "%-22s seed %-10s %s\n" "$$t" "$$s" "$${r:-NO RESULT (crash?)}" | tee -a logs/regress_summary.txt; \
	done < regress.list
	@echo; echo "passed: $$(grep -c PASSED logs/regress_summary.txt)  failed: $$(grep -vc PASSED logs/regress_summary.txt)"

cov_merge:
	imc -exec imc_merge.tcl -nocopyright

cov_report:
	mkdir -p reports
	imc -exec imc_report.tcl -nocopyright
	@echo "reports written to reports/"

cov_gui:
	imc -load cov_work/scope/merged &

clean:
	rm -rf xcelium.d xrun.* cov_work logs reports waves.shm .simvision *.history *.log *.key INCA_libs
