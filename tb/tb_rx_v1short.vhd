-- tb_rx_v1short.vhd (OpenProSeries): the deframer must accept the AES50 v1 IP's frames, which end one 32-bit word
-- early (row 10's global parity block missing, 1430 bytes after the SFD), as well as full frames.
-- The framer's real frames are captured and replayed into the deframer as: full; short (row 10 block 31 removed, the
-- FCS recomputed over the first 1426 bytes); full / short with CRS_DV toggling over the last 4 bytes (the PHY's
-- behaviour at a frame end, seen on the PRO1 with a DL8); full / short with one payload bit flipped. Every good frame's
-- block must be reported ok and bit-exact (all samples, all aux words); a corrupted one must not; frame_short_o must
-- count the good short frames. A short checksum followed by extra bytes must be rejected.
-- License: GPL-3.0-or-later
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_rx_v1short is
end entity;

architecture sim of tb_rx_v1short is
	-- what each block is sent as
	type kind_t is (FULL, SHORT, FULL_TOGGLE, SHORT_TOGGLE, FULL_BAD, SHORT_BAD, SHORT_EXTRA, SHORT_EXTRA_TOGGLE);
	type plan_t is array (natural range <>) of kind_t;
	constant PLAN : plan_t := (FULL, SHORT, SHORT, SHORT, FULL, FULL_TOGGLE, SHORT_TOGGLE, SHORT_BAD, FULL_BAD,
							   SHORT, SHORT_TOGGLE, FULL, SHORT, FULL_TOGGLE, SHORT, SHORT_EXTRA, SHORT_EXTRA_TOGGLE, SHORT);
	signal clk			: std_logic := '0';
	signal rst			: std_logic := '1';
	signal start, assm	: std_logic := '0';
	signal busy			: std_logic;
	signal raddr		: unsigned(8 downto 0);
	signal rdata		: std_logic_vector(23 downto 0);
	signal aaddr		: unsigned(6 downto 0);
	signal adata		: std_logic_vector(15 downto 0);
	signal txd			: std_logic_vector(1 downto 0);
	signal txen			: std_logic;
	signal blk			: natural := 0;
	-- capture of the framer's frame (dibits, preamble included)
	type dib_t is array (0 to 8191) of std_logic_vector(1 downto 0);
	signal cap			: dib_t;
	signal ncap			: natural := 0;
	signal capturing	: boolean := false;
	-- replay into the deframer
	signal dv			: std_logic := '0';
	signal rd			: std_logic_vector(1 downto 0) := "00";
	signal rwe, awe		: std_logic;
	signal rwaddr		: unsigned(8 downto 0);
	signal rwdata		: std_logic_vector(23 downto 0);
	signal awaddr		: unsigned(7 downto 0);
	signal awdata		: std_logic_vector(15 downto 0);
	signal bdone, bok, bpage : std_logic;
	signal bbase		: unsigned(8 downto 0);
	signal fshort		: std_logic;
	signal nshort		: natural := 0;
	type ram_t is array (0 to 511) of std_logic_vector(23 downto 0);
	signal rxram		: ram_t := (others => (others => '0'));
	type aram_t is array (0 to 255) of std_logic_vector(15 downto 0);
	signal auxram		: aram_t := (others => (others => '0'));
	-- block reports, written by the monitor process only
	signal ndone		: natural := 0;
	signal got_ok, got_page : std_logic := '0';
	signal got_base		: unsigned(8 downto 0);

	procedure say(s : string) is
		variable l : line;
	begin
		write(l, s); writeline(output, l);
	end procedure;
	function pat(b, a : natural) return std_logic_vector is
	begin
		return std_logic_vector(to_unsigned(b mod 128, 7)) & std_logic_vector(to_unsigned(a / 48, 5)) &
			   std_logic_vector(to_unsigned(a mod 48, 6)) & "000001";
	end function;
	function apat(b, j : natural) return std_logic_vector is
	begin
		return std_logic_vector(to_unsigned(b mod 128, 7)) & '1' & std_logic_vector(to_unsigned(j, 8));
	end function;
