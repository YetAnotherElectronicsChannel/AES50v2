-- tb_assm_init.vhd (OpenProSeries): aes50_clk_audio's first ASSM position. As AES50 leader (sys_mode "01") with
-- G_ASSM_INIT = (2048 - 144)*64 the first self-generated ASSM comes 144 samples (144*1024 clocks) after reset, the
-- second one 2048 samples after the first (the period is unchanged); the default (2) is checked by the same
-- formula on the first ASSM.
-- License: GPL-3.0-or-later
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_assm_init is
end entity;

architecture sim of tb_assm_init is
	signal clk				: std_logic := '0';
	signal rst				: std_logic := '1';
	signal t_fast, t_def	: std_logic;
	procedure say(s : string) is
		variable l : line;
	begin
		write(l, s); writeline(output, l);
	end procedure;
begin
	clk <= not clk after 10 ns;
	u_fast : entity work.aes50_clk_audio
		generic map (G_ASSM_INIT => (2048 - 144) * 64)
		port map (clk_i => clk, rst_i => rst, sys_mode_i => "01", i2s_i => '0', aes_clk_in_i => '0', aes_clk_gen_o => open,
				  assm_self_tgl_o => t_fast, assm_remote_tgl_o => open, wclk_readback_i => '0', mclk_o => open,
				  bclk_o => open, wclk_o => open);
	u_def : entity work.aes50_clk_audio
		port map (clk_i => clk, rst_i => rst, sys_mode_i => "01", i2s_i => '0', aes_clk_in_i => '0', aes_clk_gen_o => open,
				  assm_self_tgl_o => t_def, assm_remote_tgl_o => open, wclk_readback_i => '0', mclk_o => open,
				  bclk_o => open, wclk_o => open);
	process
		variable errors		: natural := 0;
		variable n, n1, n2	: natural := 0;
		variable seen_def	: boolean := false;
		variable p_fast, p_def : std_logic;
	begin
		wait for 35 ns; wait until rising_edge(clk);
		rst <= '0';
		p_fast := t_fast; p_def := t_def;
		-- 16 clocks per 64*fs period: the fast one first at 144 * 64 * 16 = 144 * 1024 clocks
		while n < (2048 + 144) * 1024 + 4096 loop
			wait until rising_edge(clk);
			n := n + 1;
			if t_fast /= p_fast then
				if n1 = 0 then n1 := n; elsif n2 = 0 then n2 := n; end if;
				p_fast := t_fast;
			end if;
			if t_def /= p_def and not seen_def then
				seen_def := true;
				if abs (n - (2048 * 64 - 2) * 16) > 4 then
					errors := errors + 1; say("FAIL detail: default first ASSM at clock " & integer'image(n));
				end if;
			end if;
		end loop;
		if abs (n1 - 144 * 1024) > 4 then errors := errors + 1; say("FAIL detail: first ASSM at clock " & integer'image(n1)); end if;
		if n2 - n1 /= 2048 * 1024 then errors := errors + 1; say("FAIL detail: ASSM period " & integer'image(n2 - n1)); end if;
		if not seen_def then errors := errors + 1; say("FAIL detail: no default ASSM"); end if;
		if errors = 0 then
			say("PASS tb_assm_init: G_ASSM_INIT puts the first ASSM 144 samples after reset (clock " & integer'image(n1) & "), period still 2048 samples; default unchanged");
		else
			say("FAIL tb_assm_init: " & integer'image(errors) & " errors");
		end if;
		std.env.stop;
		wait;
	end process;
end architecture;
