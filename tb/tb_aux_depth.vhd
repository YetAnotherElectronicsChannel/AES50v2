-- tb_aux_depth.vhd (OpenProSeries): aes50_par_core with 48-word aux pages (G_AUX_WORDS_PER_PAGE = 48, 96-word RAMs).
-- Core A (AES50 master) and core B (slave) over the tb_par_loop cable, at 48 kHz, then 96 kHz (both restarted).
-- Each side fills every requested page to its maximum, 44 words of a 15-bit counter (bit 15 = 0; a page starts at a
-- multiple of 44), then writes 2 more words with bit 15 = 1 (an overlong fill, which the core must drop). The other
-- side reads every block: it must hold exactly 44 words (aux_rx_count_o = 44 at the block start), start on a page
-- boundary, continue the counter bit-exact and never show an overlong word. 20 consecutive good blocks both ways at
-- each rate. The core's index assertions (every aux RAM index < 48) are active all run.
-- License: GPL-3.0-or-later
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_aux_depth is
end entity;

architecture sim of tb_aux_depth is
	constant ASSM_FR	: natural := 64;
	constant WPP		: natural := 48;
	constant NW			: natural := 44;
	signal clk			: std_logic := '0';
	signal clka			: std_logic := '0';
	signal rst			: std_logic := '1';
	signal fs96			: std_logic := '0';
	signal clear		: std_logic := '0';

	signal a_txen, b_txen : std_logic;
	signal a_txd, b_txd : std_logic_vector(1 downto 0);
	signal aa_tx, aa_en, ab_tx, ab_en, ba_tx, ba_en, bb_tx, bb_en, l1, l2 : std_logic;
	type u6_t is array (0 to 1) of unsigned(5 downto 0);
	type s16_t is array (0 to 1) of std_logic_vector(15 downto 0);
	type nat2_t is array (0 to 1) of natural;
	signal areq, arf	: std_logic_vector(0 to 1);
	signal acnt			: u6_t;
	signal ard			: s16_t;
	signal pawe, prd, rv, rf : std_logic_vector(0 to 1) := "00";
	signal pad, rdw		: s16_t := (others => (others => '0'));
	signal runs, maxcnt, overlong : nat2_t := (0, 0);	-- good blocks in a row, largest count seen, overlong words

	procedure say(s : string) is
		variable l : line;
	begin
		write(l, s); writeline(output, l);
	end procedure;
