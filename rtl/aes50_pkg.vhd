-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE (v2)
-- File         : <aes50_pkg.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
--
-- Description  : Shared constants and helper functions of the AES50 v2 core:
--                frame header, block/LC mapping, payload bit layout, CRC32
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

-- Payload organisation (one Ethernet frame):
--   11 rows x 32 blocks x 32 bit, sent row by row, block by block, LSB first.
--   Blocks 15/23/27/29/30 are parity (XNOR of all earlier blocks of the row
--   whose block number has a '0' at the parity's single '0' bit position),
--   block 31 is the XNOR of blocks 0..30.  The others carry logical channels
--   LC0..LC25 in ascending order (LC0..23 audio, LC24/25 aux).
--   One RMII dibit = 2 consecutive bits of the 32-bit block word.
--
-- Bit layout of one audio LC (pair of channels a = 2*lc, b = 2*lc+1):
--   interleaved stream I(n): a23 b23 a22 b22 ... a0 b0 ua0 ub0 ua1 ub1 ua2 ub2
--   split in two 27-bit sub-segments; each sub-segment is sent as its first
--   26 bits, then the pad bits, then its 27th bit (layout of X32/DL32/Wing
--   devices, verified against captures).  Pad = 2 bits at 48k (58-bit chunk
--   per sample pair, 6 pairs + 4 pad bits per 352-bit LC segment) and 5 bits
--   at 44.1k (64-bit chunk, 11 pairs per two Ethernet frames).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package aes50_pkg is

	-- block kinds
	constant K_AUDIO		: natural := 0;
	constant K_AUX_EVEN		: natural := 1;		-- block 26 (LC24)
	constant K_AUX_ODD		: natural := 2;		-- block 28 (LC25)
	constant K_PARITY		: natural := 3;
	constant K_GLOBAL		: natural := 4;

	function block_kind(blk : unsigned(4 downto 0)) return natural;
	-- logical channel carried by a data block (only valid for K_AUDIO)
	function block_lc(blk : unsigned(4 downto 0)) return unsigned;

	-- header octet i (0..21: dest, src, ethertype, protocol id, user octet, format id)
	function hdr_byte(i : natural; fs48 : std_logic; assm : std_logic) return std_logic_vector;

	-- position q inside a sample-pair chunk -> index n of the interleaved
	-- stream (0..53), or 63 for pad bits
	function chunk_index(q : unsigned(5 downto 0); fs48 : std_logic) return unsigned;

	-- one bit of a sample pair, selected by interleaved stream index n
	-- (n >= 48 are the U/C/M bits which are always sent as '0')
	function pair_bit(a, b : std_logic_vector(23 downto 0); n : unsigned(5 downto 0)) return std_logic;

	-- Ethernet CRC32 (reflected, poly 0xEDB88320), two bits per call, d(0) first
	function crc32_d2(crc : std_logic_vector(31 downto 0); d : std_logic_vector(1 downto 0)) return std_logic_vector;

	-- idle pattern of the aux channel: delimiters "0 111111111 0", bit phase 0..10
	function aux_idle_bit(ph : unsigned(3 downto 0)) return std_logic;

end package;

package body aes50_pkg is

	function block_kind(blk : unsigned(4 downto 0)) return natural is
	begin
		case to_integer(blk) is
			when 15 | 23 | 27 | 29 | 30	=> return K_PARITY;
			when 31						=> return K_GLOBAL;
			when 26						=> return K_AUX_EVEN;
			when 28						=> return K_AUX_ODD;
			when others					=> return K_AUDIO;
		end case;
	end function;

	function block_lc(blk : unsigned(4 downto 0)) return unsigned is
		variable b : natural := to_integer(blk);
	begin
		case b is
			when 0 to 14	=> return to_unsigned(b, 5);
			when 16 to 22	=> return to_unsigned(b - 1, 5);
			when 24 | 25	=> return to_unsigned(b - 2, 5);
			when others		=> return to_unsigned(0, 5);
		end case;
	end function;

	function hdr_byte(i : natural; fs48 : std_logic; assm : std_logic) return std_logic_vector is
	begin
		case i is
			when 0		=> return x"02";			-- destination MAC 02:00:00:00:00:00
			when 12		=> return x"88";			-- EtherType 0x88DD (AES)
			when 13		=> return x"DD";
			when 14		=> return x"01";			-- protocol identifier
			when 16		=> return x"31";			-- protocol version 3.1
			when 17		=> if assm = '1' then return x"11"; else return x"01"; end if;	-- frame type / ASSM flag
			when 18		=> if fs48 = '1' then return x"46"; else return x"06"; end if;	-- 24 bit PCM, 48k / 44.1k
			when 21		=>						-- CRC-8 over octets 16..20
				if fs48 = '1' then
					if assm = '1' then return x"AA"; else return x"1A"; end if;
				else
					if assm = '1' then return x"7C"; else return x"CC"; end if;
				end if;
			when others	=> return x"00";			-- source MAC, user octet, structure, reserved
		end case;
	end function;

	function chunk_index(q : unsigned(5 downto 0); fs48 : std_logic) return unsigned is
		variable v : natural := to_integer(q);
	begin
		if fs48 = '1' then							-- 58-bit chunk, 2 pad bits
			case v is
				when 0 to 25	=> return to_unsigned(v, 6);
				when 28			=> return to_unsigned(26, 6);
				when 29 to 54	=> return to_unsigned(v - 2, 6);
				when 57			=> return to_unsigned(53, 6);
				when others		=> return to_unsigned(63, 6);
			end case;
		else										-- 64-bit chunk, 5 pad bits
			case v is
				when 0 to 25	=> return to_unsigned(v, 6);
				when 31			=> return to_unsigned(26, 6);
				when 32 to 57	=> return to_unsigned(v - 5, 6);
				when 63			=> return to_unsigned(53, 6);
				when others		=> return to_unsigned(63, 6);
			end case;
		end if;
	end function;

	function pair_bit(a, b : std_logic_vector(23 downto 0); n : unsigned(5 downto 0)) return std_logic is
		variable idx : natural;
	begin
		if n >= 48 then
			return '0';
		end if;
		idx := 23 - to_integer(n(5 downto 1));
		if n(0) = '0' then
			return a(idx);
		else
			return b(idx);
		end if;
	end function;

	function crc32_d2(crc : std_logic_vector(31 downto 0); d : std_logic_vector(1 downto 0)) return std_logic_vector is
		constant POLY	: std_logic_vector(31 downto 0) := x"EDB88320";
		variable c		: std_logic_vector(31 downto 0) := crc;
		variable fb		: std_logic;
	begin
		for i in 0 to 1 loop
			fb := c(0) xor d(i);
			c  := '0' & c(31 downto 1);
			if fb = '1' then
				c := c xor POLY;
			end if;
		end loop;
		return c;
	end function;

	function aux_idle_bit(ph : unsigned(3 downto 0)) return std_logic is
	begin
		if ph = 0 or ph = 10 then
			return '0';
		else
			return '1';
		end if;
	end function;

end package body;
