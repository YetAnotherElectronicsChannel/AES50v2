-- tb_par_loop.vhd (OpenProSeries): aes50_par_core end to end. Core A (AES50 master) and core B (AES50 slave) over a
-- modelled cable (RMII crossed, sync pairs crossed, half-duplex: a pair carries whichever side drives it).
-- Each side writes a counting pattern into its parallel input at every sample tick (sample = side marker, period
-- number, channel); the other side's parallel output must show complete periods in order, every word bit-exact,
-- channel numbers right, consecutive periods. Aux: each side fills every requested page with a 16-bit counter; the
-- other side must receive consecutive words. Runs: 48 kHz, cable cut 3 ms, far-end reset, then 96 kHz (24
-- channels, both cores restarted at the new rate). After every event both directions must come back and play
-- 120 consecutive periods bit-exact (aux: 10 blocks). The ASSM period is shortened to 64 samples for both cores
-- (G_ASSM_FRAMES) and the clock-ok time to 0.1 ms to keep the bench short (GHDL mcode).
-- License: GPL-3.0-or-later
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_par_loop is
end entity;

architecture sim of tb_par_loop is
	constant ASSM_FR	: natural := 64;
	signal clk			: std_logic := '0';
	signal clka			: std_logic := '0';
	signal rst_a, rst_b	: std_logic := '1';
	signal fs96			: std_logic := '0';
	signal cut			: std_logic := '0';
	signal clear		: std_logic := '0';		-- the checkers start counting again (after each event)

	type side_t is record
		txen			: std_logic;
		txd				: std_logic_vector(1 downto 0);
		a_tx, a_en		: std_logic;
		b_tx, b_en		: std_logic;
		tick			: std_logic;
		ov				: std_logic;
		och				: std_logic_vector(5 downto 0);
		oph				: std_logic;
		os				: std_logic_vector(23 downto 0);
		areq			: std_logic;
		acnt			: unsigned(5 downto 0);
		arf				: std_logic;
		ard				: std_logic_vector(15 downto 0);
		ok, rxok, txst	: std_logic;
	end record;
	signal A, B			: side_t;
	signal l1, l2		: std_logic;
	signal a_crs, b_crs	: std_logic;
	signal a_rxd, b_rxd	: std_logic_vector(1 downto 0);
	-- producer outputs, one element per side (a process drives every signal it assigns anywhere)
	type s6_t is array (0 to 1) of std_logic_vector(5 downto 0);
	type s24_t is array (0 to 1) of std_logic_vector(23 downto 0);
	type s16_t is array (0 to 1) of std_logic_vector(15 downto 0);
	signal pwe, pawe	: std_logic_vector(0 to 1) := "00";
	-- aux readers (like the aux decoder: pull a word, take it two clocks later), one element per side
	signal prd, rv, rf	: std_logic_vector(0 to 1) := "00";
	signal rdw			: s16_t := (others => (others => '0'));
	signal pch			: s6_t := (others => (others => '0'));
	signal ps			: s24_t := (others => (others => '0'));
	signal pad			: s16_t := (others => (others => '0'));
	-- consecutive good periods / aux blocks seen by A (from B) and by B (from A)
	type nat2_t is array (0 to 1) of natural;
	signal runs, aruns		: nat2_t := (0, 0);
	alias run_a	: natural is runs(0);
	alias run_b	: natural is runs(1);
	alias arun_a : natural is aruns(0);
	alias arun_b : natural is aruns(1);

	procedure say(s : string) is
		variable l : line;
	begin
		write(l, s); writeline(output, l);
	end procedure;