begin
	clk  <= not clk after 10 ns;
	clka <= not clka after 10.1725 ns;
	l1 <= aa_tx when aa_en = '1' else bb_tx when bb_en = '1' else '0';
	l2 <= ab_tx when ab_en = '1' else ba_tx when ba_en = '1' else '0';

	u_a : entity work.aes50_par_core
		generic map (G_ASSM_INIT => (ASSM_FR - 20) * 64, G_ASSM_FRAMES => ASSM_FR, G_CLK_OK_REF => 5000,
					 G_AUX_WORDS_PER_PAGE => WPP)
		port map (clk50_i => clk, rst_i => rst, fs96_i => fs96, sys_mode_i => "01",
				  rmii_crs_dv_i => b_txen, rmii_rxd_i => b_txd, rmii_tx_en_o => a_txen, rmii_txd_o => a_txd, phy_rst_n_o => open,
				  aes50_clk_a_rx_i => l1, aes50_clk_a_tx_o => aa_tx, aes50_clk_a_tx_en_o => aa_en,
				  aes50_clk_b_rx_i => l2, aes50_clk_b_tx_o => ab_tx, aes50_clk_b_tx_en_o => ab_en,
				  clk_1024xfs_from_pll_i => clka, pll_lock_n_i => '0', clk_to_pll_o => open,
				  sample_tick_o => open, par_in_we_i => '0', par_in_ch_i => "000000", par_in_sample_i => x"000000",
				  par_out_valid_o => open, par_out_ch_o => open, par_out_phase_o => open, par_out_sample_o => open,
				  aux_tx_req_o => areq(0), aux_tx_we_i => pawe(0), aux_tx_data_i => pad(0),
				  aux_rx_count_o => acnt(0), aux_rx_rd_i => prd(0), aux_rx_first_o => arf(0), aux_rx_data_o => ard(0),
				  aes_ok_o => open, rx_ok_o => open, tx_started_o => open, tx_frame_o => open, rx_frame_ok_o => open,
				  rx_frame_err_o => open, rx_block_o => open, rx_block_drop_o => open, rx_assm_o => open,
				  fmt_valid_o => open, fmt_bad_o => open, fmt_o => open);
	u_b : entity work.aes50_par_core
		generic map (G_ASSM_FRAMES => ASSM_FR, G_CLK_OK_REF => 5000, G_AUX_WORDS_PER_PAGE => WPP)
		port map (clk50_i => clk, rst_i => rst, fs96_i => fs96, sys_mode_i => "00",
				  rmii_crs_dv_i => a_txen, rmii_rxd_i => a_txd, rmii_tx_en_o => b_txen, rmii_txd_o => b_txd, phy_rst_n_o => open,
				  aes50_clk_a_rx_i => l2, aes50_clk_a_tx_o => ba_tx, aes50_clk_a_tx_en_o => ba_en,
				  aes50_clk_b_rx_i => l1, aes50_clk_b_tx_o => bb_tx, aes50_clk_b_tx_en_o => bb_en,
				  clk_1024xfs_from_pll_i => clka, pll_lock_n_i => '0', clk_to_pll_o => open,
				  sample_tick_o => open, par_in_we_i => '0', par_in_ch_i => "000000", par_in_sample_i => x"000000",
				  par_out_valid_o => open, par_out_ch_o => open, par_out_phase_o => open, par_out_sample_o => open,
				  aux_tx_req_o => areq(1), aux_tx_we_i => pawe(1), aux_tx_data_i => pad(1),
				  aux_rx_count_o => acnt(1), aux_rx_rd_i => prd(1), aux_rx_first_o => arf(1), aux_rx_data_o => ard(1),
				  aes_ok_o => open, rx_ok_o => open, tx_started_o => open, tx_frame_o => open, rx_frame_ok_o => open,
				  rx_frame_err_o => open, rx_block_o => open, rx_block_drop_o => open, rx_assm_o => open,
				  fmt_valid_o => open, fmt_bad_o => open, fmt_o => open);

	gen_side : for side in 0 to 1 generate
		-- producer: 44 counter words per request, then 2 overlong words (bit 15 set)
		process (clk)
			variable c, left : natural := 0;
		begin
			if rising_edge(clk) then
				if areq(side) = '1' then left := NW + 2; c := ((c + NW - 1) / NW) * NW; end if;
				pawe(side) <= '0';
				if left > 0 then
					pawe(side) <= '1';
					if left > 2 then
						pad(side) <= '0' & std_logic_vector(to_unsigned(c, 15)); c := (c + 1) mod (NW * 700);
					else
						pad(side) <= x"8000" or std_logic_vector(to_unsigned(left, 16));
					end if;
					left := left - 1;
				end if;
			end if;
		end process;

		-- reader (as tb_par_loop): pull a word, take it two clocks later
		process (clk)
			variable ph : natural := 0;
		begin
			if rising_edge(clk) then
				prd(side) <= '0'; rv(side) <= '0';
				case ph is
					when 0 => if acnt(side) /= 0 then prd(side) <= '1'; ph := 1; end if;
					when 1 => ph := 2;
					when 2 => rv(side) <= '1'; rf(side) <= arf(side); rdw(side) <= ard(side); ph := 3;
					when others => ph := 0;
				end case;
			end if;
		end process;

		-- checker: what this side receives from the other one
		process (clk)
			variable w, last, n, run, mx : natural := 0;
			variable ok, first : boolean := true;
		begin
			if rising_edge(clk) then
				if to_integer(acnt(side)) > mx then mx := to_integer(acnt(side)); end if;
				if rv(side) = '1' then
					w := to_integer(unsigned(rdw(side)(14 downto 0)));
					-- the overlong markers (14 zero bits) never occur in the aux idle pattern of a block sent unfilled
					if rdw(side) = x"8001" or rdw(side) = x"8002" then
						overlong(side) <= overlong(side) + 1;
						say("FAIL detail: side " & integer'image(side) & " received an overlong word");
					end if;
					if rf(side) = '1' then
						-- a block ends: it was good if it held 44 consecutive words
						if not first and ok and n = NW then run := run + 1; else run := 0; end if;
						ok := w mod NW = 0 and (first or w = (last + 1) mod (NW * 700));
						first := false; n := 0;
					elsif w /= (last + 1) mod (NW * 700) then
						ok := false;
					end if;
					if rdw(side)(15) = '1' then ok := false; end if;
					n := n + 1; last := w;
				end if;
				if clear = '1' then run := 0; first := true; mx := 0; end if;
				runs(side) <= run; maxcnt(side) <= mx;
			end if;
		end process;
	end generate;

	process
		variable errors : natural := 0;
		variable t0 : time;
		procedure run(rate : string) is
		begin
			rst <= '1'; wait for 10 us; clear <= '1'; wait for 1 us; clear <= '0'; rst <= '0';
			t0 := now;
			while not (runs(0) >= 20 and runs(1) >= 20) and now - t0 < 40 ms loop wait for 100 us; end loop;
			if runs(0) >= 20 and runs(1) >= 20 and maxcnt(0) = NW and maxcnt(1) = NW then
				say("tb_aux_depth: " & rate & ": 20 full 44-word pages bit-exact both ways after " & integer'image((now - t0) / 1 us) & " us");
			else
				errors := errors + 1;
				say("FAIL detail " & rate & ": runs A " & integer'image(runs(0)) & " B " & integer'image(runs(1)) &
					", largest count A " & integer'image(maxcnt(0)) & " B " & integer'image(maxcnt(1)));
			end if;
		end procedure;
	begin
		wait for 100 ns;
		run("48k");
		fs96 <= '1';
		run("96k");
		if overlong(0) /= 0 or overlong(1) /= 0 then errors := errors + 1; end if;
		if errors = 0 then
			say("PASS tb_aux_depth: 48-word aux pages (96-word RAMs) at 48k and 96k: every block's 44 aux words bit-exact both ways, overlong fills dropped, every aux index < 48");
		else
			say("FAIL tb_aux_depth: " & integer'image(errors) & " errors");
		end if;
		std.env.stop;
		wait;
	end process;
end architecture;
