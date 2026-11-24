# OpenProSeries: GHDL benches for the v2 core. Each bench is tb_<name>.vhd plus tb_<name>.files (the rtl/ files it
# needs, in compile order). `make check` runs them all and prints one PASS / FAIL line per bench; it fails on any
# FAIL or on a bench that printed no PASS. Build output in $(B) (default build/, next to this file).
# tb_neg_<name> is a negative bench: it must stop on an assertion, and passes when the run fails with the text on
# its "-- EXPECT: " line.
GHDL ?= ghdl
B    ?= $(CURDIR)/build
TBS  := $(patsubst %.vhd,%,$(wildcard tb_*.vhd))
RTL  := $(addprefix ../rtl/,$(sort $(shell cat $(wildcard tb_*.files))))
.PHONY: check
check: $(TBS:%=$(B)/%.log)
	@grep -hE '^(PASS|FAIL)' $^; for f in $^; do grep -q '^PASS' $$f && ! grep -q '^FAIL' $$f || exit 1; done
$(B)/%.log: %.vhd %.files $(RTL)
	@rm -rf $(B)/$* && mkdir -p $(B)/$*
	@cd $(B)/$* && { $(GHDL) -a --std=08 -frelaxed $(addprefix $(CURDIR)/../rtl/,$(shell cat $*.files)) $(CURDIR)/$*.vhd && \
	    $(GHDL) -e --std=08 -frelaxed $* && $(GHDL) -r --std=08 -frelaxed $* --assert-level=error --ieee-asserts=disable-at-0 --ieee-asserts=disable; } > $@ 2>&1 || echo "FAIL $* (ghdl exit, see $@)" >> $@
$(B)/tb_neg_%.log: tb_neg_%.vhd tb_neg_%.files $(RTL)
	@rm -rf $(B)/tb_neg_$* && mkdir -p $(B)/tb_neg_$*
	@cd $(B)/tb_neg_$* && x="$$(sed -n 's/^-- EXPECT: //p' $(CURDIR)/tb_neg_$*.vhd)"; \
	  if ! $(GHDL) -a --std=08 -frelaxed $(addprefix $(CURDIR)/../rtl/,$(shell cat tb_neg_$*.files)) $(CURDIR)/tb_neg_$*.vhd > $@ 2>&1; then \
	    echo "FAIL tb_neg_$* (ghdl -a, see $@)" >> $@; \
	  elif { $(GHDL) -e --std=08 -frelaxed tb_neg_$* && $(GHDL) -r --std=08 -frelaxed tb_neg_$* --assert-level=error --ieee-asserts=disable; } >> $@ 2>&1; then \
	    echo "FAIL tb_neg_$*: ran to the end without the expected assertion" >> $@; \
	  elif [ -n "$$x" ] && grep -qF "$$x" $@; then \
	    echo "PASS tb_neg_$*: stopped as expected: $$x" >> $@; \
	  else \
	    echo "FAIL tb_neg_$*: stopped, but not with the expected assertion (see $@)" >> $@; \
	  fi
