# Makefile - UVM verification of the matrix-multiply accelerator with Cadence Xcelium + IMC
#
#   make compile                      compile and elaborate once
#   make run TEST=accel_poke_test     run one test (SEED=, NJOBS=, VERB= optional)
#   make gui TEST=accel_rand_test      same, with SimVision waveforms
#   make regress                      every test in regress.list, then a pass / fail summary
#   make cov_merge cov_report         merge all coverage runs, write reports/ (IMC)
#   make cov_gui                      open the merged coverage in IMC
#   make clean
#
# UVMHOME: CDNS-1.2 (UVM 1.2, default) or CDNS-IEEE (IEEE 1800.2), both ship with Xcelium.

TEST    ?= accel_rand_test
SEED    ?= 1
NJOBS   ?= 200
VERB    ?= UVM_LOW
UVMHOME ?= CDNS-1.2

# -coverage all: code coverage (block, expression, toggle, FSM) on the DUT, functional
# coverage (covergroups) and assertion coverage; -covdut top keeps the DUT and the interface (its SVA lives there)
COMPILE_OPTS = -64bit -sv -uvm -uvmhome $(UVMHOME) -timescale 1ns/1ps -access +rwc \
               -f rtl.f -f tb.f -top top \
               -coverage all -covdut top

RUN_OPTS = -R -64bit +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) +NJOBS=$(NJOBS) \
           -svseed $(SEED) -covworkdir cov_work -covscope scope \
           -covtest $(TEST)_s$(SEED) -covoverwrite

.PHONY: help compile run gui regress cov_merge cov_report cov_gui clean

help:
	@sed -n '3,13p' Makefile

compile:
	mkdir -p logs
	xrun -elaborate $(COMPILE_OPTS) -l logs/compile.log

run: compile
	xrun $(RUN_OPTS) -l logs/$(TEST)_s$(SEED).log
	@grep -E "TEST (PASSED|FAILED)" logs/$(TEST)_s$(SEED).log || echo "no result line: check logs/$(TEST)_s$(SEED).log"

gui: compile
	xrun $(RUN_OPTS) -gui -l logs/$(TEST)_s$(SEED)_gui.log

# regress.list: one "test seed njobs" per line
regress: compile
	@rm -f logs/regress_summary.txt
	@while read t s n; do \
	    case "$$t" in ""|\#*) continue ;; esac; \
	    echo "== $$t seed $$s"; \
	    xrun -R -64bit +UVM_TESTNAME=$$t +UVM_VERBOSITY=UVM_LOW +NJOBS=$$n -svseed $$s \
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
