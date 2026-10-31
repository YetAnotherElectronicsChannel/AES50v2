-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE (v2)
-- File         : <aes50_rx_deframer.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
--
-- Description  : AES50 receive deframer.  Decodes the RMII stream on the fly
--                (one dibit per 50 MHz clock) and writes the received samples
--                directly into the sample RAM and the aux words into the aux
--                RAM.  Partly received sample pairs of a logical channel are
--                kept in a small context RAM between rows.
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

-- A block (6 samples at 48k = 1 frame, 11 samples at 44.1k = 2 frames) is
-- written to sample RAM address blk_base_o + 48*s + ch.  blk_done_o pulses
-- when a block is complete; blocks are only reported after the first frame
-- with ASSM flag has been seen (sync_o = '1').  Aux word j of a block is
-- written to aux address (block number mod 2) & j.
-- Parity blocks are not evaluated (no error correction, like v1).
--
-- Decoding is the mirror image of aes50_tx_framer: the position inside the
-- sample-pair chunk is tracked once per row, the received bits are shifted
-- into the channel a / channel b registers of the current LC.  A row ends in
-- the middle of a sample pair, so at the end of each block the partly
-- received pair is saved in the context RAM (one entry per LC) and restored
-- when the same LC comes again in the next row.  When the last bit of a pair
-- (b0) has been received, both samples are written to the sample RAM.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.aes50_pkg.all;

entity aes50_rx_deframer is
	generic (
		G_AW			: natural := 10			-- sample RAM address width
	);
	port (
		clk_i			: in  std_logic;		-- 50 MHz RMII clock
		rst_i			: in  std_logic;

		fs48_i			: in  std_logic;		-- '1' 48k, '0' 44.1k (static)

		rmii_crs_dv_i	: in  std_logic;
		rmii_rxd_i		: in  std_logic_vector(1 downto 0);

		ram_we_o		: out std_logic;
		ram_addr_o		: out unsigned(G_AW - 1 downto 0);
		ram_data_o		: out std_logic_vector(23 downto 0);

		aux_we_o		: out std_logic;
		aux_addr_o		: out unsigned(7 downto 0);		-- page & word
		aux_data_o		: out std_logic_vector(15 downto 0);

		blk_done_o		: out std_logic;
		blk_base_o		: out unsigned(G_AW - 1 downto 0);
		blk_page_o		: out std_logic;				-- aux page of the block
		blk_ok_o		: out std_logic;				-- all frames of the block had a good FCS
		blk_assm_o		: out std_logic;				-- block started with an ASSM frame

		frame_ok_o		: out std_logic;				-- pulse per frame with good FCS
		frame_err_o		: out std_logic;				-- pulse per frame with bad FCS / truncated
		sync_o			: out std_logic
	);
end entity;

