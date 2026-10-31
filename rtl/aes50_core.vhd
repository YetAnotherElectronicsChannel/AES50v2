-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE (v2)
-- File         : <aes50_core.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
--
-- Description  : AES50 IP Core (v2).  Instantiated by aes50_top (same ports
--                as v1 except clk100_i) or by a project specific wrapper.
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

-- sys_mode_i : "00" AES50 slave  / TDM master
--              "01" AES50 master / TDM master
--              "10" AES50 master / TDM slave ("11" behaves like "10")
-- fs_mode_i  : "00" 44.1k, "01" 48k
--
-- Clock domains:
--   clk50_i                 RMII, TX framer, RX deframer, aux UART, link supervision
--   clk_1024xfs_from_pll_i  AES50 sync signal, MCLK/BCLK/WCLK generation
--   bclk_readback_i         TDM/I2S serializer / deserializer
-- They only exchange data through dual-clock RAMs and toggle handshakes.
--
-- Changes of the port semantics against v1:
--   * rst_i may be asynchronous (it is synchronized internally)
--   * all timer values (debug_out_signal_pulse_len_i, wd_*, mdix_timer_*,
--     aes_clk_ok_counter_reference_i, uart_*) count 50 MHz clocks, i.e. half
--     of the v1 values
--   * first_transmit_start_counter_*_i are not used any more: the block
--     alignment to the ASSM is done sample-exact in the TDM interface
--   * mult_clk625_*_i are unchanged (the PLL reference is still 6.25 MHz)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aes50_core is
	generic (
		G_SUPPORT_44K1		: boolean := true;		-- false: half-size sample RAMs, 48k only
		G_UART_AUX			: boolean := true;		-- aux channel over UART
		G_TDM_AUX			: boolean := true;		-- aux channel over the 7th TDM line
		G_UART_FIFO_AW		: natural := 11;		-- UART FIFOs: 2**n - 1 bytes
		G_FSYNC_DELAY		: natural := 0;			-- TDM: 0 = MSB with the WCLK edge, 1 = one BCLK later
		G_TX_LEAD_ADJ		: integer := 0;			-- TX block alignment against the ASSM (frames)
		G_SIM_ASSM_SAMPLES	: natural := 2048		-- simulation only: shorter ASSM period
	);
	port (
		--clk and reset
		clk50_i								: in  std_logic;
		rst_i								: in  std_logic;

		--samplerate and operation mode
		fs_mode_i							: in  std_logic_vector(1 downto 0);
		sys_mode_i							: in  std_logic_vector(1 downto 0);
		tdm8_i2s_mode_i						: in  std_logic;
		aux_tx_tdm_uart_select_i			: in  std_logic;

		--connection to phy
		rmii_crs_dv_i						: in  std_logic;
		rmii_rxd_i							: in  std_logic_vector(1 downto 0);
		rmii_tx_en_o						: out std_logic;
		rmii_txd_o							: out std_logic_vector(1 downto 0);
		phy_rst_n_o							: out std_logic;

		--connection to clk transceivers
		aes50_clk_a_rx_i					: in  std_logic;
		aes50_clk_a_tx_o					: out std_logic;
		aes50_clk_a_tx_en_o					: out std_logic;

		aes50_clk_b_rx_i					: in  std_logic;
		aes50_clk_b_tx_o					: out std_logic;
		aes50_clk_b_tx_en_o					: out std_logic;

		--interface to external PLL
		clk_1024xfs_from_pll_i				: in  std_logic;
		pll_lock_n_i						: in  std_logic;
		clk_to_pll_o						: out std_logic;
		pll_mult_value_o					: out natural;
		pll_init_busy_i						: in  std_logic;

		--tdm/i2s clk interface
		mclk_o								: out std_logic;
		wclk_o								: out std_logic;
		bclk_o								: out std_logic;
		wclk_readback_i						: in  std_logic;
		bclk_readback_i						: in  std_logic;
		wclk_out_en_o						: out std_logic;
		bclk_out_en_o						: out std_logic;

		tdm_i								: in  std_logic_vector(6 downto 0);
		tdm_o								: out std_logic_vector(6 downto 0);

		i2s_i								: in  std_logic;
		i2s_o								: out std_logic;

		--aes health signal
		aes_ok_o							: out std_logic;

		--debug signals
		dbg_o								: out std_logic_vector(7 downto 0);

		--uart Signals
		uart_o								: out std_logic;
		uart_i								: in  std_logic;

		--variables (timers count 50 MHz clocks)
		debug_out_signal_pulse_len_i		: in  natural range 0 to 1000000;		-- 500000 = 10 ms
		first_transmit_start_counter_48k_i	: in  natural range 0 to 5000000;		-- not used in v2
		first_transmit_start_counter_44k1_i	: in  natural range 0 to 5000000;		-- not used in v2

		wd_aes_clk_timeout_i				: in  natural range 0 to 50;			-- 25
		wd_aes_rx_dv_timeout_i				: in  natural range 0 to 20000;			-- 7500
		mdix_timer_1ms_reference_i			: in  natural range 0 to 100000;		-- 50000
		aes_clk_ok_counter_reference_i		: in  natural range 0 to 1000000;		-- 500000
		--PLL multiplicators for the 6.25 MHz reference (AES master + TDM master)
		mult_clk625_48k_i					: in  natural;							-- 8246337
		mult_clk625_44k1_i					: in  natural;							-- 7576322

		--uart speed configuration
		uart_clks_per_bit_i					: in  natural;							-- 434 for 115200 baud
		uart_timeout_clks_i					: in  natural							-- 500000 for 10 ms
	);
