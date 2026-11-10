# OpenProSeries: GHDL benches for the v2 core. Each bench is tb_<name>.vhd plus tb_<name>.files (the rtl/ files it
# needs, in compile order). `make check` runs them all and prints one PASS / FAIL line per bench; it fails on any
# FAIL or on a bench that printed no PASS. Build output in $(B) (default build/, next to this file).
GHDL ?= ghdl
B    ?= $(CURDIR)/build
TBS  := $(patsubst %.vhd,%,$(wildcard tb_*.vhd))
.PHONY: check
check: $(TBS:%=$(B)/%.log)
	@grep -hE '^(PASS|FAIL)' $^; for f in $^; do grep -q '^PASS' $$f && ! grep -q '^FAIL' $$f || exit 1; done
$(B)/%.log: %.vhd %.files $(addprefix ../rtl/,$(sort $(shell cat $(wildcard tb_*.files))))
	@rm -rf $(B)/$* && mkdir -p $(B)/$*
	@cd $(B)/$* && { $(GHDL) -a --std=08 -frelaxed $(addprefix $(CURDIR)/../rtl/,$(shell cat $*.files)) $(CURDIR)/$*.vhd && \
	    $(GHDL) -e --std=08 -frelaxed $* && $(GHDL) -r --std=08 -frelaxed $* --assert-level=error --ieee-asserts=disable-at-0 --ieee-asserts=disable; } > $@ 2>&1 || echo "FAIL $* (ghdl exit, see $@)" >> $@