architecture rtl of aes50_rx_deframer is

	type state_t is (S_IDLE, S_PREAMBLE, S_HEADER, S_PAYLOAD, S_FCS, S_SKIP);
	type pair_ctx_ram_t is array (0 to 31) of std_logic_vector(47 downto 0);

	-- RMII inputs registered (IO register)
	signal rx_dv_r				: std_logic;
	signal rxd_r				: std_logic_vector(1 downto 0);

	signal state				: state_t;
	signal step_cnt				: unsigned(12 downto 0);	-- dibit counter in header / FCS
	signal hdr_shift			: std_logic_vector(7 downto 0);	-- header octet being received
	signal header_ok			: std_logic;				-- EtherType, protocol and audio format match
	signal frame_assm			: std_logic;				-- ASSM flag of the current frame
	signal fcs_crc				: std_logic_vector(31 downto 0);
	signal fcs_ok				: std_logic;

	-- block bookkeeping
	signal synced				: std_logic;				-- an ASSM frame has been seen
	signal second_half			: std_logic;				-- 44.1k: second frame of the block
	signal block_base			: unsigned(G_AW - 1 downto 0);	-- RAM address of the block being received
	signal aux_page				: std_logic;				-- aux RAM page of the block being received
	signal block_ok				: std_logic;
	signal block_assm			: std_logic;

	-- payload position (same meaning as in aes50_tx_framer)
	signal dibit_idx			: unsigned(3 downto 0);
	signal block_idx			: unsigned(4 downto 0);
	signal row_idx				: unsigned(3 downto 0);
	signal row_sample			: unsigned(3 downto 0);
	signal row_bit				: unsigned(5 downto 0);
	signal next_row_sample		: unsigned(3 downto 0);
	signal next_row_bit			: unsigned(5 downto 0);
	signal chunk_bit			: unsigned(5 downto 0);
	signal use_pair1			: std_logic;
	signal bit0_idx				: unsigned(5 downto 0);
	signal bit1_idx				: unsigned(5 downto 0);
	signal row_addr				: unsigned(G_AW - 1 downto 0);	-- block_base + 48*row_sample (registered)
	signal ch_ofs				: unsigned(G_AW - 1 downto 0);	-- 2 * LC of the current block

	-- sample pair being assembled (channel a / b of the current LC) and the
	-- context RAM holding the partly received pair of every LC
	signal pair_a, pair_b		: std_logic_vector(23 downto 0);
	signal pair_ctx_ram			: pair_ctx_ram_t;
	signal ctx_rd_lc			: unsigned(4 downto 0);
	signal ctx_rd_data			: std_logic_vector(47 downto 0);

	-- sample RAM write sequence (channel a, then channel b)
	signal wr_step				: unsigned(1 downto 0);
	signal wr_addr				: unsigned(G_AW - 1 downto 0);
	signal wr_b_data			: std_logic_vector(23 downto 0);

	-- aux: LC24/LC25 bits of the row and the write sequence of 4 words
	signal aux_lc24				: std_logic_vector(31 downto 0);
	signal aux_lc25				: std_logic_vector(31 downto 0);
	signal aux_wr_left			: unsigned(2 downto 0);
	signal aux_word_addr		: unsigned(6 downto 0);
	signal aux_words			: std_logic_vector(63 downto 0);

	function chunk_len(fs48 : std_logic) return unsigned is
	begin
		if fs48 = '1' then return to_unsigned(58, 7); else return to_unsigned(64, 7); end if;
	end function;

	function mul48(s : unsigned(3 downto 0)) return unsigned is
		variable v : unsigned(G_AW + 5 downto 0) := resize(s, G_AW + 6);
	begin
		return resize(shift_left(v, 5) + shift_left(v, 4), G_AW);
	end function;

	-- RAM entries per block
	function block_size(fs48 : std_logic) return unsigned is
	begin
		if fs48 = '1' then return to_unsigned(288, G_AW); else return to_unsigned(528 mod 2 ** G_AW, G_AW); end if;
	end function;

	-- shift one received bit into the sample pair if it is an audio bit
	-- (stream index n: even = channel a, odd = channel b, >= 48 = U/C/M/pad)
	procedure shift_in_bit(n : in unsigned(5 downto 0); bitv : in std_logic;
						   a, b : inout std_logic_vector(23 downto 0)) is
	begin
		if n < 48 then
			if n(0) = '0' then
				a := a(22 downto 0) & bitv;
			else
				b := b(22 downto 0) & bitv;
			end if;
		end if;
	end procedure;

