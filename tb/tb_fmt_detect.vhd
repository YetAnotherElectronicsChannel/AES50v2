-- tb_fmt_detect.vhd (OpenProSeries): the deframer's format report. A deframer set to 48k is fed by a framer at 96k,
-- then at 48k, with and without ASSM: each header reports fmt_valid_o with octet 18 (0x56 / 0x46) whatever rate the
-- deframer accepts. One frame with a flipped bit in octet 21 (the format CRC-8) and one with a flipped bit in
-- octet 18 must report fmt_bad_o instead.
-- License: GPL-3.0-or-later
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.aes50_pkg.all;

entity tb_fmt_detect is
end entity;

architecture sim of tb_fmt_detect is
	signal clk			: std_logic := '0';
	signal rst			: std_logic := '1';
	signal tx96			: std_logic := '0';
	signal start, assm	: std_logic := '0';
	signal busy			: std_logic;
	signal raddr		: unsigned(8 downto 0);
	signal rdata		: std_logic_vector(23 downto 0) := (others => '0');
	signal txd, txd_w	: std_logic_vector(1 downto 0);
	signal txen			: std_logic;
	signal fv, fb		: std_logic;
	signal fmt			: std_logic_vector(7 downto 0);
	signal flip_at		: integer := -1000;		-- dibit (after the SFD) whose bit 0 is flipped on the wire
	signal dib			: integer := 0;
	signal nv, nb		: natural := 0;
	signal last_fmt		: std_logic_vector(7 downto 0);

	procedure say(s : string) is
		variable l : line;
	begin
		write(l, s); writeline(output, l);
	end procedure;
begin
	clk <= not clk after 10 ns;
	process (clk) begin
		if rising_edge(clk) then rdata <= std_logic_vector(resize(raddr, 24)); end if;
	end process;

	u_tx : entity work.aes50_tx_framer
		generic map (G_AW => 9)
		port map (clk_i => clk, rst_i => rst, fs48_i => '1', fs96_i => tx96, i2s_i => '0', start_i => start,
				  base_i => (others => '0'), assm_i => assm, aux_valid_i => '0', busy_o => busy, frame_o => open,
				  ram_addr_o => raddr, ram_data_i => rdata, aux_addr_o => open, aux_data_i => x"0000",
				  rmii_txd_o => txd, rmii_tx_en_o => txen);
	txd_w <= txd xor "01" when dib - 32 = flip_at else txd;
	u_rx : entity work.aes50_rx_deframer
		generic map (G_AW => 9)
		port map (clk_i => clk, rst_i => rst, fs48_i => '1', rmii_crs_dv_i => txen, rmii_rxd_i => txd_w,
				  ram_we_o => open, ram_addr_o => open, ram_data_o => open, aux_we_o => open, aux_addr_o => open,
				  aux_data_o => open, blk_done_o => open, blk_base_o => open, blk_page_o => open, blk_ok_o => open,
				  blk_assm_o => open, frame_ok_o => open, frame_err_o => open, fmt_valid_o => fv, fmt_bad_o => fb,
				  fmt_o => fmt, sync_o => open);

	process (clk) begin
		if rising_edge(clk) then
			if txen = '1' then dib <= dib + 1; else dib <= 0; end if;
			if fv = '1' then nv <= nv + 1; last_fmt <= fmt; end if;
			if fb = '1' then nb <= nb + 1; end if;
		end if;
	end process;

	process
		variable errors : natural := 0;
		procedure send(t96, a : std_logic; flip : integer; want_ok : boolean; want : std_logic_vector(7 downto 0)) is
			variable v0, b0 : natural;
		begin
			v0 := nv; b0 := nb;
			wait until rising_edge(clk);
			tx96 <= t96; assm <= a; flip_at <= flip; start <= '1';
			wait until rising_edge(clk);
			start <= '0';
			wait until rising_edge(clk);
			wait until busy = '0';
			for i in 1 to 20 loop wait until rising_edge(clk); end loop;
			if want_ok then
				if nv /= v0 + 1 or nb /= b0 or last_fmt /= want then
					errors := errors + 1; say("FAIL detail: a good header was not reported as format " & integer'image(to_integer(unsigned(want))));
				end if;
			elsif nb /= b0 + 1 or nv /= v0 then
				errors := errors + 1; say("FAIL detail: a corrupted header was not reported bad (flip at dibit " & integer'image(flip) & ")");
			end if;
		end procedure;
	begin
		for i in 1 to 5 loop wait until rising_edge(clk); end loop;
		rst <= '0';
		send('1', '1', -1000, true, FMT_96K);
		send('1', '0', -1000, true, FMT_96K);
		send('0', '1', -1000, true, FMT_48K);
		send('0', '0', -1000, true, FMT_48K);
		send('1', '0', 4 * 21, false, x"00");		-- octet 21, first dibit
		send('0', '0', 4 * 18 + 2, false, x"00");	-- octet 18, third dibit
		send('0', '0', -1000, true, FMT_48K);		-- and back to normal
		if errors = 0 then
			say("PASS tb_fmt_detect: 96k and 48k headers reported (0x56 / 0x46, with and without ASSM) by a 48k deframer; a flipped CRC-8 or format bit reports fmt_bad");
		else
			say("FAIL tb_fmt_detect: " & integer'image(errors) & " errors");
		end if;
		std.env.stop;
		wait;
	end process;
end architecture;
