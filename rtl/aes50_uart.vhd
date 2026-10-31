-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE (v2)
-- File         : <aes50_uart.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel) - based on UART modules from https://nandland.com/
--
-- Description  : Minimal UART receiver and transmitter (8N1), bit time given
--                in clock cycles.
--
-- License      : No license information in files from nandland.com
--
-- This file is part of the AES50 VHDL IP-CORE.
-- ===========================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ---------------------------------------------------------------- receiver
entity aes50_uart_rx is
	port (
		clk_i			: in  std_logic;
		rx_i			: in  std_logic;		-- asynchronous
		clks_per_bit_i	: in  natural range 0 to 65535;
		valid_o			: out std_logic;		-- one clock per received byte
		data_o			: out std_logic_vector(7 downto 0)
	);
end entity;

architecture rtl of aes50_uart_rx is

	type state_t is (S_IDLE, S_START, S_DATA, S_STOP);
	signal state		: state_t := S_IDLE;
	signal rx_samples	: std_logic_vector(1 downto 0) := "11";	-- synchronizer
	signal clk_cnt		: natural range 0 to 65535 := 0;
	signal bit_idx		: natural range 0 to 7 := 0;
	signal shift		: std_logic_vector(7 downto 0) := (others => '0');

begin

	process (clk_i)
		variable rx : std_logic;
	begin
		if rising_edge(clk_i) then
			rx_samples	<= rx_samples(0) & rx_i;
			rx			:= rx_samples(1);
			valid_o		<= '0';

			case state is
				when S_IDLE =>
					clk_cnt <= 0;
					if rx = '0' then
						state <= S_START;
					end if;

				when S_START =>								-- check the middle of the start bit
					if clk_cnt = (clks_per_bit_i - 1) / 2 then
						clk_cnt <= 0;
						bit_idx <= 0;
						if rx = '0' then state <= S_DATA; else state <= S_IDLE; end if;
					else
						clk_cnt <= clk_cnt + 1;
					end if;

				when S_DATA =>								-- sample in the middle of each bit, LSB first
					if clk_cnt = clks_per_bit_i - 1 then
						clk_cnt	<= 0;
						shift	<= rx & shift(7 downto 1);
						if bit_idx = 7 then
							state <= S_STOP;
						else
							bit_idx <= bit_idx + 1;
						end if;
					else
						clk_cnt <= clk_cnt + 1;
					end if;

				when S_STOP =>
					if clk_cnt = clks_per_bit_i - 1 then
						clk_cnt	<= 0;
						state	<= S_IDLE;
						if rx = '1' then
							valid_o	<= '1';
							data_o	<= shift;
						end if;
					else
						clk_cnt <= clk_cnt + 1;
					end if;
			end case;
		end if;
	end process;

end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ---------------------------------------------------------------- transmitter
entity aes50_uart_tx is
	port (
		clk_i			: in  std_logic;
		clks_per_bit_i	: in  natural range 0 to 65535;
		start_i			: in  std_logic;		-- accepted when busy_o = '0'
		data_i			: in  std_logic_vector(7 downto 0);
		busy_o			: out std_logic;
		tx_o			: out std_logic
	);
end entity;

architecture rtl of aes50_uart_tx is

	signal busy			: std_logic := '0';
	signal clk_cnt		: natural range 0 to 65535 := 0;
	signal bit_cnt		: natural range 0 to 9 := 0;
	signal shift		: std_logic_vector(9 downto 0) := (others => '1');	-- stop & data & start

begin

	busy_o	<= busy;
	tx_o	<= shift(0) when busy = '1' else '1';

	process (clk_i)
	begin
		if rising_edge(clk_i) then
			if busy = '0' then
				if start_i = '1' then
					shift	<= '1' & data_i & '0';
					busy	<= '1';
					clk_cnt	<= 0;
					bit_cnt	<= 0;
				end if;
			elsif clk_cnt = clks_per_bit_i - 1 then
				clk_cnt	<= 0;
				shift	<= '1' & shift(9 downto 1);
				if bit_cnt = 9 then
					busy <= '0';
				else
					bit_cnt <= bit_cnt + 1;
				end if;
			else
				clk_cnt <= clk_cnt + 1;
			end if;
		end if;
	end process;

end architecture;
