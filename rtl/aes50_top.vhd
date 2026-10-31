-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE (v2)
-- File         : <aes50_top.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
--
-- Description  : Top-Module for the AES50 IP Core (v2).  Same ports as v1
--                except clk100_i, which is no longer needed.  The function is
--                in aes50_core; see there for the description.
--
-- License      : GNU General Public License v3.0 or later (GPL-3.0-or-later)
--
-- This file is part of the AES50 VHDL IP-CORE.
--
-- The AES50 VHDL IP-CORE is free software: you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as published
-- by the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- The AES50 VHDL IP-CORE is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program. If not, see <https://www.gnu.org/licenses/>.
-- ===========================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aes50_top is
	generic (
		G_SUPPORT_44K1		: boolean := true;		-- false: half-size sample RAMs, 48k only
		G_UART_AUX			: boolean := true;		-- aux channel over UART
		G_TDM_AUX			: boolean := true;		-- aux channel over the 7th TDM line
		G_UART_FIFO_AW		: natural := 11;		-- UART FIFOs: 2**n - 1 bytes
		G_FSYNC_DELAY		: natural := 0;			-- TDM: 0 = MSB with the WCLK edge, 1 = one BCLK later
		G_TX_LEAD_ADJ		: integer := 0;			-- TX block alignment against the ASSM (frames)
		G_SIM_ASSM_SAMPLES	: natural := 2048		-- simulation only: shorter ASSM period
	);
	port (
		--clk and reset
		clk50_i								: in  std_logic;
		rst_i								: in  std_logic;

		--samplerate and operation mode
		fs_mode_i							: in  std_logic_vector(1 downto 0);
		sys_mode_i							: in  std_logic_vector(1 downto 0);
		tdm8_i2s_mode_i						: in  std_logic;
		aux_tx_tdm_uart_select_i			: in  std_logic;

		--connection to phy
		rmii_crs_dv_i						: in  std_logic;
		rmii_rxd_i							: in  std_logic_vector(1 downto 0);
		rmii_tx_en_o						: out std_logic;
		rmii_txd_o							: out std_logic_vector(1 downto 0);
		phy_rst_n_o							: out std_logic;

		--connection to clk transceivers
		aes50_clk_a_rx_i					: in  std_logic;
		aes50_clk_a_tx_o					: out std_logic;
		aes50_clk_a_tx_en_o					: out std_logic;

		aes50_clk_b_rx_i					: in  std_logic;
		aes50_clk_b_tx_o					: out std_logic;
		aes50_clk_b_tx_en_o					: out std_logic;

		--interface to external PLL
		clk_1024xfs_from_pll_i				: in  std_logic;
		pll_lock_n_i						: in  std_logic;
		clk_to_pll_o						: out std_logic;
		pll_mult_value_o					: out natural;
		pll_init_busy_i						: in  std_logic;

		--tdm/i2s clk interface
		mclk_o								: out std_logic;
		wclk_o								: out std_logic;
		bclk_o								: out std_logic;
		wclk_readback_i						: in  std_logic;
		bclk_readback_i						: in  std_logic;
		wclk_out_en_o						: out std_logic;
		bclk_out_en_o						: out std_logic;

		tdm_i								: in  std_logic_vector(6 downto 0);
		tdm_o								: out std_logic_vector(6 downto 0);

		i2s_i								: in  std_logic;
		i2s_o								: out std_logic;

		--aes health signal
		aes_ok_o							: out std_logic;

		--debug signals
		dbg_o								: out std_logic_vector(7 downto 0);

		--uart Signals
		uart_o								: out std_logic;
		uart_i								: in  std_logic;

		--variables (timers count 50 MHz clocks)
		debug_out_signal_pulse_len_i		: in  natural range 0 to 1000000;		-- 500000 = 10 ms
		first_transmit_start_counter_48k_i	: in  natural range 0 to 5000000;		-- not used in v2
		first_transmit_start_counter_44k1_i	: in  natural range 0 to 5000000;		-- not used in v2

		wd_aes_clk_timeout_i				: in  natural range 0 to 50;			-- 25
		wd_aes_rx_dv_timeout_i				: in  natural range 0 to 20000;			-- 7500
		mdix_timer_1ms_reference_i			: in  natural range 0 to 100000;		-- 50000
		aes_clk_ok_counter_reference_i		: in  natural range 0 to 1000000;		-- 500000
		--PLL multiplicators for the 6.25 MHz reference (AES master + TDM master)
		mult_clk625_48k_i					: in  natural;							-- 8246337
		mult_clk625_44k1_i					: in  natural;							-- 7576322

		--uart speed configuration
		uart_clks_per_bit_i					: in  natural;							-- 434 for 115200 baud
		uart_timeout_clks_i					: in  natural							-- 500000 for 10 ms
	);
