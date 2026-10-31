-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE (v2)
-- File         : <aes50_tx_framer.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
--
-- Description  : AES50 transmit framer.  Generates the complete RMII stream
--                (preamble, header, payload, FCS) on the fly, one dibit per
--                50 MHz clock, directly from the sample RAM.  Parity blocks
--                are accumulated while the data blocks are sent, so no frame
--                buffer and no extra processing passes are needed.
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

-- One start_i pulse sends one sample block: 6 samples at 48k (one frame) or
-- 11 samples at 44.1k (two frames, the second G_HALF_GAP clocks after the
-- first).  Sample s of channel ch is read from RAM address
-- base_i + 48*s + ch.  Aux word j of the block (0..43 / 0..87) is read from
-- aux_addr_o = j; if aux_valid_i is '0' the idle pattern is sent instead.
-- Both RAMs must have a registered read port (one clock latency).
--
-- How the payload is produced (see aes50_pkg for the format):
--   The payload is sent row by row (11 rows per frame), each row block by
--   block (32 blocks), each block as 16 dibits (32 bits).  A data block of
--   row r carries the 32 bits [32*r .. 32*r+31] of the bit stream of one
--   logical channel (LC).  Inside that stream every sample pair (channel a
--   and b of the LC) occupies one "chunk" of 58 bits (48k) or 64 bits
--   (44.1k).  All LCs have the same layout, so the start position of a row
--   (chunk number + bit position inside the chunk) is the same for all its
--   blocks and is tracked once per row.  A 32-bit block word touches at most
--   two chunks, i.e. two sample pairs, which are read from the RAM while the
--   previous block is being sent.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.aes50_pkg.all;

entity aes50_tx_framer is
	generic (
		G_AW			: natural := 10;		-- sample RAM address width
		G_HALF_GAP		: natural := 450		-- 44.1k: idle clocks between the two frames (48..511)
	);
	port (
		clk_i			: in  std_logic;		-- 50 MHz RMII clock
		rst_i			: in  std_logic;

		fs48_i			: in  std_logic;		-- '1' 48k, '0' 44.1k (static)
		i2s_i			: in  std_logic;		-- '1': only channels 0/1 are used, the others are sent as 0

		start_i			: in  std_logic;		-- sample block complete
		base_i			: in  unsigned(G_AW - 1 downto 0);
		assm_i			: in  std_logic;		-- set ASSM flag in (first) frame header
		aux_valid_i		: in  std_logic;
		busy_o			: out std_logic;
		frame_o			: out std_logic;		-- pulse at the start of each frame

		ram_addr_o		: out unsigned(G_AW - 1 downto 0);
		ram_data_i		: in  std_logic_vector(23 downto 0);

		aux_addr_o		: out unsigned(6 downto 0);
		aux_data_i		: in  std_logic_vector(15 downto 0);

		rmii_txd_o		: out std_logic_vector(1 downto 0);
		rmii_tx_en_o	: out std_logic
	);
end entity;

