-- tb_neg_aux_depth.vhd (OpenProSeries): negative bench. aes50_par_core with 40-word aux pages cannot hold a block's
-- 44 aux words; the core must refuse it at start-up (static check on G_AUX_WORDS_PER_PAGE), before any fill could
-- overrun into the other page. The run must stop on that assertion (see the tb_neg_ rule in the Makefile).
-- EXPECT: aes50_par_core: aux page too small
-- License: GPL-3.0-or-later
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_neg_aux_depth is
end entity;

architecture sim of tb_neg_aux_depth is
	signal clk : std_logic := '0';
begin
	clk <= not clk after 10 ns;
	u : entity work.aes50_par_core
		generic map (G_AUX_WORDS_PER_PAGE => 40)
		port map (clk50_i => clk, rst_i => '1', fs96_i => '0', sys_mode_i => "01",
				  rmii_crs_dv_i => '0', rmii_rxd_i => "00", rmii_tx_en_o => open, rmii_txd_o => open, phy_rst_n_o => open,
				  aes50_clk_a_rx_i => '0', aes50_clk_a_tx_o => open, aes50_clk_a_tx_en_o => open,
				  aes50_clk_b_rx_i => '0', aes50_clk_b_tx_o => open, aes50_clk_b_tx_en_o => open,
				  clk_1024xfs_from_pll_i => clk, pll_lock_n_i => '0', clk_to_pll_o => open,
				  sample_tick_o => open, par_in_we_i => '0', par_in_ch_i => "000000", par_in_sample_i => x"000000",
				  par_out_valid_o => open, par_out_ch_o => open, par_out_phase_o => open, par_out_sample_o => open,
				  aux_tx_req_o => open, aux_tx_we_i => '0', aux_tx_data_i => x"0000",
				  aux_rx_count_o => open, aux_rx_rd_i => '0', aux_rx_first_o => open, aux_rx_data_o => open,
				  aes_ok_o => open, rx_ok_o => open, tx_started_o => open, tx_frame_o => open, rx_frame_ok_o => open,
				  rx_frame_err_o => open, rx_block_o => open, rx_block_drop_o => open, rx_assm_o => open,
				  fmt_valid_o => open, fmt_bad_o => open, fmt_o => open);
	process
	begin
		wait for 1 us;
		report "tb_neg_aux_depth: the core accepted a 40-word aux page" severity note;
		std.env.stop;
		wait;
	end process;
end architecture;
