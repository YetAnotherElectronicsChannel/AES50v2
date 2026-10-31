-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE (v2)
-- File         : <aes50_clk_audio.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
--
-- Description  : Everything clocked by the 1024*fs audio clock: AES50 sync
--                signal generator (64*fs with ASSM phase indicator), ASSM
--                detection on the received sync signal, MCLK/BCLK/WCLK
--                generation for TDM8/I2S master mode.
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

-- Same behaviour as the PLL-clock process of the v1 aes50_clockmanager:
--   sync output: 16 clocks per 64*fs period, high for 8 clocks; every 2048
--   samples one short (6/16) and one long (10/16) pulse mark the ASSM.
--   sys_mode "10" (TDM slave): the ASSM is aligned to the rising WCLK edge
--   (re-aligned on the first 1023 WCLK edges after reset).
--   assm_*_tgl_o toggle once per ASSM (self generated / received).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aes50_clk_audio is
	generic (
		G_ASSM_SAMPLES		: natural := 2048		-- samples between two ASSM (only reduced for simulation)
	);
	port (
		clk_i				: in  std_logic;		-- 1024 * fs from the PLL
		rst_i				: in  std_logic;		-- asynchronous

		sys_mode_i			: in  std_logic_vector(1 downto 0);
		i2s_i				: in  std_logic;

		aes_clk_in_i		: in  std_logic;		-- received sync signal (after MDI/MDI-X selection)
		aes_clk_gen_o		: out std_logic;		-- generated sync signal
		assm_self_tgl_o		: out std_logic;
		assm_remote_tgl_o	: out std_logic;

		wclk_readback_i		: in  std_logic;
		mclk_o				: out std_logic;		-- 256 * fs
		bclk_o				: out std_logic;
		wclk_o				: out std_logic
	);
end entity;

architecture rtl of aes50_clk_audio is

	-- sync signal generator: 16 PLL clocks per 64*fs period
	signal sync_phase			: unsigned(3 downto 0);		-- position inside the 64*fs period
	signal sync_period_cnt		: unsigned(16 downto 0);	-- 64*fs periods, wraps every 2048 samples
	signal assm_hold_cnt		: unsigned(3 downto 0);		-- stretches the ASSM start (v1 timing)
	signal assm_armed			: std_logic;				-- ASSM requested, pulses not finished yet
	signal assm_pulse			: unsigned(1 downto 0);		-- 0 normal, 1 short pulse, 2 long pulse
	signal assm_self_toggle		: std_logic;

	-- ASSM detection on the received sync signal (long high time)
	signal sync_in_samples		: std_logic_vector(2 downto 0);	-- last 3 samples: synchronizer + edge detector
	signal sync_in_high_cnt		: unsigned(6 downto 0);		-- length of the current high phase
	signal sync_in_high			: std_logic;
	signal assm_remote_toggle	: std_logic;

	-- sys_mode "10": alignment of the ASSM to the external WCLK
	signal wclk_samples			: std_logic_vector(2 downto 0);	-- last 3 samples: synchronizer + edge detector
	signal wclk_align_left		: unsigned(9 downto 0);		-- remaining re-alignments after reset

	-- MCLK / BCLK / WCLK generator (master mode)
	signal tdm_bclk_phase		: unsigned(1 downto 0);		-- 4 PLL clocks per BCLK (also MCLK)
	signal tdm_wclk_phase		: unsigned(9 downto 0);		-- 1024 PLL clocks per frame
	signal i2s_bclk_phase		: unsigned(3 downto 0);		-- 16 PLL clocks per BCLK
	signal i2s_wclk_phase		: unsigned(9 downto 0);

