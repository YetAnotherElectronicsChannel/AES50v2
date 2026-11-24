-- tb_user_octet48.vhd (OpenProSeries): tb_user_octet with both cores at G_AUX_WORDS_PER_PAGE = 48 (96-word aux RAMs,
-- the parent's setting), to show the user octet path and the smaller aux pages work together. Otherwise the same:
-- the AES50 header user octet (frame octet 15) through aes50_par_core, both ways.
-- Core A (AES50 master) and core B (slave) over the tb_par_loop cable. A decoder on each wire reads octet 15 of
-- every frame straight from RMII. At 48 kHz, then again at 96 kHz (both cores restarted):
--  1. reset: user_octet_rx_o is 0x00 at once, and with user_octet_tx_i = 0x00 every frame on the wire carries 0x00;
--  2. hold: user_octet_tx_i set once (A 0x5A, B 0xA5) is sent unchanged in every later frame, and the far side
--     reads it;
--  3. good frames only: user_octet_rx_o may change only in the clock of a good-FCS frame (rx_frame_ok_o), all run;
--  4. bad FCS: A sends 0xC3 while one payload dibit of every frame towards B is flipped; B keeps reading 0x5A
--     through those frames, then reads 0xC3 from the first good one;
--  5. lock-step exchange: software on each side (modelled here, the core has no protocol logic) runs a nibble
--     channel in the octet: bit 7 toggles per nibble, bit 4 = more nibbles follow, bits 3..0 = data, low nibble
--     first; a side sends its next nibble only when the peer's bit 7 changed. Both start from the idle octet 0xAA.
--     A's octets on the wire must be exactly 30 B4 31 B0 30 B0 31 B0 30 B0 30 B0 30 B0 30 A0, repeated, for its
--     message 40 01 00 01 00 00 00 00; each side must receive the other's 8-byte message bit-exact 3 times.
-- License: GPL-3.0-or-later
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_user_octet48 is
end entity;

architecture sim of tb_user_octet48 is
	constant ASSM_FR	: natural := 64;
	subtype byte is std_logic_vector(7 downto 0);
	type bytes_t is array (natural range <>) of byte;
	type nat2_t is array (0 to 1) of natural;
	constant MSG		: bytes_t(0 to 15) := (x"40", x"01", x"00", x"01", x"00", x"00", x"00", x"00",	-- A's
											   x"28", x"02", x"01", x"00", x"00", x"00", x"00", x"00");	-- B's
	constant WIRE_A		: bytes_t(0 to 15) := (x"30", x"B4", x"31", x"B0", x"30", x"B0", x"31", x"B0",
											   x"30", x"B0", x"30", x"B0", x"30", x"B0", x"30", x"A0");

	signal clk			: std_logic := '0';
	signal clka			: std_logic := '0';
	signal rst			: std_logic := '1';
	signal fs96			: std_logic := '0';
	signal corrupt		: std_logic := '0';

	signal a_txen, b_txen : std_logic;
	signal a_txd, b_txd, b_rxd : std_logic_vector(1 downto 0);
	signal aa_tx, aa_en, ab_tx, ab_en, ba_tx, ba_en, bb_tx, bb_en, l1, l2 : std_logic;
	signal a_fok, b_fok, b_ferr : std_logic;
	signal utx			: bytes_t(0 to 1) := (others => x"00");	-- core inputs, driven by the software model
	signal urx			: bytes_t(0 to 1);
	signal a_dib, b_dib	: natural := 0;			-- index of the dibit on the wire in the current frame

	-- set by the main process; the software model copies it to the core input while xchg = '0'
	signal set_v		: bytes_t(0 to 1) := (others => x"00");
	signal xchg			: std_logic := '0';
	-- results
	signal n_fok		: nat2_t := (0, 0);		-- good frames received by A / B
	signal n_ferr_b		: natural := 0;
	signal msgs, bad_msgs : nat2_t := (0, 0);	-- complete messages received by A / B, wrong ones
	signal latch_errs	: nat2_t := (0, 0);		-- user_octet_rx_o changed to non-zero outside a good frame
	-- wire decoders: octet 15 of every frame from A (index 0) / B (index 1)
	signal w15			: bytes_t(0 to 1) := (others => x"00");
	signal n_w			: nat2_t := (0, 0);		-- frames seen on the wire
	signal w_clear		: std_logic := '0';
	signal want			: bytes_t(0 to 1) := (others => x"00");
	signal w_other		: nat2_t := (0, 0);		-- frames since w_clear whose octet 15 /= want
	signal wire_idx, wire_bad : natural := 0;	-- A's exchange octets checked against WIRE_A, mismatches

	procedure say(s : string) is
		variable l : line;
	begin
		write(l, s); writeline(output, l);
	end procedure;
	function hx(b : byte) return string is
		constant H : string(1 to 16) := "0123456789ABCDEF";
	begin
		return H(to_integer(unsigned(b(7 downto 4))) + 1) & H(to_integer(unsigned(b(3 downto 0))) + 1);
	end function;
begin
	clk  <= not clk after 10 ns;
	clka <= not clka after 10.1725 ns;

	-- cable (as tb_par_loop, never cut); A -> B flips dibit 200 (payload) of every frame while corrupt = '1'
	l1 <= aa_tx when aa_en = '1' else bb_tx when bb_en = '1' else '0';
	l2 <= ab_tx when ab_en = '1' else ba_tx when ba_en = '1' else '0';
	b_rxd <= a_txd xor "01" when corrupt = '1' and a_txen = '1' and a_dib = 200 else a_txd;

	process (clk)
	begin
		if rising_edge(clk) then
			if a_txen = '1' then a_dib <= a_dib + 1; else a_dib <= 0; end if;
			if b_txen = '1' then b_dib <= b_dib + 1; else b_dib <= 0; end if;
		end if;
	end process;

	u_a : entity work.aes50_par_core
		generic map (G_ASSM_INIT => (ASSM_FR - 20) * 64, G_ASSM_FRAMES => ASSM_FR, G_CLK_OK_REF => 5000, G_AUX_WORDS_PER_PAGE => 48)
		port map (clk50_i => clk, rst_i => rst, fs96_i => fs96, sys_mode_i => "01",
				  rmii_crs_dv_i => b_txen, rmii_rxd_i => b_txd, rmii_tx_en_o => a_txen, rmii_txd_o => a_txd, phy_rst_n_o => open,
				  aes50_clk_a_rx_i => l1, aes50_clk_a_tx_o => aa_tx, aes50_clk_a_tx_en_o => aa_en,
				  aes50_clk_b_rx_i => l2, aes50_clk_b_tx_o => ab_tx, aes50_clk_b_tx_en_o => ab_en,
				  clk_1024xfs_from_pll_i => clka, pll_lock_n_i => '0', clk_to_pll_o => open,
				  sample_tick_o => open, par_in_we_i => '0', par_in_ch_i => "000000", par_in_sample_i => x"000000",
				  par_out_valid_o => open, par_out_ch_o => open, par_out_phase_o => open, par_out_sample_o => open,
				  aux_tx_req_o => open, aux_tx_we_i => '0', aux_tx_data_i => x"0000",
				  aux_rx_count_o => open, aux_rx_rd_i => '0', aux_rx_first_o => open, aux_rx_data_o => open,
				  aes_ok_o => open, rx_ok_o => open, tx_started_o => open, tx_frame_o => open, rx_frame_ok_o => a_fok,
				  rx_frame_err_o => open, rx_block_o => open, rx_block_drop_o => open, rx_assm_o => open,
				  fmt_valid_o => open, fmt_bad_o => open, fmt_o => open,
				  user_octet_tx_i => utx(0), user_octet_rx_o => urx(0));
	u_b : entity work.aes50_par_core
		generic map (G_ASSM_FRAMES => ASSM_FR, G_CLK_OK_REF => 5000, G_AUX_WORDS_PER_PAGE => 48)
		port map (clk50_i => clk, rst_i => rst, fs96_i => fs96, sys_mode_i => "00",
				  rmii_crs_dv_i => a_txen, rmii_rxd_i => b_rxd, rmii_tx_en_o => b_txen, rmii_txd_o => b_txd, phy_rst_n_o => open,
				  aes50_clk_a_rx_i => l2, aes50_clk_a_tx_o => ba_tx, aes50_clk_a_tx_en_o => ba_en,
				  aes50_clk_b_rx_i => l1, aes50_clk_b_tx_o => bb_tx, aes50_clk_b_tx_en_o => bb_en,
				  clk_1024xfs_from_pll_i => clka, pll_lock_n_i => '0', clk_to_pll_o => open,
				  sample_tick_o => open, par_in_we_i => '0', par_in_ch_i => "000000", par_in_sample_i => x"000000",
				  par_out_valid_o => open, par_out_ch_o => open, par_out_phase_o => open, par_out_sample_o => open,
				  aux_tx_req_o => open, aux_tx_we_i => '0', aux_tx_data_i => x"0000",
				  aux_rx_count_o => open, aux_rx_rd_i => '0', aux_rx_first_o => open, aux_rx_data_o => open,
				  aes_ok_o => open, rx_ok_o => open, tx_started_o => open, tx_frame_o => open, rx_frame_ok_o => b_fok,
				  rx_frame_err_o => b_ferr, rx_block_o => open, rx_block_drop_o => open, rx_assm_o => open,
				  fmt_valid_o => open, fmt_bad_o => open, fmt_o => open,
				  user_octet_tx_i => utx(1), user_octet_rx_o => urx(1));

	gen_side : for side in 0 to 1 generate
		-- wire decoder: octet 15 = dibits 92..95 after the start of the preamble (32 dibits preamble + SFD)
		process (clk)
			variable o : byte;
			variable en : std_logic;
			variable d : std_logic_vector(1 downto 0);
			variable i : natural;
		begin
			if rising_edge(clk) then
				if side = 0 then en := a_txen; d := a_txd; i := a_dib; else en := b_txen; d := b_txd; i := b_dib; end if;
				if en = '1' and i >= 92 and i <= 95 then
					o := d & o(7 downto 2);
					if i = 95 then
						w15(side) <= o;
						n_w(side) <= n_w(side) + 1;
						if o /= want(side) and w_clear = '0' then w_other(side) <= w_other(side) + 1; end if;
					end if;
				end if;
				if w_clear = '1' then w_other(side) <= 0; end if;
			end if;
		end process;

		-- good frames; user_octet_rx_o may only change (to a non-zero value) in the clock of a good frame
		process (clk)
			variable prev : byte := x"00";
			variable fok : std_logic;
		begin
			if rising_edge(clk) then
				if side = 0 then fok := a_fok; else fok := b_fok; end if;
				if fok = '1' then n_fok(side) <= n_fok(side) + 1; end if;
				if not is_x(urx(side)) and urx(side) /= prev and urx(side) /= x"00" and fok /= '1' then
					latch_errs(side) <= latch_errs(side) + 1;
					say("FAIL detail: side " & integer'image(side) & " rx octet changed to " & hx(urx(side)) & " outside a good frame");
				end if;
				prev := urx(side);
			end if;
		end process;

		-- the software model (aes50ctld's job): idle 0xAA, then one nibble per peer toggle, on every good frame
		process (clk)
			variable last, tx, rx, d : byte;
			variable idx, nrx : natural := 0;
			variable acc : bytes_t(0 to 7);
			variable n : std_logic_vector(3 downto 0);
			variable fok, ok : boolean;
		begin
			if rising_edge(clk) then
				if side = 0 then fok := a_fok = '1'; else fok := b_fok = '1'; end if;
				rx := urx(side);
				if xchg = '0' then
					utx(side) <= set_v(side);
					last := x"00"; tx := x"AA"; idx := 0; nrx := 0;
				else
					utx(side) <= tx;
					if fok and rx /= last then
						d := last xor rx;
						if d(7) = '1' then
							-- the peer's nibble
							if nrx < 16 then
								if nrx mod 2 = 0 then acc(nrx / 2)(3 downto 0) := rx(3 downto 0);
								else acc(nrx / 2)(7 downto 4) := rx(3 downto 0); end if;
							end if;
							nrx := nrx + 1;
							if rx(4) = '0' then					-- last nibble of a message
								if nrx >= 2 then
									ok := nrx = 16;
									for j in 0 to 7 loop
										if ok and acc(j) /= MSG(8 * (1 - side) + j) then ok := false; end if;
									end loop;
									if ok then msgs(side) <= msgs(side) + 1;
									else
										bad_msgs(side) <= bad_msgs(side) + 1;
										say("FAIL detail: side " & integer'image(side) & " got a wrong message, " & integer'image(nrx) & " nibbles");
									end if;
								end if;
								nrx := 0;
							end if;
							-- my next nibble, bit 7 inverted
							if idx mod 2 = 0 then n := MSG(8 * side + idx / 2)(3 downto 0);
							else n := MSG(8 * side + idx / 2)(7 downto 4); end if;
							tx := (tx and x"E0") or x"10" or ("0000" & n);
							if idx = 15 then tx(4) := '0'; end if;
							tx(7) := not tx(7);
							idx := (idx + 1) mod 16;
							utx(side) <= tx;
						end if;
						last := rx;
					end if;
				end if;
			end if;
		end process;
	end generate;

	-- B's bad frames; A's exchange octets on the wire against WIRE_A (after the idle octet 0xAA)
	process (clk)
		variable lastw : byte := x"00";
		variable cnt, k : natural := 0;
	begin
		if rising_edge(clk) then
			if b_ferr = '1' then n_ferr_b <= n_ferr_b + 1; end if;
			if xchg = '0' then
				lastw := x"00"; k := 0;
			elsif n_w(0) /= cnt and w15(0) /= lastw then
				lastw := w15(0);
				if lastw /= x"AA" or k /= 0 then
					if lastw /= WIRE_A(k mod 16) then
						wire_bad <= wire_bad + 1;
						say("FAIL detail: A's octet " & integer'image(k) & " is " & hx(lastw) & ", want " & hx(WIRE_A(k mod 16)));
					end if;
					k := k + 1;
					wire_idx <= wire_idx + 1;
				end if;
			end if;
			cnt := n_w(0);
		end if;
	end process;

	process
		variable errors : natural := 0;
		variable t0 : time;
		variable b0, b1, e0 : natural;
		procedure check(c : boolean; what : string) is
		begin
			if not c then errors := errors + 1; say("FAIL detail: " & what); end if;
		end procedure;
		-- wait until both sides received k more good frames (and both wires carried k more frames)
		procedure frames(k : natural) is
		begin
			b0 := n_fok(0); b1 := n_fok(1); t0 := now;
			while (n_fok(0) < b0 + k or n_fok(1) < b1 + k) and now - t0 < 30 ms loop
				wait until rising_edge(clk);
			end loop;
			check(n_fok(0) >= b0 + k and n_fok(1) >= b1 + k, "no good frames (" & integer'image(n_fok(0) - b0) & " / " & integer'image(n_fok(1) - b1) & ")");
		end procedure;
		procedure clear_wire is
		begin
			w_clear <= '1'; wait until rising_edge(clk); w_clear <= '0'; wait until rising_edge(clk);
		end procedure;
		procedure run(rate : string) is
		begin
			-- 1. reset: rx 0x00 at once; tx 0x00 in every frame
			xchg <= '0'; set_v <= (x"00", x"00"); want <= (x"00", x"00");
			rst <= '1'; wait for 10 us;
			check(urx(0) = x"00" and urx(1) = x"00", rate & ": rx octet not 0x00 in reset");
			clear_wire; rst <= '0';
			frames(20);
			check(w_other(0) = 0 and w_other(1) = 0, rate & ": a frame after reset carried a non-zero octet 15");
			check(urx(0) = x"00" and urx(1) = x"00", rate & ": rx octet not 0x00 after reset");
			-- 2. hold: one write, sent in every later frame
			set_v <= (x"5A", x"A5"); want <= (x"5A", x"A5");
			frames(3); clear_wire; frames(30);
			check(w_other(0) = 0 and w_other(1) = 0, rate & ": the tx octet was not held (" & integer'image(w_other(0)) & " / " & integer'image(w_other(1)) & " frames)");
			check(urx(1) = x"5A" and urx(0) = x"A5", rate & ": rx octets " & hx(urx(1)) & " / " & hx(urx(0)) & ", want 5A / A5");
			-- 4. bad FCS: 0xC3 only in bad frames, then in good ones
			corrupt <= '1'; set_v(0) <= x"C3"; want(0) <= x"C3";
			e0 := n_ferr_b; t0 := now;
			while n_ferr_b < e0 + 6 and now - t0 < 5 ms loop wait until rising_edge(clk); end loop;
			check(n_ferr_b >= e0 + 6, rate & ": no bad frames at B");
			check(w15(0) = x"C3", rate & ": A did not send C3 in the bad frames");
			check(urx(1) = x"5A", rate & ": B took the octet " & hx(urx(1)) & " from a bad frame");
			corrupt <= '0';
			frames(3);
			check(urx(1) = x"C3", rate & ": B did not take C3 from a good frame (" & hx(urx(1)) & ")");
			-- 5. lock-step exchange from idle
			set_v <= (x"00", x"00"); frames(3);
			check(urx(0) = x"00" and urx(1) = x"00", rate & ": rx octets not back to 0x00");
			b0 := msgs(0); b1 := msgs(1); e0 := wire_idx; xchg <= '1'; t0 := now;
			while (msgs(0) < b0 + 3 or msgs(1) < b1 + 3 or wire_idx < e0 + 48) and now - t0 < 80 ms loop
				wait until rising_edge(clk);
			end loop;
			check(msgs(0) >= b0 + 3 and msgs(1) >= b1 + 3, rate & ": messages received A " & integer'image(msgs(0) - b0) & " B " & integer'image(msgs(1) - b1));
			check(wire_idx >= e0 + 48, rate & ": only " & integer'image(wire_idx - e0) & " exchange octets from A");
			say("tb_user_octet48: " & rate & ": exchange: A got " & integer'image(msgs(0) - b0) & ", B got " &
				integer'image(msgs(1) - b1) & " messages, " & integer'image(wire_idx - e0) & " octets from A checked in " &
				integer'image((now - t0) / 1 us) & " us");
			xchg <= '0';
		end procedure;
	begin
		wait for 100 ns;
		run("48k");
		fs96 <= '1';
		run("96k");
		check(bad_msgs(0) = 0 and bad_msgs(1) = 0, "wrong messages A " & integer'image(bad_msgs(0)) & " B " & integer'image(bad_msgs(1)));
		check(wire_bad = 0, integer'image(wire_bad) & " exchange octets from A differ");
		check(latch_errs(0) = 0 and latch_errs(1) = 0, "rx octet changed outside a good frame");
		if errors = 0 then
			say("PASS tb_user_octet48: header octet 15 both ways at 48k and 96k: tx 0x00 after reset, held across frames, rx latched from good-FCS frames only (bad-FCS frames ignored), lock-step nibble exchange bit-exact both ways");
		else
			say("FAIL tb_user_octet48: " & integer'image(errors) & " errors");
		end if;
		std.env.stop;
		wait;
	end process;
end architecture;
