-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE (v2)
-- File         : <aes50_aux_uart_enc.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
--
-- Description  : Aux channel encoder for the UART input: bytes received on
--                the UART are scrambled, bit-stuffed and framed with
--                delimiters, idle delimiters are sent when there is no data.
--                One request produces the aux words of one AES50 block.
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

-- Bit stream as in v1 aes50_aux_encoder:
--   * a packet starts when the UART has been idle for timeout_clks_i clocks
--     and bytes are waiting; it ends when the FIFO runs empty
--   * idle / delimiter: "0 111111111 0" (bit 0 first)
--   * payload bits LSB first, scrambled with s = d xor s[5] xor s[9]; the
--     scrambler is reset at the start of every Ethernet frame (aux word 0
--     and 44), the first bit of a frame is sent unscrambled
--   * a '0' is inserted after 8 consecutive '1' payload bits
--   * 16 bits per aux word, bit 0 first
-- Difference to v1: v1 loses the stuffing bit when the 8th '1' is the last
-- bit of a byte; here the stuffing bit is always inserted.
--
-- req_i starts a block of 44 (48k) / 88 (44.1k) words, written to the aux RAM
-- page req_page_i (aux_addr_o = page & word index); done_o pulses after the
-- last word.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aes50_aux_uart_enc is
	generic (
		G_FIFO_AW		: natural := 11			-- UART input FIFO: 2**G_FIFO_AW - 1 bytes
	);
	port (
		clk_i			: in  std_logic;		-- 50 MHz
		rst_i			: in  std_logic;

		uart_i			: in  std_logic;
		clks_per_bit_i	: in  natural range 0 to 65535;
		timeout_clks_i	: in  natural range 0 to 16777215;

		fs48_i			: in  std_logic;
		req_i			: in  std_logic;
		req_page_i		: in  std_logic;

		aux_we_o		: out std_logic;
		aux_addr_o		: out unsigned(7 downto 0);
		aux_data_o		: out std_logic_vector(15 downto 0);
		done_o			: out std_logic
	);
end entity;

architecture rtl of aes50_aux_uart_enc is

	type state_t is (S_DELIM, S_FETCH1, S_FETCH2, S_DATA, S_STUFF);

	-- UART input and FIFO
	signal uart_valid		: std_logic;
	signal uart_data		: std_logic_vector(7 downto 0);
	signal fifo_rd			: std_logic;
	signal fifo_data		: std_logic_vector(7 downto 0);
	signal fifo_empty		: std_logic;
	signal idle_cnt			: natural range 0 to 16777215;		-- clocks since the last UART byte
	signal ready_to_send	: std_logic;						-- UART idle long enough, bytes waiting

	-- bit stream generator
	signal state			: state_t;
	signal delim_bit		: natural range 0 to 10;			-- position in the delimiter
	signal byte_reg			: std_logic_vector(7 downto 0);
	signal byte_bit			: natural range 0 to 7;
	signal byte_done		: std_logic;						-- stuffing after the last bit of a byte
	signal ones_cnt			: natural range 0 to 7;				-- consecutive '1' payload bits
	signal scrambler		: std_logic_vector(8 downto 0);

	-- word assembly
	signal active			: std_logic;						-- a block is being generated
	signal page				: std_logic;
	signal word_shift		: std_logic_vector(15 downto 0);
	signal word_bit			: natural range 0 to 15;
	signal word_idx			: unsigned(6 downto 0);
	signal word_last		: unsigned(6 downto 0);

