-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE (v2)
-- File         : <aes50_aux_uart_dec.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
--
-- Description  : Aux channel decoder for the UART output: received aux words
--                are scanned for delimiters, de-stuffed, descrambled and the
--                packet bytes are sent out on the UART.
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

-- Inverse of aes50_aux_uart_enc / v1 aes50_aux_decoder: the aux bits run
-- through an 11-bit window; the delimiter "0 111111111 0" (re)starts byte
-- alignment, the bits leaving the window are payload: a '0' after eight '1'
-- is removed, the rest is descrambled (d = s xor s[5] xor s[9]) and
-- assembled to bytes (LSB first).
-- The descrambler state is reset at the first bit of each Ethernet frame
-- (word with start marker), as the encoder does.  Difference to v1: there
-- this reset was lost when the frame started inside a packet (it was
-- overwritten by the payload processing in the same clock).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aes50_aux_uart_dec is
	generic (
		G_FIFO_AW		: natural := 11			-- UART output FIFO: 2**G_FIFO_AW - 1 bytes
	);
	port (
		clk_i			: in  std_logic;		-- 50 MHz
		rst_i			: in  std_logic;

		aux_we_i		: in  std_logic;		-- received aux words in stream order
		aux_data_i		: in  std_logic_vector(15 downto 0);
		aux_start_i		: in  std_logic;		-- first word of an Ethernet frame

		clks_per_bit_i	: in  natural range 0 to 65535;
		uart_o			: out std_logic
	);
end entity;

architecture rtl of aes50_aux_uart_dec is

	-- input FIFO (word + start marker); the decoder needs 16 clocks per word
	signal in_word			: std_logic_vector(16 downto 0);		-- aux word & start marker
	signal in_rd			: std_logic;
	signal in_data			: std_logic_vector(16 downto 0);
	signal in_empty			: std_logic;
	signal fetch_step		: natural range 0 to 2;

	-- bit processing
	signal busy				: std_logic;						-- a word is being processed
	signal word_reg			: std_logic_vector(15 downto 0);
	signal word_start		: std_logic;						-- the word starts an Ethernet frame
	signal bit_idx			: natural range 0 to 15;
	signal window			: std_logic_vector(10 downto 0);	-- last 11 aux bits
	signal descrambler		: std_logic_vector(8 downto 0);
	signal ones_cnt			: natural range 0 to 8;
	signal flush_cnt		: natural range 0 to 10;			-- skips the bits of a detected delimiter
	signal byte_shift		: std_logic_vector(7 downto 0);
	signal byte_bit			: natural range 0 to 7;
	signal synced			: std_logic;						-- a delimiter has been seen
	signal byte_valid		: std_logic;
	signal byte_data		: std_logic_vector(7 downto 0);

	-- UART output
	signal out_rd			: std_logic;
	signal out_data			: std_logic_vector(7 downto 0);
	signal out_empty		: std_logic;
	signal tx_start			: std_logic;
	signal tx_byte			: std_logic_vector(7 downto 0);		-- held while the transmitter takes it
	signal tx_busy			: std_logic;
	signal tx_step			: natural range 0 to 3;