begin

	assm_self_tgl_o		<= assm_self_toggle;
	assm_remote_tgl_o	<= assm_remote_toggle;

	process (clk_i, rst_i)
	begin
		if rst_i = '1' then
			sync_phase			<= (others => '0');
			sync_period_cnt		<= to_unsigned(2, 17);
			assm_armed			<= '0';
			assm_pulse			<= "00";
			assm_hold_cnt		<= (others => '0');
			assm_self_toggle	<= '0';
			assm_remote_toggle	<= '0';
			sync_in_high_cnt	<= (others => '0');
			sync_in_high		<= '0';
			wclk_align_left		<= to_unsigned(1023, 10);
			aes_clk_gen_o		<= '0';
			tdm_bclk_phase		<= (others => '0');		-- start phases as in v1
			tdm_wclk_phase		<= to_unsigned(2, 10);
			i2s_bclk_phase		<= (others => '0');
			i2s_wclk_phase		<= to_unsigned(8, 10);
			mclk_o				<= '0';
			bclk_o				<= '0';
			wclk_o				<= '0';

		elsif rising_edge(clk_i) then
			-- (the input synchronizers sync_in_samples / wclk_samples are not reset, like v1)

			-- -------------------------------------------- received ASSM: high phase > 8/16
			sync_in_samples <= sync_in_samples(1 downto 0) & aes_clk_in_i;
			if sync_in_samples(2 downto 1) = "01" then			-- rising edge
				sync_in_high_cnt	<= (others => '0');
				sync_in_high		<= '1';
			elsif sync_in_samples(2 downto 1) = "10" then		-- falling edge
				if sync_in_high_cnt > 8 then
					assm_remote_toggle <= not assm_remote_toggle;
				end if;
				sync_in_high <= '0';
			elsif sync_in_high = '1' and sync_in_high_cnt /= 127 then
				sync_in_high_cnt <= sync_in_high_cnt + 1;
			end if;

			-- -------------------------------------------- self generated ASSM
			sync_phase <= sync_phase + 1;
			-- once per 64*fs period: count periods, align to WCLK in TDM slave mode
			if sync_phase = 15 then
				if i2s_i = '0' then
					wclk_samples <= wclk_samples(1 downto 0) & wclk_readback_i;
				else										-- I2S: left channel starts with WCLK low
					wclk_samples <= wclk_samples(1 downto 0) & not wclk_readback_i;
				end if;
				if sys_mode_i(1) = '1' and wclk_align_left /= 0 and wclk_samples(2 downto 1) = "01" then
					sync_period_cnt	<= (others => '0');
					wclk_align_left	<= wclk_align_left - 1;
				else
					if sync_period_cnt = G_ASSM_SAMPLES * 64 - 1 then
						sync_period_cnt <= (others => '0');
					else
						sync_period_cnt	<= sync_period_cnt + 1;
					end if;
				end if;
			end if;

			-- ASSM every 2048 samples: request one short and one long pulse
			if (sys_mode_i = "01" or (sys_mode_i(1) = '1' and wclk_align_left = 0)) and
			   sync_period_cnt = 0 and sync_phase = 0 then
				assm_hold_cnt		<= to_unsigned(10, 4);
				assm_self_toggle	<= not assm_self_toggle;
			elsif assm_hold_cnt /= 0 then
				assm_hold_cnt	<= assm_hold_cnt - 1;
				assm_armed		<= '1';
			elsif assm_pulse = 2 and assm_armed = '1' and sync_phase = 15 then
				assm_armed		<= '0';
			end if;

			-- pulse sequence: normal -> short -> long -> normal
			if sync_phase = 0 and assm_armed = '1' and assm_pulse = 0 then
				assm_pulse <= "01";
			elsif sync_phase = 0 and assm_armed = '1' and assm_pulse = 1 then
				assm_pulse <= "10";
			elsif sync_phase = 15 and assm_pulse = 2 then
				assm_pulse <= "00";
			end if;

			-- short pulse 6/16, long pulse 10/16, normal 8/16
			if assm_pulse = 1 then
				if sync_phase < 6 then aes_clk_gen_o <= '1'; else aes_clk_gen_o <= '0'; end if;
			elsif assm_pulse = 2 then
				if sync_phase < 10 then aes_clk_gen_o <= '1'; else aes_clk_gen_o <= '0'; end if;
			else
				if sync_phase < 8 then aes_clk_gen_o <= '1'; else aes_clk_gen_o <= '0'; end if;
			end if;

			-- -------------------------------------------- MCLK / BCLK / WCLK
			tdm_bclk_phase <= tdm_bclk_phase + 1;
			if tdm_bclk_phase < 2 then mclk_o <= '1'; else mclk_o <= '0'; end if;
			if i2s_i = '0' then
				tdm_wclk_phase <= tdm_wclk_phase + 1;
				if tdm_wclk_phase < 32 then wclk_o <= '1'; else wclk_o <= '0'; end if;
				if tdm_bclk_phase < 2 then bclk_o <= '1'; else bclk_o <= '0'; end if;
			else
				i2s_bclk_phase	<= i2s_bclk_phase + 1;
				i2s_wclk_phase	<= i2s_wclk_phase + 1;
				if i2s_wclk_phase < 512 then wclk_o <= '0'; else wclk_o <= '1'; end if;
				if i2s_bclk_phase < 8 then bclk_o <= '1'; else bclk_o <= '0'; end if;
			end if;
		end if;
	end process;

end architecture;