end aes50_core;

architecture rtl of aes50_core is

	function sel(c : boolean; a, b : natural) return natural is
	begin
		if c then return a; else return b; end if;
	end function;

	constant AW				: natural := sel(G_SUPPORT_44K1, 10, 9);	-- sample RAM address width

	-- multiplicators of the CS2x00 PLL (same as v1)
	constant MULT_X4		: natural := 4194304;		-- 12.288 / 11.2896 MHz BCLK reference (TDM slave)
	constant MULT_X16		: natural := 16777216;		-- 3.072 MHz reference (AES slave, I2S slave)

	signal fs48				: std_logic;
	signal i2s_mode			: std_logic;

	-- ------------------------------------------------------------ resets
	signal rst_sync			: std_logic_vector(1 downto 0);			-- rst_i synchronized to clk50
	signal phy_rst_cnt		: natural range 0 to 50000;				-- 1 ms PHY reset
	signal pll_busy_sync	: std_logic_vector(1 downto 0);
	signal core_rst			: std_logic := '1';						-- clk50 domain
	signal audio_rst_sync	: std_logic_vector(1 downto 0);			-- clk_1024xfs domain
	signal audio_rst		: std_logic;
	signal bclk_rst_sync	: std_logic_vector(1 downto 0);			-- BCLK domain
	signal bclk_rst			: std_logic;
	signal rx_rst			: std_logic := '1';

	-- ------------------------------------------------------------ link / clocks
	signal mdix				: std_logic;
	signal aes_clock_ok		: std_logic;
	signal audio_clock_ok	: std_logic;
	signal rx_ok			: std_logic;
	signal clk625			: std_logic;
	signal aes_clk_in		: std_logic;
	signal aes_clk_out		: std_logic;
	signal aes_clk_gen		: std_logic;
	signal assm_self_tgl	: std_logic;
	signal assm_remote_tgl	: std_logic;
	signal assm_tgl			: std_logic;
	signal mclk_int			: std_logic;

	-- ------------------------------------------------------------ RMII
	signal tx_en_int		: std_logic;
	signal txd_int			: std_logic_vector(1 downto 0);

	-- ------------------------------------------------------------ TX path
	signal tdm_in_int		: std_logic_vector(6 downto 0);
	signal tdm_out_int		: std_logic_vector(6 downto 0);
	signal txr_we			: std_logic;
	signal txr_waddr		: unsigned(AW - 1 downto 0);
	signal txr_wdata		: std_logic_vector(23 downto 0);
	signal txr_raddr		: unsigned(AW - 1 downto 0);
	signal txr_rdata		: std_logic_vector(23 downto 0);
	signal tx_blk_tgl		: std_logic;
	signal tx_blk_sync		: std_logic_vector(2 downto 0) := "000";
	signal tx_base			: unsigned(AW - 1 downto 0);
	signal tx_assm			: std_logic;
	signal framer_start		: std_logic;
	signal framer_busy		: std_logic;
	signal framer_auxv		: std_logic;
	signal framer_page		: unsigned(1 downto 0);
	signal framer_aux_raddr	: unsigned(8 downto 0);					-- page & word (TDM aux RAM)
	signal uart_aux_raddr	: unsigned(7 downto 0);					-- page & word (UART aux RAM)
	signal framer_aux_addr	: unsigned(6 downto 0);
	signal framer_aux_data	: std_logic_vector(15 downto 0);
	signal tx_started		: std_logic;

	-- TX aux over TDM: page written in the BCLK domain
	signal tdm_aux_we		: std_logic;
	signal tdm_aux_waddr	: unsigned(8 downto 0);
	signal tdm_aux_wdata	: std_logic_vector(15 downto 0);
	signal tdm_aux_rdata	: std_logic_vector(15 downto 0);
	signal tdm_aux_tgl		: std_logic;
	signal tdm_aux_page		: unsigned(1 downto 0);
	signal tdm_aux_sync		: std_logic_vector(2 downto 0) := "000";
	signal tdm_aux_ready	: std_logic;							-- a complete page waits for the framer
	signal tdm_aux_rpage	: unsigned(1 downto 0);

	-- TX aux over UART: page written by the encoder
	signal uart_aux_we		: std_logic;
	signal uart_aux_waddr	: unsigned(7 downto 0);
	signal uart_aux_wdata	: std_logic_vector(15 downto 0);
	signal uart_aux_rdata	: std_logic_vector(15 downto 0);
	signal uart_enc_req		: std_logic;
	signal uart_enc_page	: std_logic;
	signal uart_enc_done	: std_logic;
	signal uart_aux_ready	: std_logic;
	signal uart_aux_rpage	: std_logic;

	-- ------------------------------------------------------------ RX path
	signal rxr_we			: std_logic;
	signal rxr_waddr		: unsigned(AW - 1 downto 0);
	signal rxr_wdata		: std_logic_vector(23 downto 0);
	signal rxr_raddr		: unsigned(AW - 1 downto 0);
	signal rxr_rdata		: std_logic_vector(23 downto 0);
	signal rxa_we			: std_logic;
	signal rxa_waddr		: unsigned(7 downto 0);
	signal rxa_wdata		: std_logic_vector(15 downto 0);
	signal rxa_raddr		: unsigned(7 downto 0);
	signal rxa_rdata		: std_logic_vector(15 downto 0);
	signal rx_blk_done		: std_logic;
	signal rx_blk_base		: unsigned(AW - 1 downto 0);
	signal rx_blk_page		: std_logic;
	signal rx_blk_assm		: std_logic;
	signal rx_blk_tgl		: std_logic := '0';
	signal rx_base_hold		: unsigned(AW - 1 downto 0);
	signal rx_page_hold		: std_logic;
	signal uart_dec_start	: std_logic;

	-- ------------------------------------------------------------ debug
	signal assm_dbg_sync	: std_logic_vector(2 downto 0) := "000";
	type dbg_cnt_t is array (0 to 2) of natural range 0 to 1000000;
	signal dbg_cnt			: dbg_cnt_t;
	signal dbg_pulse		: std_logic_vector(2 downto 0);

