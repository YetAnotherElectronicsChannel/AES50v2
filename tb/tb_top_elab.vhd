-- tb_top_elab.vhd (OpenProSeries): aes50_top must elaborate and come out of reset in GHDL, with the documented timer
-- and UART values (README: 115200 baud = 434 clocks a bit at 50 MHz, 10 ms timeout). Checks the PHY reset is
-- released after 1 ms and the core then drives its sync-signal pair (MDI: pair A), as AES50 master.
-- License: GPL-3.0-or-later
library ieee;
use ieee.std_logic_1164.all;
use std.textio.all;

entity tb_top_elab is
end entity;

architecture sim of tb_top_elab is
	signal clk, clka	: std_logic := '0';
	signal rst			: std_logic := '1';
	signal phy_rst_n	: std_logic;
	signal a_en			: std_logic;
	procedure say(s : string) is
		variable l : line;
	begin
		write(l, s); writeline(output, l);
	end procedure;
begin
	clk  <= not clk after 10 ns;
	clka <= not clka after 10.1725 ns;
	u : entity work.aes50_top
		port map (
			clk50_i => clk, rst_i => rst, fs_mode_i => "01", sys_mode_i => "01", tdm8_i2s_mode_i => '0',
			aux_tx_tdm_uart_select_i => '1', rmii_crs_dv_i => '0', rmii_rxd_i => "00", rmii_tx_en_o => open,
			rmii_txd_o => open, phy_rst_n_o => phy_rst_n,
			aes50_clk_a_rx_i => '0', aes50_clk_a_tx_o => open, aes50_clk_a_tx_en_o => a_en,
			aes50_clk_b_rx_i => '0', aes50_clk_b_tx_o => open, aes50_clk_b_tx_en_o => open,
			clk_1024xfs_from_pll_i => clka, pll_lock_n_i => '0', clk_to_pll_o => open, pll_mult_value_o => open,
			pll_init_busy_i => '0', mclk_o => open, wclk_o => open, bclk_o => open, wclk_readback_i => '0',
			bclk_readback_i => '0', wclk_out_en_o => open, bclk_out_en_o => open, tdm_i => (others => '0'), tdm_o => open,
			i2s_i => '0', i2s_o => open, aes_ok_o => open, dbg_o => open, uart_o => open, uart_i => '1',
			debug_out_signal_pulse_len_i => 500000, first_transmit_start_counter_48k_i => 0,
			first_transmit_start_counter_44k1_i => 0, wd_aes_clk_timeout_i => 25, wd_aes_rx_dv_timeout_i => 7500,
			mdix_timer_1ms_reference_i => 50000, aes_clk_ok_counter_reference_i => 500000,
			mult_clk625_48k_i => 8246337, mult_clk625_44k1_i => 7576322, uart_clks_per_bit_i => 434,
			uart_timeout_clks_i => 500000);
	process
	begin
		wait for 100 ns; rst <= '0';
		wait for 900 us;
		if phy_rst_n /= '0' then say("FAIL tb_top_elab: PHY reset released before 1 ms"); std.env.stop; end if;
		wait for 200 us;
		if phy_rst_n = '1' and a_en = '1' then
			say("PASS tb_top_elab: aes50_top elaborates in GHDL with the documented UART / timer values, PHY reset released after 1 ms, sync pair A driven");
		else
			say("FAIL tb_top_elab: PHY reset " & std_logic'image(phy_rst_n) & ", pair A enable " & std_logic'image(a_en));
		end if;
		std.env.stop;
		wait;
	end process;
end architecture;
