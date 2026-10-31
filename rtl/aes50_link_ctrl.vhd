-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE (v2)
-- File         : <aes50_link_ctrl.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
--
-- Description  : Link supervision in the 50 MHz domain: sync signal
--                watchdogs, clock health, RX data-valid watchdog, automatic
--                MDI/MDI-X selection of the sync pair, 6.25 MHz PLL reference.
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

-- Same behaviour as the 100 MHz process of the v1 aes50_clockmanager, all
-- timer values are now counted in 50 MHz clocks.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aes50_link_ctrl is
	port (
		clk_i					: in  std_logic;		-- 50 MHz
		rst_i					: in  std_logic;

		aes_clk_a_rx_i			: in  std_logic;		-- asynchronous
		aes_clk_b_rx_i			: in  std_logic;
		pll_lock_n_i			: in  std_logic;
		rx_dv_i					: in  std_logic;		-- RMII CRS_DV

		wd_aes_clk_timeout_i	: in  natural range 0 to 50;
		wd_aes_rx_dv_timeout_i	: in  natural range 0 to 20000;
		mdix_timer_1ms_i		: in  natural range 0 to 100000;
		aes_clk_ok_ref_i		: in  natural range 0 to 1000000;

		mdix_o					: out std_logic;		-- '0' MDI (A = TX, B = RX), '1' MDI-X
		aes_clock_ok_o			: out std_logic;		-- both sync pairs active and PLL locked
		clock_health_good_o		: out std_logic;		-- sync pairs active for aes_clk_ok_ref_i clocks
		rx_ok_o					: out std_logic;		-- RMII receive activity
		clk625_o				: out std_logic			-- 6.25 MHz PLL reference
	);
end entity;

architecture rtl of aes50_link_ctrl is

	signal ref625_phase		: unsigned(2 downto 0);			-- 8 clocks per 6.25 MHz period

	-- last 3 samples of the asynchronous inputs: synchronizer + edge detector
	signal clk_a_samples	: std_logic_vector(2 downto 0);
	signal clk_b_samples	: std_logic_vector(2 downto 0);
	signal rx_dv_samples	: std_logic_vector(2 downto 0);

	-- watchdogs: reloaded on every rising edge, '0' = signal missing
	signal clk_a_watchdog	: natural range 0 to 50;
	signal clk_b_watchdog	: natural range 0 to 50;
	signal rx_dv_watchdog	: natural range 0 to 20000;
	signal clk_ok_cnt		: natural range 0 to 1000000;	-- how long both sync pairs are active
	signal clock_ok			: std_logic;

	-- MDI / MDI-X selection
	signal lfsr				: std_logic_vector(10 downto 0);	-- pseudo random decision every 1 ms
	signal mdix				: std_logic;
	signal mdix_timer_cnt	: natural range 0 to 100000;

begin

	mdix_o			<= mdix;
	aes_clock_ok_o	<= clock_ok;

	process (clk_i)
	begin
		if rising_edge(clk_i) then
			if rst_i = '1' then
				ref625_phase		<= (others => '0');
				clk625_o			<= '0';
				clk_a_watchdog		<= 0;
				clk_b_watchdog		<= 0;
				rx_dv_watchdog		<= 0;
				clock_ok			<= '0';
				clock_health_good_o	<= '0';
				rx_ok_o				<= '0';
				mdix				<= '0';
				lfsr				<= "10110101011";
				mdix_timer_cnt		<= mdix_timer_1ms_i;
				clk_ok_cnt			<= 0;
			else
				ref625_phase	<= ref625_phase + 1;
				clk625_o		<= not ref625_phase(2);			-- high for 4 of 8 clocks

				clk_a_samples	<= clk_a_samples(1 downto 0) & aes_clk_a_rx_i;
				clk_b_samples	<= clk_b_samples(1 downto 0) & aes_clk_b_rx_i;
				rx_dv_samples	<= rx_dv_samples(1 downto 0) & rx_dv_i;

				if clk_a_samples(2 downto 1) = "01" then
					clk_a_watchdog <= wd_aes_clk_timeout_i;
				elsif clk_a_watchdog > 0 then
					clk_a_watchdog <= clk_a_watchdog - 1;
				end if;
				if clk_b_samples(2 downto 1) = "01" then
					clk_b_watchdog <= wd_aes_clk_timeout_i;
				elsif clk_b_watchdog > 0 then
					clk_b_watchdog <= clk_b_watchdog - 1;
				end if;

				if clk_a_watchdog > 0 and clk_b_watchdog > 0 and pll_lock_n_i = '0' then
					clock_ok <= '1';
				else
					clock_ok <= '0';
				end if;

				if clk_a_watchdog > 0 and clk_b_watchdog > 0 then
					if clk_ok_cnt < aes_clk_ok_ref_i then
						clk_ok_cnt <= clk_ok_cnt + 1;
					else
						clock_health_good_o <= '1';
					end if;
				else
					clk_ok_cnt				<= 0;
					clock_health_good_o	<= '0';
				end if;

				if rx_dv_samples(2 downto 1) = "01" then
					rx_dv_watchdog <= wd_aes_rx_dv_timeout_i;
				elsif rx_dv_watchdog > 0 then
					rx_dv_watchdog <= rx_dv_watchdog - 1;
				end if;
				if rx_dv_watchdog > 0 then rx_ok_o <= '1'; else rx_ok_o <= '0'; end if;

				-- MDI/MDI-X: pseudo random toggling every 1 ms until sync is detected
				if mdix_timer_cnt > 0 then
					mdix_timer_cnt <= mdix_timer_cnt - 1;
				else
					lfsr		<= lfsr(9 downto 0) & (lfsr(8) xor lfsr(10));
					mdix_timer_cnt	<= mdix_timer_1ms_i;
					if mdix = '0' and lfsr(10) = '1' and clock_ok = '0' then
						mdix <= '1';
					elsif mdix = '1' and lfsr(10) = '0' and clock_ok = '0' then
						mdix <= '0';
					end if;
				end if;
			end if;
		end if;
	end process;

end architecture;
