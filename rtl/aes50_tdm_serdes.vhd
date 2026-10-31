-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE (v2)
-- File         : <aes50_tdm_serdes.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
--
-- Description  : TDM8 (6x audio + 1x aux line) / I2S serializer and
--                deserializer, clocked directly by BCLK.  Writes the received
--                samples into the TX sample RAM, plays the RX sample RAM out
--                and forms the sample blocks of the AES50 frames.
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

-- Naming: "TX" / "RX" always refer to the AES50 direction.  The TDM inputs
-- feed the AES50 transmitter (TX sample RAM), the TDM outputs are fed from the
-- AES50 receiver (RX sample RAM).
--
-- Serial format (both modes): 32-bit slots, 24-bit sample MSB first, 8 zero
-- bits; data is launched on the falling and captured on the rising BCLK edge.
--   TDM8 : 256 BCLK per frame, frame starts with the rising WCLK edge.  The
--          MSB of slot 0 is captured G_FSYNC_DELAY BCLKs after the first
--          rising BCLK edge that sees WCLK high (0 = original IP, 1 = OpenX32).
--          Channel = line * 8 + slot.  Line 6 carries aux words:
--          bits 23..8 aux word, bit 7 valid, bits 6..0 word index.
--   I2S  : 64 BCLK per frame, left channel (ch 0) while WCLK is low, right
--          channel (ch 1) while WCLK is high, MSB one BCLK after the WCLK edge.
--
-- Schedule within each slot (slot_bit = bit position 0..31 at the capturing
-- rising edge):
--   0..23   shift the sample bits in / out
--   24..29  write the 6 received samples (TX sample RAM)
--   30      aux word of the slot (TX aux RAM)
--   22..28  read the 6 samples + aux word of the next slot (RX RAMs); the
--           data arrives two clocks later and is loaded at 24..30
--
-- Blocks: N = 6 (48k) or 11 (44.1k) consecutive frames form one AES50 sample
-- block.  After tx_en_i is set, the first block starts N + G_TX_LEAD_ADJ
-- frames before the frame that follows the next ASSM event, so that the block
-- with the ASSM flag ends at the ASSM (G_TX_LEAD_ADJ = 0).  Every completed
-- block toggles tx_blk_tgl_o (tx_base_o / tx_assm_o stay valid until the
-- next toggle).
-- Received blocks (rx_blk_tgl_i, rx_base_i, rx_page_i) are played out starting
-- with the first frame that begins after the block was reported.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aes50_tdm_serdes is
	generic (
		G_AW			: natural := 10;		-- sample RAM address width (TX and RX)
		G_FSYNC_DELAY	: natural := 0;			-- TDM: BCLKs from WCLK edge to MSB of slot 0
		G_TX_LEAD_ADJ	: integer := 0;			-- frames, shifts the block alignment against the ASSM
		G_ASSM_FRAMES	: natural := 2048		-- frames between two ASSM (only reduced for simulation)
	);
	port (
		bclk_i				: in  std_logic;
		wclk_i				: in  std_logic;
		rst_i				: in  std_logic;	-- synchronous to bclk_i

		fs48_i				: in  std_logic;
		i2s_i				: in  std_logic;	-- '1' I2S (2x2), '0' TDM8 (48x48)

		tdm_i				: in  std_logic_vector(6 downto 0);
		tdm_o				: out std_logic_vector(6 downto 0);

		-- TX sample RAM and TX aux RAM (write ports; aux address = page & word)
		tx_ram_we_o			: out std_logic;
		tx_ram_addr_o		: out unsigned(G_AW - 1 downto 0);
		tx_ram_data_o		: out std_logic_vector(23 downto 0);
		tx_aux_we_o			: out std_logic;
		tx_aux_addr_o		: out unsigned(8 downto 0);	-- 4 pages of 128 words
		tx_aux_data_o		: out std_logic_vector(15 downto 0);

		-- RX sample RAM and RX aux RAM (read ports, one clock latency)
		rx_ram_addr_o		: out unsigned(G_AW - 1 downto 0);
		rx_ram_data_i		: in  std_logic_vector(23 downto 0);
		rx_aux_addr_o		: out unsigned(7 downto 0);
		rx_aux_data_i		: in  std_logic_vector(15 downto 0);

		-- block handshakes (toggles, data stable while the toggle is pending)
		tx_en_i				: in  std_logic;	-- asynchronous level
		assm_tgl_i			: in  std_logic;	-- asynchronous toggle per ASSM
		tx_blk_tgl_o		: out std_logic;
		tx_base_o			: out unsigned(G_AW - 1 downto 0);
		tx_assm_o			: out std_logic;
		tx_aux_tgl_o		: out std_logic;	-- a complete aux page was received over TDM
		tx_aux_page_o		: out unsigned(1 downto 0);	-- page being written (the completed one is page - 1)

		rx_blk_tgl_i		: in  std_logic;	-- asynchronous toggle per received block
		rx_base_i			: in  unsigned(G_AW - 1 downto 0);
		rx_page_i			: in  std_logic;

		playing_o			: out std_logic		-- RX blocks are being played out
	);
