-- UART output must only receive auxiliary payload from validated blocks, at both sample rates.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
entity tb_uart_validated is end;
architecture sim of tb_uart_validated is
 signal clk, clka : std_logic := '0';
 signal rst : std_logic := '1';
 signal phy_rst_n, a_en, uart_out : std_logic;
 signal fs_mode : std_logic_vector(1 downto 0) := "01";
 signal req, enc_done, awe : std_logic := '0';
 signal uart_in : std_logic := '1';
 signal awaddr : unsigned(7 downto 0);
 signal awdata, adata : std_logic_vector(15 downto 0);
 signal aaddr : unsigned(6 downto 0);
 type ram_t is array(0 to 255) of std_logic_vector(15 downto 0);
 signal ram : ram_t;
 signal start, assm, busy, txen, wire_en : std_logic := '0';
 signal txd, wire_data : std_logic_vector(1 downto 0);
 signal dib : natural := 0;
 signal bad, cut : boolean := false;
 signal valid : std_logic;
 signal data : std_logic_vector(7 downto 0);
 signal received : natural := 0;
begin
 clk <= not clk after 10 ns;
 clka <= not clka after 10.1725 ns;
	u : entity work.aes50_core
		port map (
			clk50_i => clk, rst_i => rst, fs_mode_i => fs_mode, sys_mode_i => "01", tdm8_i2s_mode_i => '0',
			aux_tx_tdm_uart_select_i => '1', rmii_crs_dv_i => wire_en, rmii_rxd_i => wire_data, rmii_tx_en_o => open,
			rmii_txd_o => open, phy_rst_n_o => phy_rst_n,
			aes50_clk_a_rx_i => '0', aes50_clk_a_tx_o => open, aes50_clk_a_tx_en_o => a_en,
			aes50_clk_b_rx_i => '0', aes50_clk_b_tx_o => open, aes50_clk_b_tx_en_o => open,
			clk_1024xfs_from_pll_i => clka, pll_lock_n_i => '0', clk_to_pll_o => open, pll_mult_value_o => open,
			pll_init_busy_i => '0', mclk_o => open, wclk_o => open, bclk_o => open, wclk_readback_i => '0',
			bclk_readback_i => '0', wclk_out_en_o => open, bclk_out_en_o => open, tdm_i => (others => '0'), tdm_o => open,
			i2s_i => '0', i2s_o => open, aes_ok_o => open, dbg_o => open, uart_o => uart_out, uart_i => '1',
			debug_out_signal_pulse_len_i => 500000, first_transmit_start_counter_48k_i => 0,
			first_transmit_start_counter_44k1_i => 0, wd_aes_clk_timeout_i => 25, wd_aes_rx_dv_timeout_i => 7500,
			mdix_timer_1ms_reference_i => 50000, aes_clk_ok_counter_reference_i => 500000,
			mult_clk625_48k_i => 8246337, mult_clk625_44k1_i => 7576322, uart_clks_per_bit_i => 16,
			uart_timeout_clks_i => 500000);
 enc : entity work.aes50_aux_uart_enc
 port map(clk_i => clk, rst_i => rst, uart_i => uart_in, clks_per_bit_i => 16,
 timeout_clks_i => 32, fs48_i => fs_mode(0), req_i => req, req_page_i => '0',
 aux_we_o => awe, aux_addr_o => awaddr, aux_data_o => awdata, done_o => enc_done);
 tx : entity work.aes50_tx_framer
 port map(clk_i => clk, rst_i => rst, fs48_i => fs_mode(0), i2s_i => '0', start_i => start,
 base_i => (others => '0'), assm_i => assm, aux_valid_i => '1', busy_o => busy, frame_o => open,
 ram_addr_o => open, ram_data_i => x"000000", aux_addr_o => aaddr, aux_data_i => adata,
 rmii_txd_o => txd, rmii_tx_en_o => txen);
 wire_en <= '0' when cut and dib > 2000 else txen;
 wire_data <= txd xor "01" when bad and dib = 32 + 400 else txd;
 rx : entity work.aes50_uart_rx
 port map(clk_i => clk, rx_i => uart_out, clks_per_bit_i => 16, valid_o => valid, data_o => data);
 process(clk) begin
 if rising_edge(clk) then
  if awe = '1' then ram(to_integer(awaddr)) <= awdata; end if;
  adata <= ram(to_integer(aaddr));
  if txen = '1' then dib <= dib + 1; else dib <= 0; end if;
  if valid = '1' then
   assert data = x"A5" report "wrong UART payload" severity failure;
   received <= received + 1;
  end if;
 end if;
 end process;
 process
 procedure clocks(n : natural) is begin for i in 1 to n loop wait until falling_edge(clk); end loop; end;
 procedure send(b, c : boolean) is begin
  bad <= b; cut <= c; start <= '1'; assm <= '1'; clocks(1); start <= '0';
  wait until busy = '0'; clocks(5000);
 end;
 variable before : natural;
 constant payload : std_logic_vector(7 downto 0) := x"A5";
 begin
 for rate in 0 to 1 loop
  rst <= '1'; clocks(10); fs_mode(0) <= not fs_mode(0); clocks(10); rst <= '0';
  wait for 1.2 ms; clocks(1);
  uart_in <= '0'; clocks(16);
  for bit in 0 to 7 loop uart_in <= payload(bit); clocks(16); end loop;
  uart_in <= '1'; clocks(80);
  req <= '1'; clocks(1); req <= '0'; wait until enc_done = '1'; clocks(10);
  before := received;
  send(true, false);
  assert received = before report "bad FCS leaked to UART" severity failure;
  send(false, true);
  assert received = before report "truncated payload leaked to UART" severity failure;
  send(false, false);
  assert received = before + 1 report "good UART payload lost or duplicated" severity failure;
 end loop;
 write(output, string'("PASS tb_uart_validated: bad FCS and truncation suppressed, good payload delivered at 44.1/48k") & LF);
 std.env.stop; wait;
 end process;
 process begin wait for 10 ms; assert false report "timeout" severity failure; end process;
end;