begin

	in_word <= aux_data_i & aux_start_i;

	u_in : entity work.aes50_fifo
		generic map (G_AW => 4, G_DW => 17)
		port map (clk_i => clk_i, rst_i => rst_i, wr_en_i => aux_we_i, wr_data_i => in_word,
				  rd_en_i => in_rd, rd_data_o => in_data, empty_o => in_empty, count_o => open);

	process (clk_i)
		variable cur_bit	: std_logic;
		variable win		: std_logic_vector(10 downto 0);
		variable pbit		: std_logic;		-- payload bit leaving the window
		variable dstate		: std_logic_vector(8 downto 0);
		variable dbit		: std_logic;
	begin
		if rising_edge(clk_i) then
			in_rd		<= '0';
			byte_valid	<= '0';

			-- fetch the next word (read data is valid two clocks after rd_en)
			case fetch_step is
				when 0 =>
					if busy = '0' and in_empty = '0' then
						in_rd		<= '1';
						fetch_step	<= 1;
					end if;
				when 1 =>
					fetch_step <= 2;
				when 2 =>
					word_reg	<= in_data(16 downto 1);
					word_start	<= in_data(0);
					bit_idx		<= 0;
					busy		<= '1';
					fetch_step	<= 0;
			end case;

			if busy = '1' then
				cur_bit	:= word_reg(bit_idx);
				win		:= window(9 downto 0) & cur_bit;
				window	<= win;

				-- the bit leaving the window now is bit 0 of a frame start word:
				-- the descrambler starts from zero (also while idle delimiters pass)
				if word_start = '1' and bit_idx = 10 then
					dstate := (others => '0');
				else
					dstate := descrambler;
				end if;
				descrambler <= dstate;

				if win = "01111111110" then					-- delimiter: restart byte alignment
					flush_cnt	<= 10;
					ones_cnt	<= 0;
					byte_bit	<= 0;
					synced		<= '1';
				elsif flush_cnt > 0 then
					flush_cnt <= flush_cnt - 1;
					if flush_cnt = 1 then
						byte_bit <= 0;
						ones_cnt <= 0;
					end if;
				else
					pbit := win(10);						-- bit received 10 clocks ago
					if ones_cnt = 8 and pbit = '0' then		-- stuffing bit
						ones_cnt	<= 0;
					else
						dbit		:= pbit xor dstate(4) xor dstate(8);
						descrambler	<= dstate(7 downto 0) & pbit;
						if pbit = '1' and ones_cnt < 8 then
							ones_cnt <= ones_cnt + 1;
						else
							ones_cnt <= 0;
						end if;
						byte_shift <= dbit & byte_shift(7 downto 1);
						if byte_bit = 7 then
							byte_data	<= dbit & byte_shift(7 downto 1);
							byte_valid	<= synced;
							byte_bit	<= 0;
						else
							byte_bit <= byte_bit + 1;
						end if;
					end if;
				end if;

				if bit_idx = 15 then
					busy <= '0';
				else
					bit_idx <= bit_idx + 1;
				end if;
			end if;

			if rst_i = '1' then
				busy		<= '0';
				fetch_step	<= 0;
				window		<= (others => '0');
				descrambler	<= (others => '0');
				ones_cnt	<= 0;
				flush_cnt	<= 0;
				byte_bit	<= 0;
				synced		<= '0';
			end if;
		end if;
	end process;

	-- UART output FIFO and transmitter
	u_out : entity work.aes50_fifo
		generic map (G_AW => G_FIFO_AW, G_DW => 8)
		port map (clk_i => clk_i, rst_i => rst_i, wr_en_i => byte_valid, wr_data_i => byte_data,
				  rd_en_i => out_rd, rd_data_o => out_data, empty_o => out_empty, count_o => open);

	u_tx : entity work.aes50_uart_tx
		port map (clk_i => clk_i, clks_per_bit_i => clks_per_bit_i, start_i => tx_start,
				  data_i => tx_byte, busy_o => tx_busy, tx_o => uart_o);

	process (clk_i)
	begin
		if rising_edge(clk_i) then
			out_rd		<= '0';
			tx_start	<= '0';
			case tx_step is
				when 0 =>
					if out_empty = '0' and tx_busy = '0' then
						out_rd	<= '1';
						tx_step	<= 1;
					end if;
				when 1 =>
					tx_step <= 2;
				when 2 =>							-- out_data is the byte read in step 0
					tx_byte		<= out_data;
					tx_start	<= '1';
					tx_step		<= 3;
				when 3 =>							-- wait until the transmitter took it
					if tx_busy = '1' then
						tx_step <= 0;
					end if;
			end case;
			if rst_i = '1' then
				tx_step <= 0;
			end if;
		end if;
	end process;

end architecture;