end entity;

architecture rtl of aes50_tdm_serdes is

	type line_words_t is array (0 to 6) of std_logic_vector(23 downto 0);

	-- synchronizers for the asynchronous control inputs
	signal tx_en_sync			: std_logic_vector(1 downto 0);
	signal assm_sync			: std_logic_vector(2 downto 0);
	signal rx_blk_sync			: std_logic_vector(2 downto 0);
	signal wclk_prev			: std_logic;

	-- frame position: bit_pos is the position (0..255 TDM, 0..63 I2S) of the
	-- bit that is captured at the next rising edge
	signal bit_pos				: unsigned(7 downto 0);
	signal framed				: std_logic;				-- a frame sync has been seen

	-- one 24-bit shift register per TDM line and direction
	signal tdm_in_shift			: line_words_t;
	signal tdm_out_shift		: line_words_t;
	signal tdm_out_bit			: std_logic_vector(6 downto 0);	-- registered on the falling edge

	-- TX block forming
	signal frames_since_assm	: unsigned(10 downto 0);
	signal assm_pending			: std_logic;
	signal tx_aligned			: std_logic;				-- ASSM seen while enabled, waiting for the block start
	signal tx_active			: std_logic;				-- blocks are being formed
	signal tx_frame_in_block	: unsigned(3 downto 0);
	signal tx_block_cnt			: unsigned(10 downto 0);	-- for the ASSM flag (every 1024 / 2048 blocks)
	signal tx_frame_addr		: unsigned(G_AW - 1 downto 0);	-- RAM address of the current frame
	signal tx_block_addr		: unsigned(G_AW - 1 downto 0);	-- RAM address of the current block
	signal tx_blk_toggle		: std_logic;
	signal tx_aux_page			: unsigned(1 downto 0);		-- round robin over 4 pages, so a page is
																-- not overwritten while the framer sends it
	signal tx_aux_toggle		: std_logic;

	-- RX playout: the block reported by the receiver waits in rx_pending_* until
	-- the next frame starts; *_cur describe the frame being played, *_next the
	-- following frame (decided before its first slot is read)
	signal rx_pending			: std_logic;
	signal rx_pending_base		: unsigned(G_AW - 1 downto 0);
	signal rx_pending_page		: std_logic;
	signal play_active_cur		: std_logic;
	signal play_addr_cur		: unsigned(G_AW - 1 downto 0);
	signal play_frame_cur		: unsigned(3 downto 0);	-- frame within the block
	signal play_page_cur		: std_logic;
	signal play_active_next		: std_logic;
	signal play_addr_next		: unsigned(G_AW - 1 downto 0);
	signal play_frame_next		: unsigned(3 downto 0);
	signal play_page_next		: std_logic;
	signal out_active			: std_logic;				-- the slot being loaded belongs to a played block
	signal out_aux_idx			: unsigned(6 downto 0);
	signal out_aux_valid		: std_logic;

	-- index of the last frame of a block (N - 1)
	function last_frame_idx(fs48 : std_logic) return unsigned is
	begin
		if fs48 = '1' then return to_unsigned(5, 4); else return to_unsigned(10, 4); end if;
	end function;

	-- aux words per block
	function aux_words(fs48 : std_logic) return unsigned is
	begin
		if fs48 = '1' then return to_unsigned(44, 7); else return to_unsigned(88, 7); end if;
	end function;