architecture rtl of aes50_tx_framer is

	type state_t is (S_IDLE, S_PREAMBLE, S_HEADER, S_PAYLOAD, S_FCS, S_GAP);
	type parity_acc_t is array (0 to 4) of std_logic_vector(31 downto 0);

	signal state				: state_t;
	signal step_cnt				: unsigned(8 downto 0);		-- dibit counter in preamble/header/FCS, clock counter in the gap
	signal second_half			: std_logic;				-- 44.1k: second frame of the block is being sent
	signal block_base			: unsigned(G_AW - 1 downto 0);	-- RAM address of sample 0 / channel 0 of the block
	signal assm_flag			: std_logic;
	signal aux_valid			: std_logic;

	-- payload position
	signal dibit_idx			: unsigned(3 downto 0);		-- dibit within the block (0..15)
	signal block_idx			: unsigned(4 downto 0);		-- block within the row (0..31)
	signal row_idx				: unsigned(3 downto 0);		-- row within the frame (0..10)
	signal row_sample			: unsigned(3 downto 0);		-- sample pair (chunk) in which the current row starts
	signal row_bit				: unsigned(5 downto 0);		-- bit position of the row start inside that chunk
	signal next_row_sample		: unsigned(3 downto 0);		-- the same for the following row
	signal next_row_bit			: unsigned(5 downto 0);

	-- block being sent: bit position inside the chunk and the two sample pairs
	-- the block word can touch (pair 0 = chunk row_sample, pair 1 = the next one)
	signal chunk_bit			: unsigned(5 downto 0);
	signal use_pair1			: std_logic;				-- the chunk boundary has been crossed
	signal bit0_idx				: unsigned(5 downto 0);		-- index in the interleaved pair stream of the
	signal bit1_idx				: unsigned(5 downto 0);		-- first / second bit of the current dibit (63 = pad)
	signal cur_a0, cur_b0		: std_logic_vector(23 downto 0);	-- pair 0: channel a / b
	signal cur_a1, cur_b1		: std_logic_vector(23 downto 0);	-- pair 1: channel a / b

	-- sample fetch for the next block (4 RAM reads, done while the current block is sent)
	signal fetch_a0, fetch_b0	: std_logic_vector(23 downto 0);
	signal fetch_a1, fetch_b1	: std_logic_vector(23 downto 0);
	signal fetch_step			: unsigned(2 downto 0);		-- 0 = idle, 1..6 = read sequence
	signal fetch_addr			: unsigned(G_AW - 1 downto 0);	-- RAM address of channel a of pair 0
	signal fetch_ch_ofs			: unsigned(G_AW - 1 downto 0);	-- 2 * LC = offset of channel a
	signal fetch_beyond_end		: std_logic;				-- 48k: pair 1 lies behind the last sample (pad bits)
	signal fetch_mute			: std_logic;				-- I2S mode: LC1..23 carry no audio
	signal row_addr				: unsigned(G_AW - 1 downto 0);	-- block_base + 48*row_sample      (registered)
	signal next_row_addr		: unsigned(G_AW - 1 downto 0);	-- block_base + 48*next_row_sample (registered)

	-- aux bits of the current row (64 bits: LC24 = even bits, LC25 = odd bits)
	signal aux_lc24				: std_logic_vector(31 downto 0);
	signal aux_lc25				: std_logic_vector(31 downto 0);
	signal aux_load_step		: unsigned(5 downto 0);		-- 0 = idle, 1.. = load sequence
	signal aux_word_addr		: unsigned(6 downto 0);
	signal idle_phase			: unsigned(3 downto 0);		-- position in the 11-bit idle delimiter

	-- parity accumulators: one 32-bit word per parity block, rotated by one
	-- dibit per clock so that the dibit for the current position is at (1..0)
	signal parity_acc			: parity_acc_t;				-- blocks 15/23/27/29/30
	signal global_acc			: std_logic_vector(31 downto 0);	-- block 31

	-- output stage: out_kind/out_dibit are produced by the state machine, the
	-- following register stage drives RMII and updates the CRC
	constant OUT_IDLE			: std_logic_vector(1 downto 0) := "00";
	constant OUT_PREAMBLE		: std_logic_vector(1 downto 0) := "01";	-- preamble/SFD, CRC preset
	constant OUT_DATA			: std_logic_vector(1 downto 0) := "10";	-- header/payload, CRC update
	constant OUT_FCS			: std_logic_vector(1 downto 0) := "11";
	signal out_kind				: std_logic_vector(1 downto 0);
	signal out_dibit			: std_logic_vector(1 downto 0);
	signal fcs_crc				: std_logic_vector(31 downto 0);

	-- length of one sample-pair chunk in the LC bit stream
	function chunk_len(fs48 : std_logic) return unsigned is
	begin
		if fs48 = '1' then return to_unsigned(58, 7); else return to_unsigned(64, 7); end if;
	end function;

	function even_bits(w : std_logic_vector(15 downto 0)) return std_logic_vector is
		variable r : std_logic_vector(7 downto 0);
	begin
		for i in 0 to 7 loop r(i) := w(2 * i); end loop;
		return r;
	end function;

	function odd_bits(w : std_logic_vector(15 downto 0)) return std_logic_vector is
		variable r : std_logic_vector(7 downto 0);
	begin
		for i in 0 to 7 loop r(i) := w(2 * i + 1); end loop;
		return r;
	end function;

	-- 48 * s, address arithmetic modulo the RAM size
	function mul48(s : unsigned(3 downto 0)) return unsigned is
		variable v : unsigned(G_AW + 5 downto 0) := resize(s, G_AW + 6);
	begin
		return resize(shift_left(v, 5) + shift_left(v, 4), G_AW);
	end function;

	-- phase of the 11-bit idle pattern, advanced by n
	function phase_add(ph : unsigned(3 downto 0); n : natural) return unsigned is
		variable v : natural := to_integer(ph) + n;
	begin
		if v >= 11 then v := v - 11; end if;
		return to_unsigned(v, 4);
	end function;

