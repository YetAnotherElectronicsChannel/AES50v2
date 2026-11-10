-- tb_tdm_badfcs.vhd (OpenProSeries): aes50_core's TDM path must never play a damaged block.
-- A stand-alone aes50_tx_framer sends one block (one 48k frame, 6 samples x 48 channels) every 125 us into
-- aes50_core (AES50 master / TDM master, 48k only as on an X32: G_SUPPORT_44K1 = false). Every sample carries its
-- block number, sample index and channel. A TDM8 receiver model decodes the core's TDM output (BCLK / WCLK from the
-- core, 48 channels on lines 0..5). Block 20 is sent with one payload bit flipped (bad FCS): the receiver reports it
-- not ok and the core must drop it (rx_blk_drop_o once). Block 30 is cut short (carrier dropped mid-frame): the
-- receiver never reports it. Checks: every good block plays whole (288 words) on its own channel slots; no word of
-- block 20 or 30 is ever played; the blocks after each fault play again. Without the fix block 20's samples are
-- played (the bench fails). Words that are undefined before the first real word (the TDM output registers before
-- their first load, a simulation start-up value) are ignored; any later one is an error.
-- License: GPL-3.0-or-later
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_tdm_badfcs is
end entity;

architecture sim of tb_tdm_badfcs is
	constant BAD_FCS	: natural := 20;
	constant BAD_CUT	: natural := 30;
	constant NBLK		: natural := 45;
	signal clk			: std_logic := '0';
	signal clka			: std_logic := '0';
	signal rst			: std_logic := '1';
	signal start		: std_logic := '0';
	signal assm			: std_logic := '0';
	signal busy			: std_logic;
	signal raddr		: unsigned(8 downto 0);
	signal rdata		: std_logic_vector(23 downto 0);
	signal txd, txd_w	: std_logic_vector(1 downto 0);
	signal txen, txen_w	: std_logic;
	signal blk			: natural := 0;		-- block number being sent
	signal flip, cut	: boolean := false;
	signal dib			: natural := 0;
	signal bclk, wclk	: std_logic;
	signal tdm			: std_logic_vector(6 downto 0);
	signal drops		: natural := 0;
	signal drop_p		: std_logic;
	-- results of the TDM model
	type seen_t is array (0 to 63) of natural;
	signal seen			: seen_t := (others => 0);	-- words played per block number
	signal bad_words	: natural := 0;
	signal zero_frames	: natural := 0;

	procedure say(s : string) is
		variable l : line;
	begin
		write(l, s); writeline(output, l);
	end procedure;
	function pat(b, a : natural) return std_logic_vector is
	begin
		-- 1 marker bit, block (6 bits), sample (3 bits), channel (6 bits); a = 48 * sample + channel
		return "00000001" & std_logic_vector(to_unsigned(b mod 64, 6)) & std_logic_vector(to_unsigned(a / 48, 4)) &
			   std_logic_vector(to_unsigned(a mod 48, 6));
	end function;