end aes50_top;

architecture rtl of aes50_top is
begin

	u_core : entity work.aes50_core
		generic map (
			G_SUPPORT_44K1 => G_SUPPORT_44K1,
			G_UART_AUX => G_UART_AUX,
			G_TDM_AUX => G_TDM_AUX,
			G_UART_FIFO_AW => G_UART_FIFO_AW,
			G_FSYNC_DELAY => G_FSYNC_DELAY,
			G_TX_LEAD_ADJ => G_TX_LEAD_ADJ,
			G_SIM_ASSM_SAMPLES => G_SIM_ASSM_SAMPLES)
		port map (
			clk50_i => clk50_i,
			rst_i => rst_i,
			fs_mode_i => fs_mode_i,
			sys_mode_i => sys_mode_i,
			tdm8_i2s_mode_i => tdm8_i2s_mode_i,
			aux_tx_tdm_uart_select_i => aux_tx_tdm_uart_select_i,
			rmii_crs_dv_i => rmii_crs_dv_i,
			rmii_rxd_i => rmii_rxd_i,
			rmii_tx_en_o => rmii_tx_en_o,
			rmii_txd_o => rmii_txd_o,
			phy_rst_n_o => phy_rst_n_o,
			aes50_clk_a_rx_i => aes50_clk_a_rx_i,
			aes50_clk_a_tx_o => aes50_clk_a_tx_o,
			aes50_clk_a_tx_en_o => aes50_clk_a_tx_en_o,
			aes50_clk_b_rx_i => aes50_clk_b_rx_i,
			aes50_clk_b_tx_o => aes50_clk_b_tx_o,
			aes50_clk_b_tx_en_o => aes50_clk_b_tx_en_o,
			clk_1024xfs_from_pll_i => clk_1024xfs_from_pll_i,
			pll_lock_n_i => pll_lock_n_i,
			clk_to_pll_o => clk_to_pll_o,
			pll_mult_value_o => pll_mult_value_o,
			pll_init_busy_i => pll_init_busy_i,
			mclk_o => mclk_o,
			wclk_o => wclk_o,
			bclk_o => bclk_o,
			wclk_readback_i => wclk_readback_i,
			bclk_readback_i => bclk_readback_i,
			wclk_out_en_o => wclk_out_en_o,
			bclk_out_en_o => bclk_out_en_o,
			tdm_i => tdm_i,
			tdm_o => tdm_o,
			i2s_i => i2s_i,
			i2s_o => i2s_o,
			aes_ok_o => aes_ok_o,
			dbg_o => dbg_o,
			uart_o => uart_o,
			uart_i => uart_i,
			debug_out_signal_pulse_len_i => debug_out_signal_pulse_len_i,
			first_transmit_start_counter_48k_i => first_transmit_start_counter_48k_i,
			first_transmit_start_counter_44k1_i => first_transmit_start_counter_44k1_i,
			wd_aes_clk_timeout_i => wd_aes_clk_timeout_i,
			wd_aes_rx_dv_timeout_i => wd_aes_rx_dv_timeout_i,
			mdix_timer_1ms_reference_i => mdix_timer_1ms_reference_i,
			aes_clk_ok_counter_reference_i => aes_clk_ok_counter_reference_i,
			mult_clk625_48k_i => mult_clk625_48k_i,
			mult_clk625_44k1_i => mult_clk625_44k1_i,
			uart_clks_per_bit_i => uart_clks_per_bit_i,
			uart_timeout_clks_i => uart_timeout_clks_i);

end architecture;
