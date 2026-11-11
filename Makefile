# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Aref Ghoreishi
#
#   make test      unit testbenches, route trace, system runs + golden checker on both data sets
#   make sweep     FIFO depth 1-8 x delay 0-7, both topologies, both data sets
#   make results   sweep + scripts/analyze.py -> results/
#   make clean

GHDL    ?= ghdl
PYTHON  ?= python3
WORK    := build/work
GHDLOPT := --std=08 --workdir=$(WORK)
RUN     := $(PYTHON) scripts/run_tb.py --ghdl $(GHDL) --workdir $(WORK)
CHECK   := $(PYTHON) scripts/check.py --quiet

RTL := rtl/noc_pkg.vhd rtl/noc_fifo.vhd rtl/noc_switch.vhd rtl/master_ip.vhd \
       rtl/slave_ip.vhd rtl/noc_top.vhd
TB  := tb/common/handshake_check.vhd \
       tb/unit/fifo_tb.vhd tb/unit/switch_tb.vhd tb/unit/slave_tb.vhd tb/unit/master_tb.vhd \
       tb/unit/regression_tb.vhd tb/unit/handshake_check_tb.vhd \
       tb/system/noc_sweep_tb.vhd tb/system/noc_tb.vhd

.PHONY: all test unit route system sweep results clean
.DELETE_ON_ERROR:

all: test

$(WORK)/.analyzed: $(RTL) $(TB)
	@mkdir -p $(WORK)
	@rm -f $(WORK)/*.cf
	$(GHDL) -a $(GHDLOPT) -Wall $(RTL) $(TB)
	@touch $@

test: unit route system
	@echo "make test: all checks passed"

unit: $(WORK)/.analyzed
	@echo "== unit testbenches"
	@for d in 1 2 4; do $(RUN) fifo_tb -gDEPTH=$$d || exit 1; done
	@for d in 1 2 4; do for t in 0 1 3 7; do \
	  $(RUN) switch_tb -gFIFO_DEPTH=$$d -gDELAY=$$t || exit 1; done; done
	@$(RUN) slave_tb
	@$(RUN) master_tb
	@$(RUN) master_tb -gDATA_FILE=tb/unit/data/bad_valid_size.txt -gCHECK_PADDING=false \
	  --log build/logs/master_tb_bad.log \
	  --expect-fail "tb/unit/data/bad_valid_size.txt:2: valid_size=9 out of range 0..8"
	@$(RUN) regression_tb
	@$(RUN) handshake_check_tb --expect-errors 3

route:
	@echo "== routing tables"
	@$(PYTHON) scripts/route_trace.py

# Default configuration (depth 2, delay 7), both topologies, both data sets. The baseline
# replies are also compared with the original ModelSim logs of each topology.
system: $(WORK)/.analyzed
	@echo "== system runs"
	@mkdir -p build/system
	@for t in NOC1 NOC2; do \
	  $(RUN) noc_tb -gTOPOLOGY=$$t -gOUT_PREFIX=build/system/$${t}_baseline_ \
	    --pass "NOC_SWEEP_TB PASS" || exit 1; \
	  $(CHECK) build/system/$${t}_baseline_ --topology $$t --data data/baseline \
	    --regress data/golden || exit 1; \
	  $(RUN) noc_tb -gTOPOLOGY=$$t -gOUT_PREFIX=build/system/$${t}_stress_ \
	    -gDATA_DIR=data/stress/ --pass "NOC_SWEEP_TB PASS" || exit 1; \
	  $(CHECK) build/system/$${t}_stress_ --topology $$t --data data/stress || exit 1; \
	done

sweep: $(WORK)/.analyzed
	$(PYTHON) scripts/sweep.py --ghdl $(GHDL) --workdir $(WORK)

results: sweep
	@mkdir -p build/mpl
	MPLCONFIGDIR=build/mpl $(PYTHON) scripts/analyze.py

clean:
	rm -rf build