begin
	clk  <= not clk after 10 ns;
	clka <= not clka after 10.1725 ns;

	process (clk) begin
		if rising_edge(clk) then rdata <= pat(blk, to_integer(raddr)); end if;
	end process;
	u_tx : entity work.aes50_tx_framer
		generic map (G_AW => 9)
		port map (clk_i => clk, rst_i => '0', fs48_i => '1', i2s_i => '0', start_i => start, base_i => (others => '0'),
				  assm_i => assm, aux_valid_i => '0', busy_o => busy, frame_o => open, ram_addr_o => raddr,
				  ram_data_i => rdata, aux_addr_o => open, aux_data_i => x"0000", rmii_txd_o => txd, rmii_tx_en_o => txen);
	-- faults on the wire: one payload bit flipped (dibit 400 after the SFD), or the carrier dropped at dibit 2000
	process (clk) begin
		if rising_edge(clk) then
			if txen = '1' then dib <= dib + 1; else dib <= 0; end if;
		end if;
	end process;
	txd_w  <= txd xor "01" when flip and dib = 32 + 400 else txd;
	txen_w <= '0' when cut and dib >= 32 + 2000 else txen;

	u_core : entity work.aes50_core
		generic map (G_SUPPORT_44K1 => false, G_UART_AUX => false, G_TDM_AUX => false)
		port map (
			clk50_i => clk, rst_i => rst, fs_mode_i => "01", sys_mode_i => "01", tdm8_i2s_mode_i => '0',
			aux_tx_tdm_uart_select_i => '0',
			rmii_crs_dv_i => txen_w, rmii_rxd_i => txd_w, rmii_tx_en_o => open, rmii_txd_o => open, phy_rst_n_o => open,
			aes50_clk_a_rx_i => '0', aes50_clk_a_tx_o => open, aes50_clk_a_tx_en_o => open,
			aes50_clk_b_rx_i => '0', aes50_clk_b_tx_o => open, aes50_clk_b_tx_en_o => open,
			clk_1024xfs_from_pll_i => clka, pll_lock_n_i => '0', clk_to_pll_o => open, pll_mult_value_o => open,
			pll_init_busy_i => '0',
			mclk_o => open, wclk_o => wclk, bclk_o => bclk, wclk_readback_i => wclk, bclk_readback_i => bclk,
			wclk_out_en_o => open, bclk_out_en_o => open, tdm_i => (others => '0'), tdm_o => tdm,
			i2s_i => '0', i2s_o => open, aes_ok_o => open, rx_blk_drop_o => drop_p, dbg_o => open, uart_o => open, uart_i => '1',
			debug_out_signal_pulse_len_i => 500000, first_transmit_start_counter_48k_i => 0,
			first_transmit_start_counter_44k1_i => 0, wd_aes_clk_timeout_i => 25, wd_aes_rx_dv_timeout_i => 7500,
			mdix_timer_1ms_reference_i => 50000, aes_clk_ok_counter_reference_i => 500000,
			mult_clk625_48k_i => 8246337, mult_clk625_44k1_i => 7576322, uart_clks_per_bit_i => 434, uart_timeout_clks_i => 500000);

	process (clk) begin
		if rising_edge(clk) then
			if drop_p = '1' then drops <= drops + 1; end if;
		end if;
	end process;

	-- TDM8 receiver model: 256 BCLK a frame from the rising WCLK edge, 32-bit slots, 24-bit MSB first, captured on
	-- the rising BCLK edge (G_FSYNC_DELAY = 0); channel = line * 8 + slot
	process (bclk)
		type sh_t is array (0 to 5) of std_logic_vector(23 downto 0);
		variable sh			: sh_t;
		variable pos		: natural := 0;
		variable wprev		: std_logic := '0';
		variable framed		: boolean := false;
		variable sl, bt, ch, b, smp : natural;
		variable w			: std_logic_vector(23 downto 0);
		variable all_zero	: boolean := true;
		variable cnt		: seen_t := (others => 0);
		variable nbad		: natural := 0;
		variable started	: boolean := false;		-- a real audio word has been played
	begin
		if rising_edge(bclk) then
			if wclk = '1' and wprev = '0' then
				if framed and all_zero then zero_frames <= zero_frames + 1; end if;
				pos := 0; framed := true; all_zero := true;
			end if;
			wprev := wclk;
			if framed then
				sl := pos / 32; bt := pos mod 32;
				if bt <= 23 then
					for i in 0 to 5 loop sh(i) := sh(i)(22 downto 0) & tdm(i); end loop;
				end if;
				if bt = 23 and sl <= 7 then
					for i in 0 to 5 loop
						w := sh(i); ch := i * 8 + sl;
						-- undefined words before the first real one: the TDM output registers before their first load
						-- (a simulation start-up value only; afterwards an undefined word counts as an error)
						if is_x(w) and not started then
							null;
						elsif w /= x"000000" then
							started := true;
							all_zero := false;
							b := to_integer(unsigned(w(15 downto 10))); smp := to_integer(unsigned(w(9 downto 6)));
							if w(23 downto 16) /= x"01" or to_integer(unsigned(w(5 downto 0))) /= ch or smp > 5 then
								nbad := nbad + 1;
							end if;
							cnt(b) := cnt(b) + 1;
						end if;
					end loop;
					seen <= cnt; bad_words <= nbad;
				end if;
				pos := pos + 1;
			end if;
		end if;
	end process;

	process
		variable errors : natural := 0;
		variable t0 : time;
	begin
		wait for 100 ns;
		rst <= '0';
		wait for 1.2 ms;					-- PHY reset (1 ms) inside the core
		for b in 0 to NBLK - 1 loop
			t0 := now;
			wait until rising_edge(clk);
			blk <= b; flip <= (b = BAD_FCS); cut <= (b = BAD_CUT);
			if b = 0 then assm <= '1'; else assm <= '0'; end if;
			start <= '1';
			wait until rising_edge(clk);
			start <= '0';
			wait until busy = '0' and txen = '0';
			wait for 125 us - (now - t0);
		end loop;
		wait for 500 us;
		-- every good block from the second one on (the first may land before the playout starts) is played whole
		for b in 2 to NBLK - 3 loop
			if b /= BAD_FCS and b /= BAD_CUT and seen(b) /= 288 then
				errors := errors + 1; say("FAIL detail: block " & integer'image(b) & " played " & integer'image(seen(b)) & " words, want 288");
			end if;
		end loop;
		if seen(BAD_FCS) /= 0 then errors := errors + 1; say("FAIL detail: " & integer'image(seen(BAD_FCS)) & " words of the bad-FCS block played"); end if;
		if seen(BAD_CUT) /= 0 then errors := errors + 1; say("FAIL detail: " & integer'image(seen(BAD_CUT)) & " words of the truncated block played"); end if;
		if bad_words /= 0 then errors := errors + 1; say("FAIL detail: " & integer'image(bad_words) & " TDM words in the wrong slot or corrupted"); end if;
		if drops /= 1 then errors := errors + 1; say("FAIL detail: " & integer'image(drops) & " blocks reported dropped, want 1 (the bad-FCS block; a cut-short frame is never reported)"); end if;
		say("tb_tdm_badfcs: blocks dropped " & integer'image(drops) & ", silent TDM frames " & integer'image(zero_frames) &
			", block " & integer'image(BAD_FCS + 1) & " / " & integer'image(BAD_CUT + 1) & " played " &
			integer'image(seen(BAD_FCS + 1)) & " / " & integer'image(seen(BAD_CUT + 1)) & " words");
		if errors = 0 then
			say("PASS tb_tdm_badfcs: aes50_core (TDM, 48k only) plays every good block bit-exact on its own slots, never a word of a bad-FCS or truncated block (silence instead), and carries on with the next block");
		else
			say("FAIL tb_tdm_badfcs: " & integer'image(errors) & " errors");
		end if;
		std.env.stop;
		wait;
	end process;
end architecture;