begin

	tx_blk_tgl_o	<= tx_blk_toggle;
	tx_aux_tgl_o	<= tx_aux_toggle;
	tx_aux_page_o	<= tx_aux_page;
	playing_o		<= play_active_cur;

	-- output register on the falling edge
	process (bclk_i)
	begin
		if falling_edge(bclk_i) then
			tdm_o <= tdm_out_bit;
		end if;
	end process;

	process (bclk_i)
		variable cap_pos		: unsigned(7 downto 0);		-- position of the bit captured now
		variable next_pos		: unsigned(7 downto 0);
		variable last_pos		: unsigned(7 downto 0);
		variable slot_bit		: unsigned(4 downto 0);
		variable slot			: unsigned(2 downto 0);
		variable next_slot		: unsigned(2 downto 0);
		variable line			: natural range 0 to 7;
		variable frame_start	: boolean;
		variable aux_idx		: unsigned(6 downto 0);
		variable rd_frame_addr	: unsigned(G_AW - 1 downto 0);	-- frame of the slot being read
		variable rd_frame_idx	: unsigned(3 downto 0);
		variable rd_page		: std_logic;
		variable rd_active		: std_logic;
	begin
		if rising_edge(bclk_i) then

			tx_en_sync	<= tx_en_sync(0) & tx_en_i;
			assm_sync	<= assm_sync(1 downto 0) & assm_tgl_i;
			rx_blk_sync	<= rx_blk_sync(1 downto 0) & rx_blk_tgl_i;
			wclk_prev	<= wclk_i;

			tx_ram_we_o <= '0';
			tx_aux_we_o <= '0';

			if i2s_i = '1' then
				last_pos := to_unsigned(63, 8);
			else
				last_pos := to_unsigned(255, 8);
			end if;

			-- ---------------------------------------------------- framing
			if (i2s_i = '0' and wclk_i = '1' and wclk_prev = '0') or (i2s_i = '1' and wclk_i = '0' and wclk_prev = '1') then
				framed <= '1';
			end if;
			if i2s_i = '0' and wclk_i = '1' and wclk_prev = '0' then		-- TDM: rising WCLK edge
				if G_FSYNC_DELAY = 0 then
					cap_pos := (others => '0');
				else
					cap_pos := last_pos - to_unsigned(G_FSYNC_DELAY - 1, 8);
				end if;
			elsif i2s_i = '1' and wclk_i = '0' and wclk_prev = '1' then	-- I2S: falling WCLK edge,
				cap_pos := last_pos;										-- MSB one BCLK later
			else
				cap_pos := bit_pos;
			end if;
			if cap_pos = last_pos then
				next_pos := (others => '0');
			else
				next_pos := cap_pos + 1;
			end if;
			bit_pos		<= next_pos;
			slot_bit	:= cap_pos(4 downto 0);
			slot		:= cap_pos(7 downto 5);
			frame_start	:= (cap_pos = 0);

			-- ---------------------------------------------------- input
			if slot_bit <= 23 then
				for i in 0 to 6 loop
					tdm_in_shift(i) <= tdm_in_shift(i)(22 downto 0) & tdm_i(i);
				end loop;
			end if;

			-- ---------------------------------------------------- frame / block bookkeeping
			if assm_sync(2) /= assm_sync(1) then
				assm_pending <= '1';
			end if;
			if frame_start then
				frames_since_assm <= frames_since_assm + 1;
				if assm_pending = '1' then					-- this frame is the ASSM frame
					assm_pending		<= '0';
					frames_since_assm	<= (others => '0');
					if tx_en_sync(1) = '1' and framed = '1' then
						tx_aligned <= '1';
					end if;
				end if;
				-- TX: next frame of the block / next block / first block
				if tx_active = '1' then
					if tx_frame_in_block = last_frame_idx(fs48_i) then
						tx_frame_in_block	<= (others => '0');
						tx_block_addr		<= tx_frame_addr + 48;
						tx_block_cnt		<= tx_block_cnt + 1;
					else
						tx_frame_in_block <= tx_frame_in_block + 1;
					end if;
					tx_frame_addr <= tx_frame_addr + 48;
				elsif tx_aligned = '1' and
					  frames_since_assm = to_unsigned(G_ASSM_FRAMES - 2 - G_TX_LEAD_ADJ, 11) - last_frame_idx(fs48_i) then
					-- frames_since_assm is the index (relative to the ASSM frame) of the frame that ends now
					tx_active			<= '1';
					tx_frame_in_block	<= (others => '0');
					tx_block_cnt		<= (others => '0');
					tx_frame_addr		<= tx_frame_addr + 48;
					tx_block_addr		<= tx_frame_addr + 48;
				end if;
				-- RX playout: the next-frame context becomes current
				play_active_cur	<= play_active_next;
				play_addr_cur	<= play_addr_next;
				play_frame_cur	<= play_frame_next;
				play_page_cur	<= play_page_next;
			end if;
			if tx_en_sync(1) = '0' then					-- has priority over a block start
				tx_aligned	<= '0';
				tx_active	<= '0';
			end if;

			-- ---------------------------------------------------- TX sample writes
			if slot_bit >= 24 and slot_bit <= 29 and tx_active = '1' then
				line := to_integer(slot_bit) - 24;
				if i2s_i = '0' or (line = 0 and slot <= 1) then
					tx_ram_we_o <= '1';
					if i2s_i = '1' then
						tx_ram_addr_o <= tx_frame_addr + resize(slot, G_AW);
					else
						tx_ram_addr_o <= tx_frame_addr + to_unsigned(line * 8, G_AW) + resize(slot, G_AW);
					end if;
					tx_ram_data_o <= tdm_in_shift(line);
				end if;
				-- last write of the block: publish base address and ASSM flag
				if line = 5 and slot = 7 and tx_frame_in_block = last_frame_idx(fs48_i) then
					tx_base_o <= tx_block_addr;
					if fs48_i = '1' then
						if tx_block_cnt(9 downto 0) = 0 then tx_assm_o <= '1'; else tx_assm_o <= '0'; end if;
					else
						if tx_block_cnt(10 downto 0) = 0 then tx_assm_o <= '1'; else tx_assm_o <= '0'; end if;
					end if;
				end if;
			end if;
			-- block complete (TDM: end of slot 7 of the last frame)
			if slot_bit = 31 and slot = 7 and tx_active = '1' and tx_frame_in_block = last_frame_idx(fs48_i) then
				tx_blk_toggle <= not tx_blk_toggle;
			end if;
			-- block complete (I2S: end of the right channel of the last frame)
			if i2s_i = '1' and slot_bit = 31 and slot = 1 and cap_pos = 63 and tx_active = '1' and
			   tx_frame_in_block = last_frame_idx(fs48_i) then
				tx_base_o		<= tx_block_addr;
				tx_blk_toggle	<= not tx_blk_toggle;
				if (fs48_i = '1' and tx_block_cnt(9 downto 0) = 0) or (fs48_i = '0' and tx_block_cnt = 0) then
					tx_assm_o <= '1';
				else
					tx_assm_o <= '0';
				end if;
			end if;

			-- aux words received over TDM (line 6), stored by their word index
			if slot_bit = 30 and i2s_i = '0' and framed = '1' then
				aux_idx := unsigned(tdm_in_shift(6)(6 downto 0));
				if tdm_in_shift(6)(7) = '1' and aux_idx < aux_words(fs48_i) then
					tx_aux_we_o		<= '1';
					tx_aux_addr_o	<= tx_aux_page & aux_idx;
					tx_aux_data_o	<= tdm_in_shift(6)(23 downto 8);
					if aux_idx = aux_words(fs48_i) - 1 then		-- last word: the page is complete
						tx_aux_page		<= tx_aux_page + 1;
						tx_aux_toggle	<= not tx_aux_toggle;
					end if;
				end if;
			end if;

			-- ---------------------------------------------------- RX playout
			if rx_blk_sync(2) /= rx_blk_sync(1) then
				rx_pending		<= '1';
				rx_pending_base	<= rx_base_i;
				rx_pending_page	<= rx_page_i;
			end if;

			-- decide what the next frame plays, before its first slot is read
			if cap_pos = last_pos - 16 then
				if play_active_cur = '1' and play_frame_cur /= last_frame_idx(fs48_i) then
					play_active_next	<= '1';					-- continue the current block
					play_addr_next		<= play_addr_cur + 48;
					play_frame_next		<= play_frame_cur + 1;
					play_page_next		<= play_page_cur;
				elsif rx_pending = '1' then
					play_active_next	<= '1';					-- start the reported block
					play_addr_next		<= rx_pending_base;
					play_frame_next		<= (others => '0');
					play_page_next		<= rx_pending_page;
					rx_pending			<= '0';
				else
					play_active_next	<= '0';					-- nothing to play: output zeros
				end if;
			end if;

			-- read the samples and the aux word of the next slot
			if slot = last_pos(7 downto 5) then
				next_slot		:= (others => '0');
				rd_frame_addr	:= play_addr_next;
				rd_frame_idx	:= play_frame_next;
				rd_page			:= play_page_next;
				rd_active		:= play_active_next;
			else
				next_slot		:= slot + 1;
				rd_frame_addr	:= play_addr_cur;
				rd_frame_idx	:= play_frame_cur;
				rd_page			:= play_page_cur;
				rd_active		:= play_active_cur;
			end if;
			if slot_bit = 22 then
				out_active <= rd_active;
			end if;
			if slot_bit >= 22 and slot_bit <= 27 then
				line := to_integer(slot_bit) - 22;
				if i2s_i = '1' then
					rx_ram_addr_o <= rd_frame_addr + resize(next_slot, G_AW);
				else
					rx_ram_addr_o <= rd_frame_addr + to_unsigned(line * 8, G_AW) + resize(next_slot, G_AW);
				end if;
			end if;
			if slot_bit = 28 then
				-- aux word index: 8 words per frame (one per slot), 44 / 88 per block
				aux_idx			:= resize(rd_frame_idx * 8, 7) + resize(next_slot, 7);
				rx_aux_addr_o	<= rd_page & aux_idx;
				out_aux_idx		<= aux_idx;
				if rd_active = '1' and aux_idx < aux_words(fs48_i) and i2s_i = '0' then
					out_aux_valid <= '1';
				else
					out_aux_valid <= '0';
				end if;
			end if;

			-- ---------------------------------------------------- output
			-- bit for position next_pos, driven on the following falling edge;
			-- the shift registers are reloaded while the 8 pad bits are sent
			if slot_bit <= 22 or slot_bit = 31 then
				for i in 0 to 6 loop
					tdm_out_bit(i)		<= tdm_out_shift(i)(23);
					tdm_out_shift(i)	<= tdm_out_shift(i)(22 downto 0) & '0';
				end loop;
			else
				tdm_out_bit <= (others => '0');
			end if;
			if slot_bit >= 24 and slot_bit <= 29 then
				line := to_integer(slot_bit) - 24;
				if out_active = '1' and (i2s_i = '0' or line = 0) then
					tdm_out_shift(line) <= rx_ram_data_i;
				else
					tdm_out_shift(line) <= (others => '0');
				end if;
			end if;
			if slot_bit = 30 then
				if out_aux_valid = '1' then
					tdm_out_shift(6) <= rx_aux_data_i & '1' & std_logic_vector(out_aux_idx);
				else
					tdm_out_shift(6) <= (others => '0');
				end if;
			end if;
			if i2s_i = '1' then
				tdm_out_bit(6 downto 1) <= (others => '0');
			end if;

			if rst_i = '1' then
				bit_pos				<= (others => '0');
				framed				<= '0';
				frames_since_assm	<= (others => '0');
				assm_pending		<= '0';
				tx_aligned			<= '0';
				tx_active			<= '0';
				tx_frame_addr		<= (others => '0');
				tx_blk_toggle		<= '0';
				tx_aux_page			<= (others => '0');
				tx_aux_toggle		<= '0';
				rx_pending			<= '0';
				play_active_cur		<= '0';
				play_active_next	<= '0';
				tdm_out_bit			<= (others => '0');
			end if;
		end if;
	end process;

end architecture;