begin

	sync_o <= synced;

	-- context RAM read port (registered)
	process (clk_i)
	begin
		if rising_edge(clk_i) then
			ctx_rd_data <= pair_ctx_ram(to_integer(ctx_rd_lc));
		end if;
	end process;

	process (clk_i)
		variable new_chunk_bit	: unsigned(5 downto 0);
		variable bit_sum		: unsigned(6 downto 0);
		variable new_a, new_b	: std_logic_vector(23 downto 0);
		variable blk_kind		: natural range 0 to 4;
		variable next_block		: unsigned(4 downto 0);
		variable block_complete	: boolean;
		variable aux64			: std_logic_vector(63 downto 0);
		variable new_lc25		: std_logic_vector(31 downto 0);
	begin
		if rising_edge(clk_i) then

			rx_dv_r	<= rmii_crs_dv_i;
			rxd_r	<= rmii_rxd_i;

			ram_we_o		<= '0';
			aux_we_o		<= '0';
			blk_done_o		<= '0';
			frame_ok_o		<= '0';
			frame_err_o		<= '0';
			block_complete	:= false;

			case state is

				-- ------------------------------------------------------------
				when S_IDLE =>
					if rx_dv_r = '1' and rxd_r = "01" then
						state <= S_PREAMBLE;
					end if;

				when S_PREAMBLE =>
					if rx_dv_r = '0' then
						state <= S_IDLE;
					elsif rxd_r = "11" then					-- SFD
						state		<= S_HEADER;
						step_cnt	<= (others => '0');
						fcs_crc		<= (others => '1');
						header_ok	<= '1';
						frame_assm	<= '0';
					elsif rxd_r /= "01" then
						state <= S_IDLE;
					end if;

				-- ------------------------------------------------------------
				when S_HEADER =>							-- 22 octets = 88 dibits
					fcs_crc		<= crc32_d2(fcs_crc, rxd_r);
					hdr_shift	<= rxd_r & hdr_shift(7 downto 2);
					step_cnt	<= step_cnt + 1;
					if step_cnt(1 downto 0) = "11" then		-- octet complete: rxd_r & hdr_shift(7..2)
						case to_integer(step_cnt(6 downto 2)) is
							when 12 => if rxd_r & hdr_shift(7 downto 2) /= x"88" then header_ok <= '0'; end if;
							when 13 => if rxd_r & hdr_shift(7 downto 2) /= x"DD" then header_ok <= '0'; end if;
							when 14 => if rxd_r & hdr_shift(7 downto 2) /= x"01" then header_ok <= '0'; end if;
							when 17 =>						-- frame type / flags
								if (rxd_r & hdr_shift(7 downto 2)) = x"11" then
									frame_assm <= '1';
								end if;
							when 18 =>						-- audio format must match fs_mode
								if (fs48_i = '1' and (rxd_r & hdr_shift(7 downto 2)) /= x"46") or
								   (fs48_i = '0' and (rxd_r & hdr_shift(7 downto 2)) /= x"06") then
									header_ok <= '0';
								end if;
							when others => null;
						end case;
					end if;

					if step_cnt = 85 then					-- start position of rows 0 and 1
						row_idx		<= (others => '0');
						block_idx	<= (others => '0');
						dibit_idx	<= (others => '0');
						-- 44.1k: second frame of a block (row 11 = chunk 5, bit 32) unless this is an ASSM frame
						if fs48_i = '0' and second_half = '1' and frame_assm = '0' then
							row_sample	<= to_unsigned(5, 4);
							row_bit		<= to_unsigned(32, 6);
							bit_sum		:= to_unsigned(64, 7);
						else
							row_sample	<= (others => '0');
							row_bit		<= (others => '0');
							bit_sum		:= to_unsigned(32, 7);
						end if;
						if bit_sum >= chunk_len(fs48_i) then
							next_row_bit <= resize(bit_sum - chunk_len(fs48_i), 6);
							if fs48_i = '0' and second_half = '1' and frame_assm = '0' then
								next_row_sample <= to_unsigned(6, 4);
							else
								next_row_sample <= to_unsigned(1, 4);
							end if;
						else
							next_row_bit	<= resize(bit_sum, 6);
							next_row_sample	<= (others => '0');
						end if;
						ctx_rd_lc <= (others => '0');		-- context of LC0
					end if;

					if step_cnt = 87 then
						step_cnt <= (others => '0');
						if header_ok = '0' then
							state <= S_SKIP;
						else
							state <= S_PAYLOAD;
							if frame_assm = '1' then			-- an ASSM frame starts a block
								synced		<= '1';
								second_half	<= '0';
							end if;
							if frame_assm = '1' or fs48_i = '1' or second_half = '0' then
								block_ok	<= '1';
								block_assm	<= frame_assm;
							end if;
							new_chunk_bit	:= row_bit;
							chunk_bit		<= new_chunk_bit;
							bit0_idx		<= chunk_index(new_chunk_bit, fs48_i);
							bit1_idx		<= chunk_index(new_chunk_bit + 1, fs48_i);
							use_pair1		<= '0';
							ch_ofs			<= (others => '0');
							if fs48_i = '0' and second_half = '1' and frame_assm = '0' then
								aux_word_addr <= to_unsigned(44, 7);
							else
								aux_word_addr <= (others => '0');
							end if;
						end if;
					end if;

				-- ------------------------------------------------------------
				when S_PAYLOAD =>
					fcs_crc  <= crc32_d2(fcs_crc, rxd_r);
					blk_kind := block_kind(block_idx);

					if dibit_idx = 0 and blk_kind = K_AUDIO then	-- continue the LC's sample pair
						new_a := ctx_rd_data(47 downto 24);
						new_b := ctx_rd_data(23 downto 0);
					else
						new_a := pair_a;
						new_b := pair_b;
					end if;

					if blk_kind = K_AUDIO then
						shift_in_bit(bit0_idx, rxd_r(0), new_a, new_b);
						shift_in_bit(bit1_idx, rxd_r(1), new_a, new_b);
						-- sample pair complete (b0 received): start the two writes
						if (bit0_idx = 47 or bit1_idx = 47) and synced = '1' then
							wr_step <= "01";
							if use_pair1 = '1' then
								wr_addr <= row_addr + 48 + ch_ofs;
							else
								wr_addr <= row_addr + ch_ofs;
							end if;
							ram_data_o	<= new_a;
							wr_b_data	<= new_b;
						end if;
					end if;
					pair_a <= new_a;
					pair_b <= new_b;

					if blk_kind = K_AUX_EVEN then
						aux_lc24 <= rxd_r & aux_lc24(31 downto 2);
					end if;
					new_lc25 := rxd_r & aux_lc25(31 downto 2);
					if blk_kind = K_AUX_ODD then
						aux_lc25 <= new_lc25;
					end if;

					-- advance the position inside the sample-pair chunk
					if resize(chunk_bit, 7) + 2 = chunk_len(fs48_i) then
						new_chunk_bit	:= (others => '0');
						use_pair1		<= '1';
					else
						new_chunk_bit	:= chunk_bit + 2;
					end if;

					-- read the context of the next block's LC
					if dibit_idx = 14 then
						if block_idx = 31 then
							next_block := (others => '0');
						else
							next_block := block_idx + 1;
						end if;
						ctx_rd_lc <= block_lc(next_block);
					end if;

					-- end of block
					dibit_idx <= dibit_idx + 1;
					if dibit_idx = 15 then
						if blk_kind = K_AUDIO then				-- save the partly received pair
							pair_ctx_ram(to_integer(block_lc(block_idx))) <= new_a & new_b;
						end if;
						if blk_kind = K_AUX_ODD then			-- 4 aux words of this row are complete
							for i in 0 to 31 loop
								aux64(2 * i)		:= aux_lc24(i);
								aux64(2 * i + 1)	:= new_lc25(i);
							end loop;
							aux_words	<= aux64;
							aux_wr_left	<= "100";
						end if;
						new_chunk_bit	:= row_bit;
						use_pair1		<= '0';
						if block_idx = 31 then
							block_idx <= (others => '0');
							if row_idx = 10 then
								state		<= S_FCS;
								step_cnt	<= (others => '0');
								fcs_ok		<= '1';
							else
								row_idx			<= row_idx + 1;
								row_sample		<= next_row_sample;
								row_bit			<= next_row_bit;
								new_chunk_bit	:= next_row_bit;
								bit_sum := resize(next_row_bit, 7) + 32;
								if bit_sum >= chunk_len(fs48_i) then
									next_row_bit	<= resize(bit_sum - chunk_len(fs48_i), 6);
									next_row_sample	<= next_row_sample + 1;
								else
									next_row_bit	<= resize(bit_sum, 6);
								end if;
							end if;
							ch_ofs <= (others => '0');
						else
							block_idx	<= block_idx + 1;
							ch_ofs		<= resize(block_lc(block_idx + 1) & '0', G_AW);
						end if;
					end if;
					chunk_bit	<= new_chunk_bit;
					bit0_idx	<= chunk_index(new_chunk_bit, fs48_i);
					bit1_idx	<= chunk_index(new_chunk_bit + 1, fs48_i);

					if rx_dv_r = '0' and dibit_idx(0) = '1' then	-- carrier lost inside the frame
						state		<= S_IDLE;
						frame_err_o	<= '1';
						block_ok	<= '0';
					end if;

				-- ------------------------------------------------------------
				when S_FCS =>								-- compare with the computed CRC
					if rxd_r /= not fcs_crc(1 downto 0) then
						fcs_ok <= '0';
					end if;
					fcs_crc  <= "00" & fcs_crc(31 downto 2);
					step_cnt <= step_cnt + 1;
					if step_cnt = 15 then
						state <= S_SKIP;
						if rxd_r = not fcs_crc(1 downto 0) and fcs_ok = '1' then
							frame_ok_o <= '1';
						else
							frame_err_o	<= '1';
							block_ok	<= '0';
						end if;
						if fs48_i = '1' or second_half = '1' then
							block_complete := true;
						end if;
						second_half <= not second_half;
					end if;

				-- ------------------------------------------------------------
				when S_SKIP =>								-- wait for the end of the carrier
					if rx_dv_r = '0' then
						state <= S_IDLE;
					end if;

			end case;

			-- report a complete block, then continue in the ring / next aux page
			if block_complete and synced = '1' then
				blk_done_o	<= '1';
				blk_base_o	<= block_base;
				blk_page_o	<= aux_page;
				blk_assm_o	<= block_assm;
				if fcs_ok = '0' or rxd_r /= not fcs_crc(1 downto 0) then
					blk_ok_o <= '0';
				else
					blk_ok_o <= block_ok;
				end if;
				block_base	<= block_base + block_size(fs48_i);
				aux_page	<= not aux_page;
			end if;

			-- sample RAM writes: channel a at wr_addr, channel b at wr_addr + 1
			case wr_step is
				when "01" =>
					ram_we_o	<= '1';
					ram_addr_o	<= wr_addr;
					wr_step		<= "10";
				when "10" =>
					ram_we_o	<= '1';
					ram_addr_o	<= wr_addr + 1;
					ram_data_o	<= wr_b_data;
					wr_step		<= "00";
				when others => null;
			end case;

			-- aux RAM writes: 4 words per row
			if aux_wr_left /= 0 then
				if synced = '1' then
					aux_we_o <= '1';
				end if;
				aux_addr_o		<= aux_page & aux_word_addr;
				aux_data_o		<= aux_words(15 downto 0);
				aux_words		<= x"0000" & aux_words(63 downto 16);
				aux_word_addr	<= aux_word_addr + 1;
				aux_wr_left		<= aux_wr_left - 1;
			end if;

			row_addr <= block_base + mul48(row_sample);

			if rst_i = '1' then
				state		<= S_IDLE;
				synced		<= '0';
				second_half	<= '0';
				block_base	<= (others => '0');
				aux_page	<= '0';
				wr_step		<= "00";
				aux_wr_left	<= "000";
			end if;
		end if;
	end process;

end architecture;
