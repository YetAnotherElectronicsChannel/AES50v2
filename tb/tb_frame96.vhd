-- tb_frame96.vhd (OpenProSeries): the 96 kHz frame format. aes50_tx_framer -> aes50_rx_deframer over RMII, three
-- runs: 96k -> 96k (octet 18 = 0x56, octet 21 = the CRC-8 0xFB / 0x4B with / without ASSM, 6 x 48 words bit-exact),
-- 48k -> 48k (unchanged: 0x46, 0xAA / 0x1A, bit-exact), 96k -> a 48k receiver (rejected: no block reported).
-- License: GPL-3.0-or-later
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.aes50_pkg.all;

entity tb_frame96 is
end entity;

architecture sim of tb_frame96 is
	signal clk			: std_logic := '0';
	signal rst			: std_logic := '1';
	signal tx96, rx96	: std_logic := '0';
	signal start, assm	: std_logic := '0';
	signal base			: unsigned(8 downto 0) := (others => '0');
	signal busy			: std_logic;
	signal raddr		: unsigned(8 downto 0);
	signal rdata		: std_logic_vector(23 downto 0);
	signal auxa			: unsigned(6 downto 0);
	signal txd			: std_logic_vector(1 downto 0);
	signal txen			: std_logic;
	signal rwe			: std_logic;
	signal rwaddr		: unsigned(8 downto 0);
	signal rwdata		: std_logic_vector(23 downto 0);
	signal bdone		: std_logic;
	signal bbase		: unsigned(8 downto 0);
	type ram_t is array (0 to 511) of std_logic_vector(23 downto 0);
	signal rxram		: ram_t := (others => (others => 'U'));
	type hdr_t is array (0 to 21) of std_logic_vector(7 downto 0);
	signal hdr			: hdr_t;
	signal hdr_cnt		: natural := 0;
	signal ndone		: natural := 0;
	signal last_base	: unsigned(8 downto 0);

	function pat(a : natural) return std_logic_vector is
	begin
		return std_logic_vector(to_unsigned((a * 40503 + 12345) mod 2 ** 24, 24));
	end function;
	procedure say(s : string) is
		variable l : line;
	begin
		write(l, s); writeline(output, l);
	end procedure;
begin
	clk <= not clk after 10 ns;

	-- TX sample RAM: pattern, registered read
	process (clk) begin
		if rising_edge(clk) then rdata <= pat(to_integer(raddr)); end if;
	end process;

	u_tx : entity work.aes50_tx_framer
		generic map (G_AW => 9)
		port map (clk_i => clk, rst_i => rst, fs48_i => '1', fs96_i => tx96, i2s_i => '0', start_i => start,
				  base_i => base, assm_i => assm, aux_valid_i => '0', busy_o => busy, frame_o => open,
				  ram_addr_o => raddr, ram_data_i => rdata, aux_addr_o => auxa, aux_data_i => x"0000",
				  rmii_txd_o => txd, rmii_tx_en_o => txen);
	u_rx : entity work.aes50_rx_deframer
		generic map (G_AW => 9)
		port map (clk_i => clk, rst_i => rst, fs48_i => '1', fs96_i => rx96, rmii_crs_dv_i => txen, rmii_rxd_i => txd,
				  ram_we_o => rwe, ram_addr_o => rwaddr, ram_data_o => rwdata, aux_we_o => open, aux_addr_o => open,
				  aux_data_o => open, blk_done_o => bdone, blk_base_o => bbase, blk_page_o => open, blk_ok_o => open,
				  blk_assm_o => open, frame_ok_o => open, frame_err_o => open, sync_o => open);

	process (clk)
		variable sh : std_logic_vector(7 downto 0);
		variable n  : natural;
	begin
		if rising_edge(clk) then
			if rwe = '1' then rxram(to_integer(rwaddr)) <= rwdata; end if;
			if bdone = '1' then ndone <= ndone + 1; last_base <= bbase; end if;
			-- header octets from the wire (dibit 0 after the 32 preamble / SFD dibits)
			if txen = '0' then
				hdr_cnt <= 0;
			else
				hdr_cnt <= hdr_cnt + 1;
				if hdr_cnt >= 32 and hdr_cnt < 32 + 88 then
					n := (hdr_cnt - 32) / 4;
					sh := hdr(n);
					sh := txd & sh(7 downto 2);
					hdr(n) <= sh;
				end if;
			end if;
		end if;
	end process;

	process
		variable errors : natural := 0;
		variable want18 : std_logic_vector(7 downto 0);
		variable c21    : std_logic_vector(7 downto 0);
		procedure send(b : natural; a : std_logic) is
		begin
			wait until rising_edge(clk);
			base <= to_unsigned(b, 9); assm <= a; start <= '1';
			wait until rising_edge(clk);
			start <= '0';
			wait until rising_edge(clk);
			wait until busy = '0';
		end procedure;
		procedure run(t96, r96 : std_logic; name : string) is
			variable n0 : natural;
		begin
			rst <= '1'; tx96 <= t96; rx96 <= r96;
			for i in 1 to 5 loop wait until rising_edge(clk); end loop;
			rst <= '0';
			n0 := ndone;
			if t96 = '1' then want18 := x"56"; else want18 := x"46"; end if;
			send(0, '1');
			if hdr(18) /= want18 or hdr(21) /= fmt_crc(want18, '1') or hdr(17) /= x"11" then
				errors := errors + 1; say("FAIL detail " & name & ": ASSM frame header octets 17/18/21 wrong");
			end if;
			send(288, '0');
			if hdr(18) /= want18 or hdr(21) /= fmt_crc(want18, '0') or hdr(17) /= x"01" then
				errors := errors + 1; say("FAIL detail " & name & ": frame header octets 17/18/21 wrong");
			end if;
			for i in 1 to 50 loop wait until rising_edge(clk); end loop;
			if t96 = r96 then
				if ndone /= n0 + 2 then
					errors := errors + 1; say("FAIL detail " & name & ": blocks reported " & integer'image(ndone - n0));
				else
					for s in 0 to 5 loop
						for ch in 0 to 47 loop
							if rxram(to_integer(last_base + to_unsigned(48 * s + ch, 9))) /= pat((288 + 48 * s + ch) mod 512) then
								errors := errors + 1;
							end if;
						end loop;
					end loop;
				end if;
			elsif ndone /= n0 then
				errors := errors + 1; say("FAIL detail " & name & ": a mismatched rate was accepted");
			end if;
		end procedure;
	begin
		run('1', '1', "96k->96k");
		run('0', '0', "48k->48k");
		run('1', '0', "96k->48k receiver");
		assert fmt_crc(FMT_48K, '1') = x"AA" and fmt_crc(FMT_44K1, '0') = x"CC" severity error;
		if errors = 0 then
			say("PASS tb_frame96: 96k frames carry 0x56 / CRC-8 0xFB, 0x4B and arrive bit-exact (6 x 48 words); 48k unchanged; a 48k receiver rejects 96k frames");
		else
			say("FAIL tb_frame96: " & integer'image(errors) & " errors");
		end if;
		std.env.stop;
		wait;
	end process;
end architecture;