begin

	fs48		<= fs_mode_i(0);
	i2s_mode	<= tdm8_i2s_mode_i;

	-- ================================================================ resets
	process (clk50_i, rst_i)
	begin
		if rst_i = '1' then
			rst_sync <= "11";
		elsif rising_edge(clk50_i) then
			rst_sync <= rst_sync(0) & '0';
		end if;
	end process;

	process (clk50_i)
	begin
		if rising_edge(clk50_i) then
			pll_busy_sync <= pll_busy_sync(0) & pll_init_busy_i;
			if rst_sync(1) = '1' then
				phy_rst_cnt	<= 50000;
				phy_rst_n_o	<= '0';
				core_rst	<= '1';
			else
				if phy_rst_cnt > 0 then
					phy_rst_cnt <= phy_rst_cnt - 1;
				else
					phy_rst_n_o <= '1';
				end if;
				if pll_busy_sync(1) = '1' or phy_rst_cnt > 0 then
					core_rst <= '1';
				else
					core_rst <= '0';
				end if;
			end if;
			-- the receiver restarts (waits for the next ASSM frame) when the link is lost
			rx_rst <= core_rst or not rx_ok;
		end if;
	end process;

	-- asynchronous assertion, synchronous release in the audio clock domains
	process (clk_1024xfs_from_pll_i, core_rst)
	begin
		if core_rst = '1' then
			audio_rst_sync <= "11";
		elsif rising_edge(clk_1024xfs_from_pll_i) then
			audio_rst_sync <= audio_rst_sync(0) & '0';
		end if;
	end process;
	audio_rst <= audio_rst_sync(1);

	process (bclk_readback_i, core_rst)
	begin
		if core_rst = '1' then
			bclk_rst_sync <= "11";
		elsif rising_edge(bclk_readback_i) then
			bclk_rst_sync <= bclk_rst_sync(0) & '0';
		end if;
	end process;
	bclk_rst <= bclk_rst_sync(1);

	-- ================================================================ link supervision (clk50)
	u_link : entity work.aes50_link_ctrl
		port map (
			clk_i => clk50_i, rst_i => core_rst,
			aes_clk_a_rx_i => aes50_clk_a_rx_i, aes_clk_b_rx_i => aes50_clk_b_rx_i,
			pll_lock_n_i => pll_lock_n_i, rx_dv_i => rmii_crs_dv_i,
			wd_aes_clk_timeout_i => wd_aes_clk_timeout_i, wd_aes_rx_dv_timeout_i => wd_aes_rx_dv_timeout_i,
			mdix_timer_1ms_i => mdix_timer_1ms_reference_i, aes_clk_ok_ref_i => aes_clk_ok_counter_reference_i,
			mdix_o => mdix, aes_clock_ok_o => aes_clock_ok, clock_health_good_o => audio_clock_ok,
			rx_ok_o => rx_ok, clk625_o => clk625);

	aes_ok_o <= audio_clock_ok;

	-- sync signal pins: in MDI the A pair transmits and the B pair receives
	aes_clk_in	<= aes50_clk_b_rx_i when mdix = '0' else aes50_clk_a_rx_i;
	aes_clk_out	<= aes_clk_in when sys_mode_i = "00" else aes_clk_gen;	-- AES slave: loop back
	aes50_clk_a_tx_o	<= aes_clk_out when (mdix = '0' and core_rst = '0') else '0';
	aes50_clk_b_tx_o	<= aes_clk_out when (mdix = '1' and core_rst = '0') else '0';
	aes50_clk_a_tx_en_o	<= '1' when (mdix = '0' and core_rst = '0') else '0';
	aes50_clk_b_tx_en_o	<= '1' when (mdix = '1' and core_rst = '0') else '0';

	-- PLL reference and multiplicator (as v1)
	clk_to_pll_o <= aes_clk_in		when (sys_mode_i = "00" and core_rst = '0') else
					clk625			when (sys_mode_i = "01" and core_rst = '0') else
					bclk_readback_i	when (sys_mode_i(1) = '1' and core_rst = '0') else
					'0';
	pll_mult_value_o <= MULT_X16			when (sys_mode_i = "00" or (sys_mode_i(1) = '1' and i2s_mode = '1')) else
						mult_clk625_44k1_i	when (sys_mode_i = "01" and fs_mode_i = "00") else
						mult_clk625_48k_i	when (sys_mode_i = "01") else
						MULT_X4;

	-- ================================================================ audio clock domain
	u_clk : entity work.aes50_clk_audio
		generic map (G_ASSM_SAMPLES => G_SIM_ASSM_SAMPLES)
		port map (
			clk_i => clk_1024xfs_from_pll_i, rst_i => audio_rst,
			sys_mode_i => sys_mode_i, i2s_i => i2s_mode,
			aes_clk_in_i => aes_clk_in, aes_clk_gen_o => aes_clk_gen,
			assm_self_tgl_o => assm_self_tgl, assm_remote_tgl_o => assm_remote_tgl,
			wclk_readback_i => wclk_readback_i,
			mclk_o => mclk_int, bclk_o => bclk_o, wclk_o => wclk_o);

	mclk_o <= mclk_int;
	-- AES slave: the blocks are aligned to the received ASSM, otherwise to our own
	assm_tgl <= assm_remote_tgl when sys_mode_i = "00" else assm_self_tgl;

	wclk_out_en_o <= '1' when sys_mode_i(1) = '0' else '0';
	bclk_out_en_o <= '1' when sys_mode_i(1) = '0' else '0';

	-- ================================================================ TDM / I2S (BCLK domain)
	tdm_in_int	<= tdm_i when i2s_mode = '0' else "000000" & i2s_i;
	tdm_o		<= tdm_out_int when i2s_mode = '0' else (others => '0');
	i2s_o		<= tdm_out_int(0) when i2s_mode = '1' else '0';

	u_tdm : entity work.aes50_tdm_serdes
		generic map (G_AW => AW, G_FSYNC_DELAY => G_FSYNC_DELAY, G_TX_LEAD_ADJ => G_TX_LEAD_ADJ,
					 G_ASSM_FRAMES => G_SIM_ASSM_SAMPLES)
		port map (
			bclk_i => bclk_readback_i, wclk_i => wclk_readback_i, rst_i => bclk_rst,
			fs48_i => fs48, i2s_i => i2s_mode,
			tdm_i => tdm_in_int, tdm_o => tdm_out_int,
			tx_ram_we_o => txr_we, tx_ram_addr_o => txr_waddr, tx_ram_data_o => txr_wdata,
			tx_aux_we_o => tdm_aux_we, tx_aux_addr_o => tdm_aux_waddr, tx_aux_data_o => tdm_aux_wdata,
			rx_ram_addr_o => rxr_raddr, rx_ram_data_i => rxr_rdata,
			rx_aux_addr_o => rxa_raddr, rx_aux_data_i => rxa_rdata,
			tx_en_i => audio_clock_ok, assm_tgl_i => assm_tgl,
			tx_blk_tgl_o => tx_blk_tgl, tx_base_o => tx_base, tx_assm_o => tx_assm,
			tx_aux_tgl_o => tdm_aux_tgl, tx_aux_page_o => tdm_aux_page,
			rx_blk_tgl_i => rx_blk_tgl, rx_base_i => rx_base_hold, rx_page_i => rx_page_hold,
			playing_o => open);

	-- ================================================================ RAMs
	u_tx_ram : entity work.aes50_dpram
		generic map (G_AW => AW, G_DW => 24)
		port map (wclk_i => bclk_readback_i, we_i => txr_we, waddr_i => txr_waddr, wdata_i => txr_wdata,
				  rclk_i => clk50_i, raddr_i => txr_raddr, rdata_o => txr_rdata);

	u_rx_ram : entity work.aes50_dpram
		generic map (G_AW => AW, G_DW => 24)
		port map (wclk_i => clk50_i, we_i => rxr_we, waddr_i => rxr_waddr, wdata_i => rxr_wdata,
				  rclk_i => bclk_readback_i, raddr_i => rxr_raddr, rdata_o => rxr_rdata);

	gen_tdm_aux : if G_TDM_AUX generate
		u_tx_aux_ram : entity work.aes50_dpram
			generic map (G_AW => 9, G_DW => 16)
			port map (wclk_i => bclk_readback_i, we_i => tdm_aux_we, waddr_i => tdm_aux_waddr, wdata_i => tdm_aux_wdata,
					  rclk_i => clk50_i, raddr_i => framer_aux_raddr, rdata_o => tdm_aux_rdata);
		u_rx_aux_ram : entity work.aes50_dpram
			generic map (G_AW => 8, G_DW => 16)
			port map (wclk_i => clk50_i, we_i => rxa_we, waddr_i => rxa_waddr, wdata_i => rxa_wdata,
					  rclk_i => bclk_readback_i, raddr_i => rxa_raddr, rdata_o => rxa_rdata);
	end generate;
	gen_no_tdm_aux : if not G_TDM_AUX generate
		tdm_aux_rdata	<= (others => '0');
		rxa_rdata		<= (others => '0');
	end generate;

	-- ================================================================ TX framer (clk50)
	-- start the framer for every completed block; choose the aux source
	process (clk50_i)
		variable use_uart : boolean;
	begin
		if rising_edge(clk50_i) then
			tx_blk_sync		<= tx_blk_sync(1 downto 0) & tx_blk_tgl;
			tdm_aux_sync	<= tdm_aux_sync(1 downto 0) & tdm_aux_tgl;
			framer_start	<= '0';
			uart_enc_req	<= '0';
			use_uart		:= G_UART_AUX and aux_tx_tdm_uart_select_i = '1';

			-- a complete aux page arrived over TDM (the page before the one written now)
			if tdm_aux_sync(2) /= tdm_aux_sync(1) then
				tdm_aux_ready	<= '1';
				tdm_aux_rpage	<= tdm_aux_page - 1;
			end if;
			if uart_enc_done = '1' then
				uart_aux_ready	<= '1';
				uart_aux_rpage	<= uart_enc_page;
			end if;

			if tx_blk_sync(2) /= tx_blk_sync(1) and framer_busy = '0' and audio_clock_ok = '1' and core_rst = '0' then
				framer_start	<= '1';
				tx_started		<= '1';
				-- aux words of this block: a ready page or the idle pattern (v1: FIFO filled or empty)
				if use_uart then
					framer_auxv		<= uart_aux_ready;
					framer_page		<= '0' & uart_aux_rpage;
					uart_aux_ready	<= '0';
					-- the encoder fills the other page for the next block
					uart_enc_req	<= '1';
					uart_enc_page	<= not uart_aux_rpage;
				elsif G_TDM_AUX then
					framer_auxv		<= tdm_aux_ready;
					framer_page		<= tdm_aux_rpage;
					tdm_aux_ready	<= '0';
				else
					framer_auxv		<= '0';
				end if;
			end if;

			if core_rst = '1' or audio_clock_ok = '0' then
				tdm_aux_ready	<= '0';
				uart_aux_ready	<= '0';
				uart_aux_rpage	<= '0';
				tx_started		<= '0';
			end if;
		end if;
	end process;

	framer_aux_raddr	<= framer_page & framer_aux_addr;
	uart_aux_raddr		<= framer_page(0) & framer_aux_addr;
	framer_aux_data <= uart_aux_rdata when (G_UART_AUX and aux_tx_tdm_uart_select_i = '1') else tdm_aux_rdata;

	u_framer : entity work.aes50_tx_framer
		generic map (G_AW => AW)
		port map (
			clk_i => clk50_i, rst_i => core_rst, fs48_i => fs48, i2s_i => i2s_mode,
			start_i => framer_start, base_i => tx_base, assm_i => tx_assm, aux_valid_i => framer_auxv,
			busy_o => framer_busy, frame_o => open,
			ram_addr_o => txr_raddr, ram_data_i => txr_rdata,
			aux_addr_o => framer_aux_addr, aux_data_i => framer_aux_data,
			rmii_txd_o => txd_int, rmii_tx_en_o => tx_en_int);

	rmii_txd_o		<= txd_int;
	rmii_tx_en_o	<= tx_en_int;

	gen_uart_enc : if G_UART_AUX generate
		u_enc : entity work.aes50_aux_uart_enc
			generic map (G_FIFO_AW => G_UART_FIFO_AW)
			port map (
				clk_i => clk50_i, rst_i => core_rst,
				uart_i => uart_i, clks_per_bit_i => uart_clks_per_bit_i, timeout_clks_i => uart_timeout_clks_i,
				fs48_i => fs48, req_i => uart_enc_req, req_page_i => uart_enc_page,
				aux_we_o => uart_aux_we, aux_addr_o => uart_aux_waddr, aux_data_o => uart_aux_wdata,
				done_o => uart_enc_done);
		u_uart_aux_ram : entity work.aes50_dpram
			generic map (G_AW => 8, G_DW => 16)
			port map (wclk_i => clk50_i, we_i => uart_aux_we, waddr_i => uart_aux_waddr, wdata_i => uart_aux_wdata,
					  rclk_i => clk50_i, raddr_i => uart_aux_raddr, rdata_o => uart_aux_rdata);
	end generate;
	gen_no_uart_enc : if not G_UART_AUX generate
		uart_aux_rdata	<= (others => '0');
		uart_enc_done	<= '0';
	end generate;

	-- ================================================================ RX deframer (clk50)
	u_deframer : entity work.aes50_rx_deframer
		generic map (G_AW => AW)
		port map (
			clk_i => clk50_i, rst_i => rx_rst, fs48_i => fs48,
			rmii_crs_dv_i => rmii_crs_dv_i, rmii_rxd_i => rmii_rxd_i,
			ram_we_o => rxr_we, ram_addr_o => rxr_waddr, ram_data_o => rxr_wdata,
			aux_we_o => rxa_we, aux_addr_o => rxa_waddr, aux_data_o => rxa_wdata,
			blk_done_o => rx_blk_done, blk_base_o => rx_blk_base, blk_page_o => rx_blk_page,
			blk_ok_o => open, blk_assm_o => rx_blk_assm,
			frame_ok_o => open, frame_err_o => open, sync_o => open);

	-- report received blocks to the TDM interface (toggle, data held until the next block)
	process (clk50_i)
	begin
		if rising_edge(clk50_i) then
			if rx_blk_done = '1' then
				rx_base_hold	<= rx_blk_base;
				rx_page_hold	<= rx_blk_page;
				rx_blk_tgl		<= not rx_blk_tgl;
			end if;
			if core_rst = '1' then
				rx_blk_tgl <= '0';
			end if;
		end if;
	end process;

	gen_uart_dec : if G_UART_AUX generate
		-- aux words 0 and 44 start an Ethernet frame (scrambler reset)
		uart_dec_start <= '1' when rxa_waddr(6 downto 0) = 0 or rxa_waddr(6 downto 0) = 44 else '0';
		u_dec : entity work.aes50_aux_uart_dec
			generic map (G_FIFO_AW => G_UART_FIFO_AW)
			port map (
				clk_i => clk50_i, rst_i => rx_rst,
				aux_we_i => rxa_we, aux_data_i => rxa_wdata, aux_start_i => uart_dec_start,
				clks_per_bit_i => uart_clks_per_bit_i, uart_o => uart_o);
	end generate;
	gen_no_uart_dec : if not G_UART_AUX generate
		uart_o <= '1';
	end generate;

	-- ================================================================ debug
	-- 7: ASSM frame sent, 6: ASSM frame received, 5: ASSM on the sync signal
	-- (pulses stretched to debug_out_signal_pulse_len_i), 4: RMII CRS_DV,
	-- 3: RMII TX_EN, 2: transmission started, 1: RX link active, 0: MCLK
	process (clk50_i)
		variable trig : std_logic_vector(2 downto 0);
	begin
		if rising_edge(clk50_i) then
			assm_dbg_sync <= assm_dbg_sync(1 downto 0) & assm_tgl;
			trig(2) := framer_start and tx_assm;
			trig(1) := rx_blk_done and rx_blk_assm;
			trig(0) := assm_dbg_sync(2) xor assm_dbg_sync(1);
			for i in 0 to 2 loop
				if trig(i) = '1' then
					dbg_cnt(i)		<= debug_out_signal_pulse_len_i;
					dbg_pulse(i)	<= '1';
				elsif dbg_cnt(i) > 0 then
					dbg_cnt(i) <= dbg_cnt(i) - 1;
				else
					dbg_pulse(i) <= '0';
				end if;
			end loop;
		end if;
	end process;

	dbg_o <= dbg_pulse & rmii_crs_dv_i & tx_en_int & tx_started & rx_ok & mclk_int;

end architecture;
