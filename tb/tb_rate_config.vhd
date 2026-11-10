-- All support/rate selections: 48k-only hardware must never select a 44.1k format or PLL ratio.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.aes50_pkg.all;
entity tb_rate_config is end;
architecture sim of tb_rate_config is
 signal clk, clka : std_logic := '0';
 signal rst : std_logic := '1';
 type counts_t is array(0 to 3) of natural;
 signal counts : counts_t := (others => 0);
 function bit_value(b : boolean) return std_logic is begin if b then return '1'; else return '0'; end if; end;
begin
 clk <= not clk after 10 ns;
 clka <= not clka after 10.1725 ns;
 cases : for i in 0 to 3 generate
  constant support : boolean := i >= 2;
  constant selected : std_logic := bit_value(i mod 2 = 1);
  constant effective : std_logic := bit_value(not support or selected = '1');
  signal phy_rst_n, a_en, sync_pin, wclk, bclk, txen, fv : std_logic;
  signal txd : std_logic_vector(1 downto 0);
  signal fmt : std_logic_vector(7 downto 0);
  signal mult : natural;
 begin
	u : entity work.aes50_core
 generic map(G_SUPPORT_44K1 => support, G_UART_AUX => false, G_TDM_AUX => false, G_SIM_ASSM_SAMPLES => 64)
		port map (
			clk50_i => clk, rst_i => rst, fs_mode_i => "0" & selected, sys_mode_i => "01", tdm8_i2s_mode_i => '0',
			aux_tx_tdm_uart_select_i => '1', rmii_crs_dv_i => '0', rmii_rxd_i => "00", rmii_tx_en_o => txen,
			rmii_txd_o => txd, phy_rst_n_o => phy_rst_n,
			aes50_clk_a_rx_i => sync_pin, aes50_clk_a_tx_o => sync_pin, aes50_clk_a_tx_en_o => a_en,
			aes50_clk_b_rx_i => sync_pin, aes50_clk_b_tx_o => open, aes50_clk_b_tx_en_o => open,
			clk_1024xfs_from_pll_i => clka, pll_lock_n_i => '0', clk_to_pll_o => open, pll_mult_value_o => mult,
			pll_init_busy_i => '0', mclk_o => open, wclk_o => wclk, bclk_o => bclk, wclk_readback_i => wclk,
			bclk_readback_i => bclk, wclk_out_en_o => open, bclk_out_en_o => open, tdm_i => (others => '0'), tdm_o => open,
			i2s_i => '0', i2s_o => open, aes_ok_o => open, dbg_o => open, uart_o => open, uart_i => '1',
			debug_out_signal_pulse_len_i => 500000, first_transmit_start_counter_48k_i => 0,
			first_transmit_start_counter_44k1_i => 0, wd_aes_clk_timeout_i => 25, wd_aes_rx_dv_timeout_i => 7500,
			mdix_timer_1ms_reference_i => 50000, aes_clk_ok_counter_reference_i => 50,
			mult_clk625_48k_i => 8246337, mult_clk625_44k1_i => 7576322, uart_clks_per_bit_i => 434,
			uart_timeout_clks_i => 500000);
  monitor : entity work.aes50_rx_deframer
  port map(clk_i => clk, rst_i => rst, fs48_i => effective, rmii_crs_dv_i => txen, rmii_rxd_i => txd,
   ram_we_o => open, ram_addr_o => open, ram_data_o => open, aux_we_o => open, aux_addr_o => open,
   aux_data_o => open, blk_done_o => open, blk_base_o => open, blk_page_o => open,
   blk_ok_o => open, blk_assm_o => open, frame_ok_o => open, frame_err_o => open,
   fmt_valid_o => fv, fmt_bad_o => open, fmt_o => fmt, sync_o => open);
  process(clk) begin
   if rising_edge(clk) and rst = '0' then
    if effective = '1' then
     assert mult = 8246337 report "48k-only PLL ratio is wrong" severity failure;
    else assert mult = 7576322 report "44.1k PLL ratio is wrong" severity failure; end if;
    if fv = '1' then
     if effective = '1' then assert fmt = FMT_48K severity failure;
     else assert fmt = FMT_44K1 severity failure; end if;
     counts(i) <= counts(i) + 1;
    end if;
   end if;
  end process;
 end generate;
 process begin
 wait for 100 ns; rst <= '0'; wait for 8 ms;
 for i in counts'range loop assert counts(i) > 0 report "rate selection never sent a frame" severity failure; end loop;
 write(output, string'("PASS tb_rate_config: all four support/rate choices send the effective format and PLL ratio") & LF);
 std.env.stop; wait;
 end process;
end;