begin
	clk  <= not clk after 10 ns;			-- 50 MHz
	clka <= not clka after 10.1725 ns;		-- 49.152 MHz

	-- cable
	l1 <= '0' when cut = '1' else A.a_tx when A.a_en = '1' else B.b_tx when B.b_en = '1' else '0';
	l2 <= '0' when cut = '1' else A.b_tx when A.b_en = '1' else B.a_tx when B.a_en = '1' else '0';
	b_crs <= A.txen and not cut;  b_rxd <= A.txd when cut = '0' else "00";
	a_crs <= B.txen and not cut;  a_rxd <= B.txd when cut = '0' else "00";

	u_a : entity work.aes50_par_core
		generic map (G_ASSM_INIT => (ASSM_FR - 20) * 64, G_ASSM_FRAMES => ASSM_FR, G_CLK_OK_REF => 5000)
		port map (clk50_i => clk, rst_i => rst_a, fs96_i => fs96, sys_mode_i => "01",
				  rmii_crs_dv_i => a_crs, rmii_rxd_i => a_rxd, rmii_tx_en_o => A.txen, rmii_txd_o => A.txd, phy_rst_n_o => open,
				  aes50_clk_a_rx_i => l1, aes50_clk_a_tx_o => A.a_tx, aes50_clk_a_tx_en_o => A.a_en,
				  aes50_clk_b_rx_i => l2, aes50_clk_b_tx_o => A.b_tx, aes50_clk_b_tx_en_o => A.b_en,
				  clk_1024xfs_from_pll_i => clka, pll_lock_n_i => '0', clk_to_pll_o => open,
				  sample_tick_o => A.tick, par_in_we_i => pwe(0), par_in_ch_i => pch(0), par_in_sample_i => ps(0),
				  par_out_valid_o => A.ov, par_out_ch_o => A.och, par_out_phase_o => A.oph, par_out_sample_o => A.os,
				  aux_tx_req_o => A.areq, aux_tx_we_i => pawe(0), aux_tx_data_i => pad(0),
				  aux_rx_count_o => A.acnt, aux_rx_rd_i => prd(0), aux_rx_first_o => A.arf, aux_rx_data_o => A.ard,
				  aes_ok_o => A.ok, rx_ok_o => A.rxok, tx_started_o => A.txst, tx_frame_o => open, rx_frame_ok_o => open,
				  rx_frame_err_o => open, rx_block_o => open, rx_block_drop_o => open, rx_assm_o => open,
				  fmt_valid_o => open, fmt_bad_o => open, fmt_o => open);
	u_b : entity work.aes50_par_core
		generic map (G_ASSM_FRAMES => ASSM_FR, G_CLK_OK_REF => 5000)
		port map (clk50_i => clk, rst_i => rst_b, fs96_i => fs96, sys_mode_i => "00",
				  rmii_crs_dv_i => b_crs, rmii_rxd_i => b_rxd, rmii_tx_en_o => B.txen, rmii_txd_o => B.txd, phy_rst_n_o => open,
				  aes50_clk_a_rx_i => l2, aes50_clk_a_tx_o => B.a_tx, aes50_clk_a_tx_en_o => B.a_en,
				  aes50_clk_b_rx_i => l1, aes50_clk_b_tx_o => B.b_tx, aes50_clk_b_tx_en_o => B.b_en,
				  clk_1024xfs_from_pll_i => clka, pll_lock_n_i => '0', clk_to_pll_o => open,
				  sample_tick_o => B.tick, par_in_we_i => pwe(1), par_in_ch_i => pch(1), par_in_sample_i => ps(1),
				  par_out_valid_o => B.ov, par_out_ch_o => B.och, par_out_phase_o => B.oph, par_out_sample_o => B.os,
				  aux_tx_req_o => B.areq, aux_tx_we_i => pawe(1), aux_tx_data_i => pad(1),
				  aux_rx_count_o => B.acnt, aux_rx_rd_i => prd(1), aux_rx_first_o => B.arf, aux_rx_data_o => B.ard,
				  aes_ok_o => B.ok, rx_ok_o => B.rxok, tx_started_o => B.txst, tx_frame_o => open, rx_frame_ok_o => open,
				  rx_frame_err_o => open, rx_block_o => open, rx_block_drop_o => open, rx_assm_o => open,
				  fmt_valid_o => open, fmt_bad_o => open, fmt_o => open);

	-- producers: one period per tick (marker bit 23: '0' from A, '1' from B), 44 aux words per request
	gen_prod : for side in 0 to 1 generate
		process (clk)
			variable k		: natural := 0;
			variable ch		: natural := 0;
			variable busy	: boolean := false;
			variable n		: natural;
			variable ac		: natural := 0;
			variable aleft	: natural := 0;
			variable tick, req : std_logic;
			variable w		: std_logic_vector(23 downto 0);
		begin
			if rising_edge(clk) then
				if side = 0 then tick := A.tick; req := A.areq; else tick := B.tick; req := B.areq; end if;
				if fs96 = '1' then n := 24; else n := 48; end if;
				if tick = '1' then busy := true; ch := 0; k := (k + 1) mod 2 ** 17; end if;
				w := std_logic_vector(to_unsigned(side, 1)) & std_logic_vector(to_unsigned(k, 17)) & std_logic_vector(to_unsigned(ch, 6));
				pwe(side) <= '0';
				if busy then
					pwe(side) <= '1'; pch(side) <= std_logic_vector(to_unsigned(ch, 6)); ps(side) <= w;
					if ch = n - 1 then busy := false; else ch := ch + 1; end if;
				end if;
				if req = '1' then aleft := 44; end if;
				pawe(side) <= '0';
				if aleft > 0 then
					pawe(side) <= '1'; pad(side) <= std_logic_vector(to_unsigned(ac, 16));
					ac := (ac + 1) mod 2 ** 16; aleft := aleft - 1;
				end if;
			end if;
		end process;
	end generate;

	gen_rd : for side in 0 to 1 generate
		process (clk)
			variable ph : natural := 0;
			variable cnt : unsigned(5 downto 0);
		begin
			if rising_edge(clk) then
				if side = 0 then cnt := A.acnt; else cnt := B.acnt; end if;
				prd(side) <= '0'; rv(side) <= '0';
				case ph is
					when 0 => if cnt /= 0 then prd(side) <= '1'; ph := 1; end if;
					when 1 => ph := 2;
					when 2 =>
						rv(side) <= '1';
						if side = 0 then rf(side) <= A.arf; rdw(side) <= A.ard; else rf(side) <= B.arf; rdw(side) <= B.ard; end if;
						ph := 3;
					when others => ph := 0;
				end case;
			end if;
		end process;
	end generate;

	-- checkers: side 0 checks what A receives (from B, marker '1'), side 1 what B receives
	gen_chk : for side in 0 to 1 generate
		process (clk)
			variable v, arv, arf : std_logic;
			variable och	: std_logic_vector(5 downto 0);
			variable oph	: std_logic;
			variable os		: std_logic_vector(23 downto 0);
			variable ard	: std_logic_vector(15 downto 0);
			variable k, last_k, cnt, n, wch : natural := 0;
			variable okp	: boolean := true;
			variable run	: natural := 0;
			variable alast, arun : natural := 0;
			variable afirst	: boolean := true;
		begin
			if rising_edge(clk) then
				if side = 0 then v := A.ov; och := A.och; oph := A.oph; os := A.os;
				else v := B.ov; och := B.och; oph := B.oph; os := B.os; end if;
				arv := rv(side); arf := rf(side); ard := rdw(side);
				if fs96 = '1' then n := 24; else n := 48; end if;
				if v = '1' then
					wch := to_integer(unsigned(och));
					if wch = 0 then
						-- a new period: was the previous one complete, good and the successor of the one before?
						if cnt = n and okp and k = (last_k + 1) mod 2 ** 17 then run := run + 1; else run := 0; end if;
						last_k := k; cnt := 0; okp := true;
						k := to_integer(unsigned(os(22 downto 6)));
					end if;
					if os(23) /= std_logic(to_unsigned(1 - side, 1)(0)) or to_integer(unsigned(os(5 downto 0))) /= wch or
					   to_integer(unsigned(os(22 downto 6))) /= k or wch /= cnt then
						okp := false;
					end if;
					cnt := cnt + 1;
				end if;
				if arv = '1' then
					if arf = '1' then
						if not afirst and to_integer(unsigned(ard)) = (alast + 1) mod 2 ** 16 then arun := arun + 1; else arun := 0; end if;
						afirst := false;
					elsif to_integer(unsigned(ard)) /= (alast + 1) mod 2 ** 16 then
						arun := 0; afirst := true;
					end if;
					alast := to_integer(unsigned(ard));
				end if;
				if clear = '1' then run := 0; arun := 0; afirst := true; end if;
				runs(side) <= run; aruns(side) <= arun;
			end if;
		end process;
	end generate;

	process
		variable errors : natural := 0;
		variable t0 : time;
		procedure await(name : string; tmax : time) is
		begin
			clear <= '1'; wait for 1 us; clear <= '0';
			t0 := now;
			while not (run_a >= 120 and run_b >= 120 and arun_a >= 10 and arun_b >= 10) and now - t0 < tmax loop
				wait for 100 us;
			end loop;
			if run_a >= 120 and run_b >= 120 and arun_a >= 10 and arun_b >= 10 then
				say("tb_par_loop: " & name & ": both ways bit-exact again after " & integer'image((now - t0) / 1 us) & " us");
			else
				errors := errors + 1;
				say("FAIL detail " & name & ": runs A " & integer'image(run_a) & " B " & integer'image(run_b) &
					" aux A " & integer'image(arun_a) & " B " & integer'image(arun_b));
			end if;
		end procedure;
	begin
		wait for 100 ns;
		rst_a <= '0'; rst_b <= '0';
		await("48k start", 20 ms);
		cut <= '1'; wait for 3 ms; cut <= '0';
		wait for 1 ms;
		await("48k cable cut 3 ms", 20 ms);
		rst_b <= '1'; wait for 10 us; rst_b <= '0';
		wait for 1 ms;
		await("48k far-end reset", 20 ms);
		rst_a <= '1'; rst_b <= '1'; wait for 10 us; fs96 <= '1'; wait for 10 us; rst_a <= '0'; rst_b <= '0';
		wait for 1 ms;
		await("switch to 96k", 20 ms);
		if errors = 0 then
			say("PASS tb_par_loop: master <-> slave over the parallel interface, 48k (48 ch) and 96k (24 ch): every period bit-exact and in order both ways, aux words both ways; back after a 3 ms cable cut, a far-end reset and a rate switch");
		else
			say("FAIL tb_par_loop: " & integer'image(errors) & " errors");
		end if;
		std.env.stop;
		wait;
	end process;
end architecture;