begin

	u_rx : entity work.aes50_uart_rx
		port map (clk_i => clk_i, rx_i => uart_i, clks_per_bit_i => clks_per_bit_i,
				  valid_o => uart_valid, data_o => uart_data);

	u_fifo : entity work.aes50_fifo
		generic map (G_AW => G_FIFO_AW, G_DW => 8)
		port map (clk_i => clk_i, rst_i => rst_i, wr_en_i => uart_valid, wr_data_i => uart_data,
				  rd_en_i => fifo_rd, rd_data_o => fifo_data, empty_o => fifo_empty, count_o => open);

	-- start a packet only after a UART pause
	process (clk_i)
	begin
		if rising_edge(clk_i) then
			if rst_i = '1' or uart_valid = '1' or fifo_empty = '1' then
				idle_cnt		<= 0;
				ready_to_send	<= '0';
			elsif idle_cnt < timeout_clks_i then
				idle_cnt <= idle_cnt + 1;
			else
				ready_to_send <= '1';
			end if;
		end if;
	end process;

	process (clk_i)
		variable nbit		: std_logic;		-- next bit of the aux stream
		variable valid		: boolean;			-- nbit is produced in this clock
		variable sbit		: std_logic;
		variable frame_start: boolean;			-- first bit of an Ethernet frame
	begin
		if rising_edge(clk_i) then
			aux_we_o	<= '0';
			done_o		<= '0';
			fifo_rd		<= '0';
			valid		:= false;
			nbit		:= '0';

			if req_i = '1' then
				active		<= '1';
				page		<= req_page_i;
				word_idx	<= (others => '0');
				word_bit	<= 0;
				if fs48_i = '1' then word_last <= to_unsigned(43, 7); else word_last <= to_unsigned(87, 7); end if;
			end if;

			frame_start := word_bit = 0 and (word_idx = 0 or word_idx = 44);

			if active = '1' then
				case state is
					when S_DELIM =>
						if delim_bit = 0 or delim_bit = 10 then nbit := '0'; else nbit := '1'; end if;
						valid := true;
						if delim_bit = 10 then
							delim_bit <= 0;
							if ready_to_send = '1' then
								state	<= S_FETCH1;
								fifo_rd	<= '1';
								byte_bit <= 0;
							end if;
						else
							delim_bit <= delim_bit + 1;
						end if;
						if frame_start then
							scrambler <= (others => '0');
						end if;

					when S_FETCH1 =>
						state <= S_FETCH2;
						if frame_start then
							scrambler <= (others => '0');
						end if;

					when S_FETCH2 =>
						byte_reg <= fifo_data;
						state	 <= S_DATA;
						if frame_start then
							scrambler <= (others => '0');
						end if;

					when S_DATA =>
						if frame_start then						-- first bit of a frame: unscrambled
							sbit		:= byte_reg(byte_bit);
							scrambler	<= "00000000" & sbit;
						else
							sbit		:= byte_reg(byte_bit) xor scrambler(4) xor scrambler(8);
							scrambler	<= scrambler(7 downto 0) & sbit;
						end if;
						nbit	:= sbit;
						valid	:= true;

						-- end of the byte: next byte or back to idle
						byte_done <= '0';
						if byte_bit = 7 then
							byte_bit <= 0;
						else
							byte_bit <= byte_bit + 1;
						end if;
						if sbit = '1' and ones_cnt = 7 then
							ones_cnt	<= 0;
							state		<= S_STUFF;
							if byte_bit = 7 then
								byte_done <= '1';
							end if;
						else
							if sbit = '1' then ones_cnt <= ones_cnt + 1; else ones_cnt <= 0; end if;
							if byte_bit = 7 then
								if fifo_empty = '1' or ready_to_send = '0' then
									state <= S_DELIM;
								else
									fifo_rd	<= '1';
									state	<= S_FETCH1;
								end if;
							end if;
						end if;

					when S_STUFF =>
						nbit		:= '0';
						valid		:= true;
						ones_cnt	<= 0;
						state		<= S_DATA;
						if byte_done = '1' then
							if fifo_empty = '1' or ready_to_send = '0' then
								state <= S_DELIM;
							else
								fifo_rd	<= '1';
								state	<= S_FETCH1;
							end if;
						end if;
						if frame_start then
							scrambler <= (others => '0');
						end if;
				end case;

				-- collect 16 bits per aux word (bit 0 first)
				if valid then
					if word_bit = 15 then
						aux_we_o	<= '1';
						aux_addr_o	<= page & word_idx;
						aux_data_o	<= nbit & word_shift(15 downto 1);
						word_bit	<= 0;
						if word_idx = word_last then
							active	<= '0';
							done_o	<= '1';
						else
							word_idx <= word_idx + 1;
						end if;
					else
						word_bit <= word_bit + 1;
					end if;
					word_shift <= nbit & word_shift(15 downto 1);
				end if;
			end if;

			if rst_i = '1' then
				state		<= S_DELIM;
				delim_bit	<= 0;
				ones_cnt	<= 0;
				byte_done	<= '0';
				active		<= '0';
				word_bit	<= 0;
				scrambler	<= (others => '0');
			end if;
		end if;
	end process;

end architecture;
