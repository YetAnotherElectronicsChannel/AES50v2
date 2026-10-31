-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE (v2)
-- File         : <aes50_cs2x00_pll_controller.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
--
-- Description  : Initialises the CS2x00 audio PLL over I2C and writes the
--                ratio again whenever the core requests a new multiplier.
--                v2: clock frequency as generic (default 50 MHz), the wait
--                time between I2C transfers is derived from it.
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

entity aes50_cs2x00_pll_controller is
	generic (
		G_CLK_HZ				: natural := 50_000_000;	-- frequency of clk_i
		G_I2C_HZ				: natural := 100_000		-- SCL frequency
	);
	port (
		clk_i					: in  std_logic;
		rst_i					: in  std_logic;
		pll_mult_value_i		: in  natural;
		cs2x00_init_busy_o		: out std_logic;
		sda_i					: in  std_logic;
		scl_i					: in  std_logic;
		sda_en_o				: out std_logic;
		scl_en_o				: out std_logic;
		scl_o					: out std_logic;
		sda_o					: out std_logic
	);
end aes50_cs2x00_pll_controller;

architecture rtl of aes50_cs2x00_pll_controller is

	-- 7-bit I2C address of the CS2x00 (100 1110)
	constant C_I2C_ADDR		: std_logic_vector(6 downto 0) := "1001110";

	-- pause before the first and after every register write, ~167 us
	-- (v1: 16383 clocks at 100 MHz)
	constant C_WAIT_CLKS	: natural := G_CLK_HZ / 6000;

	-- register write sequence: (register address, value)
	--   0x03 : 0x07  AUX pin = PLL lock, device config enable 1
	--   0x05 : 0x09  freeze = 1, device config enable 2
	--   0x17 : 0x18  clock output also when unlocked, high-accuracy mode
	--   0x16 : 0x08  clock skip disabled, ref clock divider "01" (16..28 MHz)
	--   0x1E : 0x00  loop bandwidth 1 Hz
	--   0x04 : 0x01  hybrid PLL mode, lock-clock ratio 0
	--   0x06..0x09   ratio (multiplier) bytes 31..24, 23..16, 15..8, 7..0
	--   0x02 : 0x00  enable CLK_OUT and AUX output
	--   0x05 : 0x01  freeze = 0, changes take effect immediately
	constant C_NUM_REGS		: natural := 12;
	type reg_table_t is array (0 to C_NUM_REGS - 1, 0 to 1) of std_logic_vector(7 downto 0);
	constant C_REG_TABLE	: reg_table_t := (
		(x"03", x"07"),
		(x"05", x"09"),
		(x"17", x"18"),
		(x"16", x"08"),
		(x"1E", x"00"),
		(x"04", x"01"),
		(x"06", x"FF"),		-- ratio bytes: value taken from pll_mult
		(x"07", x"FF"),
		(x"08", x"FF"),
		(x"09", x"FF"),
		(x"02", x"00"),
		(x"05", x"01"));

	type state_t is (
		S_WAIT_RESET,		-- I2C master held in reset for C_WAIT_CLKS
		S_SEND_ADDR,		-- start transfer: device address + register address
		S_ADDR_BUSY,		-- wait until the master took the register address
		S_SEND_DATA,		-- master ready for the next byte: register value
		S_DATA_BUSY,		-- wait until the master took the register value
		S_DATA_DONE,		-- byte sent, end the transfer
		S_PAUSE,			-- pause, then next register or done
		S_DONE);
	signal state			: state_t := S_WAIT_RESET;

	signal wait_cnt			: natural range 0 to C_WAIT_CLKS := C_WAIT_CLKS;
	signal reg_index		: natural range 0 to C_NUM_REGS - 1 := 0;
	signal pll_mult			: std_logic_vector(31 downto 0) := (others => '0');
	signal pll_mult_last	: natural := 0;

	-- I2C master interface
	signal i2c_rst_n		: std_logic := '0';
	signal i2c_enable		: std_logic := '0';
	signal i2c_rw			: std_logic := '0';
	signal i2c_data			: std_logic_vector(7 downto 0) := (others => '0');
	signal i2c_busy			: std_logic;
	signal i2c_ack_error	: std_logic;

begin

	u_i2c : entity work.aes50_i2c_master(rtl)
		generic map (
			input_clk		=> G_CLK_HZ,
			bus_clk			=> G_I2C_HZ)
		port map (
			clk_i			=> clk_i,
			rst_n_i			=> i2c_rst_n,
			en_i			=> i2c_enable,
			addr_i			=> C_I2C_ADDR,
			rw_i			=> i2c_rw,
			data_wr_i		=> i2c_data,
			busy_o			=> i2c_busy,
			data_rd_o		=> open,
			ack_error_bfr	=> i2c_ack_error,
			sda_i			=> sda_i,
			scl_i			=> scl_i,
			sda_en_o		=> sda_en_o,
			scl_en_o		=> scl_en_o,
			scl_o			=> scl_o,
			sda_o			=> sda_o);

	process (clk_i)
	begin
		if rising_edge(clk_i) then
			-- a reset or a new multiplier restarts the whole sequence
			if rst_i = '1' or pll_mult_last /= pll_mult_value_i then
				wait_cnt			<= C_WAIT_CLKS;
				state				<= S_WAIT_RESET;
				reg_index			<= 0;
				pll_mult_last		<= pll_mult_value_i;
				pll_mult			<= std_logic_vector(to_unsigned(pll_mult_value_i, 32));
				cs2x00_init_busy_o	<= '1';
			else
				case state is
					when S_WAIT_RESET =>
						if wait_cnt > 0 then
							wait_cnt	<= wait_cnt - 1;
							i2c_rst_n	<= '0';
							i2c_enable	<= '0';
						else
							i2c_rst_n	<= '1';
							i2c_rw		<= '0';
							state		<= S_SEND_ADDR;
						end if;

					when S_SEND_ADDR =>
						i2c_enable	<= '1';
						i2c_data	<= C_REG_TABLE(reg_index, 0);
						state		<= S_ADDR_BUSY;

					when S_ADDR_BUSY =>
						if i2c_busy = '1' then
							state <= S_SEND_DATA;
						end if;

					when S_SEND_DATA =>
						if i2c_busy = '0' then
							case C_REG_TABLE(reg_index, 0) is
								when x"06"	=> i2c_data <= pll_mult(31 downto 24);
								when x"07"	=> i2c_data <= pll_mult(23 downto 16);
								when x"08"	=> i2c_data <= pll_mult(15 downto 8);
								when x"09"	=> i2c_data <= pll_mult(7 downto 0);
								when others	=> i2c_data <= C_REG_TABLE(reg_index, 1);
							end case;
							state <= S_DATA_BUSY;
						end if;

					when S_DATA_BUSY =>
						if i2c_busy = '1' then
							state <= S_DATA_DONE;
						end if;

					when S_DATA_DONE =>
						if i2c_busy = '0' then
							i2c_enable	<= '0';
							wait_cnt	<= C_WAIT_CLKS;
							state		<= S_PAUSE;
						end if;

					when S_PAUSE =>
						if wait_cnt > 0 then
							wait_cnt <= wait_cnt - 1;
						elsif reg_index < C_NUM_REGS - 1 then
							reg_index	<= reg_index + 1;
							state		<= S_SEND_ADDR;
						else
							state				<= S_DONE;
							cs2x00_init_busy_o	<= '0';
						end if;

					when S_DONE =>
						null;
				end case;
			end if;
		end if;
	end process;

end architecture;