begin

	busy_o <= '0' when state = S_IDLE else '1';

	process (clk_i)
		variable blk_kind			: natural range 0 to 4;
		variable dibit				: std_logic_vector(1 downto 0);
		variable new_chunk_bit		: unsigned(5 downto 0);
		variable fetch_sample		: unsigned(3 downto 0);		-- chunk (sample) number of the fetched pair 0
		variable pair_a, pair_b		: std_logic_vector(23 downto 0);
		variable parity_sel			: natural range 0 to 4;		-- accumulator of the current parity block
		variable hdr_octet			: std_logic_vector(7 downto 0);
		variable hdr_dibit			: std_logic_vector(1 downto 0);
		variable bit_sum			: unsigned(6 downto 0);
		variable fetch_block		: unsigned(4 downto 0);		-- block whose samples are fetched
		variable fetch_row_addr		: unsigned(G_AW - 1 downto 0);
		variable start_fetch		: boolean;
		variable start_aux_load		: boolean;
		variable aux_row			: unsigned(4 downto 0);		-- absolute row (0..21) for the aux word address
	begin
		if rising_edge(clk_i) then

			frame_o			<= '0';
			start_fetch		:= false;
			start_aux_load	:= false;

			case state is

				-- ------------------------------------------------------------
				when S_IDLE =>
					out_kind <= OUT_IDLE;
					if start_i = '1' then
						block_base	<= base_i;
						assm_flag	<= assm_i;
						aux_valid	<= aux_valid_i;
						second_half	<= '0';
						state		<= S_PREAMBLE;
						step_cnt	<= (others => '0');
					end if;

				-- ------------------------------------------------------------
				when S_PREAMBLE =>							-- 7x 0x55 + 0xD5
					out_kind <= OUT_PREAMBLE;
					if step_cnt = 0 then
						frame_o <= '1';
					end if;
					if step_cnt = 31 then
						out_dibit	<= "11";
						state		<= S_HEADER;
						step_cnt	<= (others => '0');
					else
						out_dibit	<= "01";
						step_cnt	<= step_cnt + 1;
					end if;

				-- ------------------------------------------------------------
				when S_HEADER =>							-- 22 octets = 88 dibits
					hdr_octet := hdr_byte(to_integer(step_cnt(6 downto 2)), fs48_i, assm_flag and not second_half);
					hdr_dibit := hdr_octet(2 * to_integer(step_cnt(1 downto 0)) + 1 downto 2 * to_integer(step_cnt(1 downto 0)));
					out_kind	<= OUT_DATA;
					out_dibit	<= hdr_dibit;

					-- the header time is used to prepare the payload
					if step_cnt = 0 then						-- start position of row 0
						row_idx		<= (others => '0');
						block_idx	<= (others => '0');
						dibit_idx	<= (others => '0');
						idle_phase	<= (others => '0');
						if fs48_i = '0' and second_half = '1' then	-- 44.1k second frame starts with row 11
							row_sample	<= to_unsigned(5, 4);		-- bit 352 = chunk 5, bit 32
							row_bit		<= to_unsigned(32, 6);
						else
							row_sample	<= (others => '0');
							row_bit		<= (others => '0');
						end if;
					end if;
					if step_cnt = 1 then						-- start position of row 1
						bit_sum := resize(row_bit, 7) + 32;
						if bit_sum >= chunk_len(fs48_i) then
							next_row_bit	<= resize(bit_sum - chunk_len(fs48_i), 6);
							next_row_sample	<= row_sample + 1;
						else
							next_row_bit	<= resize(bit_sum, 6);
							next_row_sample	<= row_sample;
						end if;
					end if;
					if step_cnt = 8 then
						start_aux_load := true;					-- aux bits of row 0
					end if;
					if step_cnt = 70 then						-- samples of block 0 / row 0
						start_fetch		:= true;
						fetch_block		:= (others => '0');
						fetch_row_addr	:= row_addr;
						fetch_sample	:= row_sample;
					end if;

					if step_cnt = 87 then
						state			<= S_PAYLOAD;
						new_chunk_bit	:= row_bit;
						chunk_bit		<= new_chunk_bit;
						bit0_idx		<= chunk_index(new_chunk_bit, fs48_i);
						bit1_idx		<= chunk_index(new_chunk_bit + 1, fs48_i);
						use_pair1		<= '0';
						cur_a0 <= fetch_a0; cur_b0 <= fetch_b0; cur_a1 <= fetch_a1; cur_b1 <= fetch_b1;
					end if;
					step_cnt <= step_cnt + 1;

				-- ------------------------------------------------------------
				when S_PAYLOAD =>
					blk_kind := block_kind(block_idx);
					if use_pair1 = '0' then
						pair_a := cur_a0; pair_b := cur_b0;
					else
						pair_a := cur_a1; pair_b := cur_b1;
					end if;
					-- a parity block has exactly one '0' in its block number: that
					-- bit position selects the accumulator
					parity_sel := 0;
					for k in 0 to 4 loop
						if block_idx(k) = '0' then parity_sel := k; end if;
					end loop;

					case blk_kind is
						when K_AUDIO	=> dibit := pair_bit(pair_a, pair_b, bit1_idx) & pair_bit(pair_a, pair_b, bit0_idx);
						when K_AUX_EVEN	=> dibit := aux_lc24(1 downto 0);
						when K_AUX_ODD	=> dibit := aux_lc25(1 downto 0);
						when K_PARITY	=> dibit := not parity_acc(parity_sel)(1 downto 0);
						when others		=> dibit := not global_acc(1 downto 0);
					end case;

					out_kind	<= OUT_DATA;
					out_dibit	<= dibit;

					-- parity accumulators: a data block contributes to every parity
					-- block whose '0' bit is also '0' in the data block number;
					-- block 0 starts the accumulation of a new row
					for k in 0 to 4 loop
						if (blk_kind = K_AUDIO or blk_kind = K_AUX_EVEN or blk_kind = K_AUX_ODD) and block_idx(k) = '0' then
							if block_idx = 0 then
								parity_acc(k) <= dibit & parity_acc(k)(31 downto 2);
							else
								parity_acc(k) <= (parity_acc(k)(1 downto 0) xor dibit) & parity_acc(k)(31 downto 2);
							end if;
						else
							parity_acc(k) <= parity_acc(k)(1 downto 0) & parity_acc(k)(31 downto 2);
						end if;
					end loop;
					-- global parity: all blocks 0..30, including the parity blocks
					if block_idx = 0 then
						global_acc <= dibit & global_acc(31 downto 2);
					elsif block_idx /= 31 then
						global_acc <= (global_acc(1 downto 0) xor dibit) & global_acc(31 downto 2);
					else
						global_acc <= global_acc(1 downto 0) & global_acc(31 downto 2);
					end if;

					if blk_kind = K_AUX_EVEN then
						aux_lc24 <= "00" & aux_lc24(31 downto 2);
					end if;
					if blk_kind = K_AUX_ODD then
						aux_lc25 <= "00" & aux_lc25(31 downto 2);
					end if;

					-- advance the position inside the sample-pair chunk
					if resize(chunk_bit, 7) + 2 = chunk_len(fs48_i) then
						new_chunk_bit	:= (others => '0');
						use_pair1		<= '1';
					else
						new_chunk_bit	:= chunk_bit + 2;
					end if;

					-- fetch the samples of the next block, started at the second
					-- dibit of a block (row_addr follows row_sample one clock later)
					if dibit_idx = 1 and not (block_idx = 31 and row_idx = 10) then
						start_fetch := true;
						if block_idx = 31 then
							fetch_block		:= (others => '0');
							fetch_row_addr	:= next_row_addr;
							fetch_sample	:= next_row_sample;
						else
							fetch_block		:= block_idx + 1;
							fetch_row_addr	:= row_addr;
							fetch_sample	:= row_sample;
						end if;
					end if;

					-- end of block: switch to the fetched samples, next block / row
					dibit_idx <= dibit_idx + 1;
					if dibit_idx = 15 then
						new_chunk_bit	:= row_bit;
						use_pair1		<= '0';
						cur_a0 <= fetch_a0; cur_b0 <= fetch_b0; cur_a1 <= fetch_a1; cur_b1 <= fetch_b1;
						if block_idx = 31 then
							block_idx <= (others => '0');
							if row_idx = 10 then
								state		<= S_FCS;
								step_cnt	<= (others => '0');
							else
								row_idx			<= row_idx + 1;
								row_sample		<= next_row_sample;
								row_bit			<= next_row_bit;
								new_chunk_bit	:= next_row_bit;
								start_aux_load	:= true;
								bit_sum := resize(next_row_bit, 7) + 32;
								if bit_sum >= chunk_len(fs48_i) then
									next_row_bit	<= resize(bit_sum - chunk_len(fs48_i), 6);
									next_row_sample	<= next_row_sample + 1;
								else
									next_row_bit	<= resize(bit_sum, 6);
								end if;
							end if;
						else
							block_idx <= block_idx + 1;
						end if;
					end if;
					chunk_bit	<= new_chunk_bit;
					bit0_idx	<= chunk_index(new_chunk_bit, fs48_i);
					bit1_idx	<= chunk_index(new_chunk_bit + 1, fs48_i);

				-- ------------------------------------------------------------
				when S_FCS =>								-- 4 octets = 16 dibits
					out_kind <= OUT_FCS;
					if step_cnt = 15 then
						step_cnt	<= (others => '0');
						state		<= S_GAP;
					else
						step_cnt <= step_cnt + 1;
					end if;

				-- ------------------------------------------------------------
				when S_GAP =>								-- inter-frame gap
					out_kind <= OUT_IDLE;
					step_cnt <= step_cnt + 1;
					if fs48_i = '0' and second_half = '0' then
						if step_cnt = G_HALF_GAP - 1 then	-- 44.1k: second frame of the block
							second_half	<= '1';
							step_cnt	<= (others => '0');
							state		<= S_PREAMBLE;
						end if;
					elsif step_cnt = 47 then				-- 12 octets minimum
						state <= S_IDLE;
					end if;

			end case;

			-- ----------------------------------------------------------------
			-- sample fetch: 4 reads (channel a/b of pair 0 and pair 1), the
			-- data arrives two clocks after the address is set; the address sum
			-- is split over two clocks to keep the path short
			if start_fetch then
				fetch_step		<= to_unsigned(1, 3);
				fetch_addr		<= fetch_row_addr;
				fetch_ch_ofs	<= resize(block_lc(fetch_block) & '0', G_AW);
				if i2s_i = '1' and block_lc(fetch_block) /= 0 then
					fetch_mute <= '1';
				else
					fetch_mute <= '0';
				end if;
				-- 48k: the chunk after sample 5 is the 4-bit pad at the end of the LC segment
				if fs48_i = '1' and fetch_sample = 5 then
					fetch_beyond_end <= '1';
				else
					fetch_beyond_end <= '0';
				end if;
			elsif fetch_step /= 0 then
				fetch_step <= fetch_step + 1;
				case to_integer(fetch_step) is
					when 1		=> ram_addr_o <= fetch_addr + fetch_ch_ofs;		-- pair 0, channel a
								   fetch_addr <= fetch_addr + fetch_ch_ofs;
					when 2		=> ram_addr_o <= fetch_addr + 1;				-- pair 0, channel b
					when 3		=> ram_addr_o <= fetch_addr + 48;				-- pair 1, channel a
								   fetch_a0 <= ram_data_i;
					when 4		=> ram_addr_o <= fetch_addr + 49;				-- pair 1, channel b
								   fetch_b0 <= ram_data_i;
					when 5		=> fetch_a1 <= ram_data_i;
					when 6		=> fetch_b1 <= ram_data_i;
								   fetch_step <= (others => '0');
								   if fetch_beyond_end = '1' then
									   fetch_a1 <= (others => '0');
									   fetch_b1 <= (others => '0');
								   end if;
								   if fetch_mute = '1' then
									   fetch_a0 <= (others => '0'); fetch_b0 <= (others => '0');
									   fetch_a1 <= (others => '0'); fetch_b1 <= (others => '0');
								   end if;
					when others	=> null;
				end case;
			end if;

			row_addr		<= block_base + mul48(row_sample);
			next_row_addr	<= block_base + mul48(next_row_sample);

			-- ----------------------------------------------------------------
			-- aux bits of a row: 4 words from the aux RAM or 64 idle bits,
			-- split into the even (LC24) and odd (LC25) bits
			if start_aux_load then
				aux_load_step	<= to_unsigned(1, 6);
				aux_row			:= resize(row_idx, 5);
				if state = S_PAYLOAD then					-- row_idx is advanced in this clock
					aux_row := aux_row + 1;
				end if;
				if fs48_i = '0' and second_half = '1' then	-- 44.1k second frame: rows 11..21
					aux_row := aux_row + 11;
				end if;
				aux_word_addr <= shift_left(resize(aux_row, 7), 2);
			elsif aux_load_step /= 0 then
				aux_load_step <= aux_load_step + 1;
				if aux_valid = '1' then
					-- steps 1..4 set the address, steps 3..6 take the data
					case to_integer(aux_load_step) is
						when 1 | 2 | 3 | 4 =>
							aux_addr_o		<= aux_word_addr;
							aux_word_addr	<= aux_word_addr + 1;
						when others => null;
					end case;
					if aux_load_step >= 3 and aux_load_step <= 6 then
						aux_lc24 <= even_bits(aux_data_i) & aux_lc24(31 downto 8);
						aux_lc25 <= odd_bits(aux_data_i) & aux_lc25(31 downto 8);
					end if;
					if aux_load_step = 6 then
						aux_load_step <= (others => '0');
					end if;
				else
					-- idle pattern, 2 bits per clock
					aux_lc24	<= aux_idle_bit(idle_phase) & aux_lc24(31 downto 1);
					aux_lc25	<= aux_idle_bit(phase_add(idle_phase, 1)) & aux_lc25(31 downto 1);
					idle_phase	<= phase_add(idle_phase, 2);
					if aux_load_step = 32 then
						aux_load_step <= (others => '0');
					end if;
				end if;
			end if;

			-- ----------------------------------------------------------------
			-- output register stage
			case out_kind is
				when OUT_PREAMBLE =>
					rmii_tx_en_o	<= '1';
					rmii_txd_o		<= out_dibit;
					fcs_crc			<= (others => '1');
				when OUT_DATA =>
					rmii_tx_en_o	<= '1';
					rmii_txd_o		<= out_dibit;
					fcs_crc			<= crc32_d2(fcs_crc, out_dibit);
				when OUT_FCS =>
					rmii_tx_en_o	<= '1';
					rmii_txd_o		<= not fcs_crc(1 downto 0);
					fcs_crc			<= "00" & fcs_crc(31 downto 2);
				when others =>
					rmii_tx_en_o	<= '0';
					rmii_txd_o		<= "00";
			end case;

			if rst_i = '1' then
				state			<= S_IDLE;
				out_kind		<= OUT_IDLE;
				rmii_tx_en_o	<= '0';
				rmii_txd_o		<= "00";
				fetch_step		<= (others => '0');
				aux_load_step	<= (others => '0');
			end if;
		end if;
	end process;

end architecture;