begin
	clk <= not clk after 10 ns;
	process (clk) begin
		if rising_edge(clk) then rdata <= pat(blk, to_integer(raddr)); adata <= apat(blk, to_integer(aaddr)); end if;
	end process;
	u_tx : entity work.aes50_tx_framer
		generic map (G_AW => 9)
		port map (clk_i => clk, rst_i => rst, fs48_i => '1', i2s_i => '0', start_i => start, base_i => (others => '0'),
				  assm_i => assm, aux_valid_i => '1', busy_o => busy, frame_o => open, ram_addr_o => raddr,
				  ram_data_i => rdata, aux_addr_o => aaddr, aux_data_i => adata, rmii_txd_o => txd, rmii_tx_en_o => txen);
	process (clk) begin
		if rising_edge(clk) then
			if txen = '1' then
				if not capturing then capturing <= true; cap(0) <= txd; ncap <= 1;
				else cap(ncap) <= txd; ncap <= ncap + 1; end if;
			else
				capturing <= false;
			end if;
		end if;
	end process;

	u_rx : entity work.aes50_rx_deframer
		generic map (G_AW => 9)
		port map (clk_i => clk, rst_i => rst, fs48_i => '1', rmii_crs_dv_i => dv, rmii_rxd_i => rd,
				  ram_we_o => rwe, ram_addr_o => rwaddr, ram_data_o => rwdata, aux_we_o => awe, aux_addr_o => awaddr,
				  aux_data_o => awdata, blk_done_o => bdone, blk_base_o => bbase, blk_page_o => bpage, blk_ok_o => bok,
				  blk_assm_o => open, frame_ok_o => open, frame_err_o => open, frame_short_o => fshort, sync_o => open);
	process (clk) begin
		if rising_edge(clk) then
			if rwe = '1' then rxram(to_integer(rwaddr)) <= rwdata; end if;
			if awe = '1' then auxram(to_integer(awaddr)) <= awdata; end if;
			if fshort = '1' then nshort <= nshort + 1; end if;
			if bdone = '1' then ndone <= ndone + 1; got_ok <= bok; got_page <= bpage; got_base <= bbase; end if;
		end if;
	end process;

	process
		type bytes_t is array (0 to 1433) of std_logic_vector(7 downto 0);
		variable by		: bytes_t;
		variable nby	: natural;
		variable crc	: std_logic_vector(31 downto 0);
		variable errors	: natural := 0;
		variable nok, nbad, want_short : natural := 0;
		variable k		: kind_t;
		variable is_short, toggle, bad : boolean;
		variable d, dd	: natural;
		variable b8		: std_logic_vector(7 downto 0);
		variable x		: std_logic_vector(23 downto 0);
		variable n0		: natural;
		variable got	: boolean;
		function crc32(c : std_logic_vector(31 downto 0); b : std_logic_vector(7 downto 0)) return std_logic_vector is
			variable r : std_logic_vector(31 downto 0) := c xor (x"000000" & b);
		begin
			for i in 0 to 7 loop
				if r(0) = '1' then r := ('0' & r(31 downto 1)) xor x"EDB88320"; else r := '0' & r(31 downto 1); end if;
			end loop;
			return r;
		end function;
	begin
		wait for 50 ns; rst <= '0';
		for b in PLAN'range loop
			k := PLAN(b);
			is_short := k = SHORT or k = SHORT_TOGGLE or k = SHORT_BAD or k = SHORT_EXTRA or k = SHORT_EXTRA_TOGGLE;
			toggle := k = FULL_TOGGLE or k = SHORT_TOGGLE or k = SHORT_EXTRA_TOGGLE;
			bad := k = FULL_BAD or k = SHORT_BAD or k = SHORT_EXTRA or k = SHORT_EXTRA_TOGGLE;
			-- frame the block
			wait until rising_edge(clk);
			blk <= b; if b = 0 then assm <= '1'; else assm <= '0'; end if;
			start <= '1'; wait until rising_edge(clk); start <= '0';
			wait until rising_edge(clk); wait until busy = '0'; wait until rising_edge(clk); wait until rising_edge(clk);
			assert ncap = 32 + 4 * 1434 report "framer frame length" severity failure;
			-- bytes after the SFD (dibit 32 on), LSB dibit first
			for i in 0 to 1433 loop
				by(i) := cap(32 + 4 * i + 3) & cap(32 + 4 * i + 2) & cap(32 + 4 * i + 1) & cap(32 + 4 * i);
			end loop;
			nby := 1434;
			if is_short then
				-- drop row 10 block 31 (bytes 1426..1429) and recompute the FCS over the first 1426 bytes
				crc := x"FFFFFFFF";
				for i in 0 to 1425 loop crc := crc32(crc, by(i)); end loop;
				crc := not crc;
				by(1426) := crc(7 downto 0); by(1427) := crc(15 downto 8); by(1428) := crc(23 downto 16); by(1429) := crc(31 downto 24);
				nby := 1430;
			end if;
			if k = SHORT_EXTRA or k = SHORT_EXTRA_TOGGLE then
				nby := 1434;
				for i in 1430 to 1433 loop by(i) := x"00"; end loop;
			end if;
			if k = FULL_BAD or k = SHORT_BAD then by(600) := by(600) xor x"10"; end if;	-- one bit in the payload
			-- replay: preamble + SFD, then the bytes; CRS_DV toggles (low on even dibits) over the last 4 bytes
			n0 := ndone;
			for i in 0 to 31 loop
				wait until rising_edge(clk); dv <= '1'; rd <= cap(i);
			end loop;
			for i in 0 to nby - 1 loop
				b8 := by(i);
				for j in 0 to 3 loop
					wait until rising_edge(clk);
					d := 4 * i + j;
					rd <= b8(2 * j + 1 downto 2 * j);
					if toggle and i >= nby - 4 and (d mod 2) = 0 then dv <= '0'; else dv <= '1'; end if;
				end loop;
			end loop;
			wait until rising_edge(clk); dv <= '0'; rd <= "00";
			for i in 1 to 80 loop wait until rising_edge(clk); end loop;		-- inter-frame gap (> 12 bytes)
			-- the verdict
			got := ndone > n0;
			if bad then
				if got and got_ok = '1' then errors := errors + 1; say("FAIL detail: block " & integer'image(b) & " (" & kind_t'image(k) & ") corrupted but reported ok"); end if;
				nbad := nbad + 1;
			else
				if is_short then want_short := want_short + 1; end if;
				if not got or got_ok /= '1' then
					errors := errors + 1; say("FAIL detail: block " & integer'image(b) & " (" & kind_t'image(k) & ") not reported ok");
				else
					nok := nok + 1;
					for s in 0 to 5 loop
						for ch in 0 to 47 loop
							x := rxram(to_integer(got_base + to_unsigned(48 * s + ch, 9)));
							if x /= pat(b, 48 * s + ch) then
								errors := errors + 1;
								if errors < 6 then say("FAIL detail: block " & integer'image(b) & " s " & integer'image(s) & " ch " & integer'image(ch)); end if;
							end if;
						end loop;
					end loop;
					for j in 0 to 43 loop
						if auxram(to_integer(unsigned'(got_page & to_unsigned(j, 7)))) /= apat(b, j) then
							errors := errors + 1;
							if errors < 6 then say("FAIL detail: block " & integer'image(b) & " aux word " & integer'image(j)); end if;
						end if;
					end loop;
				end if;
			end if;
		end loop;
		if nshort /= want_short then errors := errors + 1; say("FAIL detail: frame_short_o " & integer'image(nshort) & ", want " & integer'image(want_short)); end if;
		say("tb_rx_v1short: " & integer'image(nok) & " good frames bit-exact (" & integer'image(want_short) & " short), " & integer'image(nbad) & " corrupted rejected");
		if errors = 0 then
			say("PASS tb_rx_v1short: full and v1-style short frames (1430 bytes) both accepted bit-exact, also with CRS_DV toggling at the frame end; corrupted full and short frames rejected; short frames counted");
		else
			say("FAIL tb_rx_v1short: " & integer'image(errors) & " errors");
		end if;
		std.env.stop;
		wait;
	end process;
end architecture;
