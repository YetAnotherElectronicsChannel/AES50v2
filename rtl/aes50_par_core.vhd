-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE (v2), OpenProSeries extension
-- File         : <aes50_par_core.vhd>
-- Description  : The v2 core with a parallel on-chip audio interface instead
--                of TDM / I2S pins, for a design that routes audio inside
--                the FPGA. Same link, framer and deframer as aes50_core;
--                aes50_tdm_serdes is replaced by the parallel serdes below.
--
-- License      : GNU General Public License v3.0 or later (GPL-3.0-or-later)
-- ===========================================================================
--
-- Clocks: clk50_i (RMII and everything here except the audio-clock process),
-- clk_1024xfs_from_pll_i (1024 x 48 kHz: sync signal and the sample periods).
--
-- Audio towards AES50: after every sample_tick_o the producer writes one
-- period, channels in any order, with par_in_we_i: 48 channels at 48 kHz,
-- 24 at 96 kHz (fs96_i). Writes before the first block start (tx_started_o)
-- are dropped. At 96 kHz the two periods of a 48 kHz frame period go to
-- frame slots c (first) and c + 24 (second).
-- Audio from AES50: every good received block is streamed out one word per
-- clock right after its frame ended: 6 frame periods x 48 words, slot w of
-- period s as par_out_ch_o = w (48k), or w mod 24 with par_out_phase_o = 1
-- for w >= 24 (96k). Blocks whose frame failed the FCS or was cut short are
-- dropped (rx_block_drop_o), so no corrupted audio is played.
-- Aux towards AES50: aux_tx_req_o asks for the next 44 words; the producer
-- writes them in order with aux_tx_we_i (any time before the next block).
-- A filled page is sent with the next block, an empty one as idle pattern.
-- Aux from AES50: the 44 words of every good block are streamed out with
-- aux_rx_count_o words left to read; each aux_rx_rd_i takes the next one, which
-- is on aux_rx_data_o from the next clock on (aux_rx_first_o with the block's
-- first word): the timing of a FIFO with a registered read port. The words come straight from the receiver's aux page, so a consumer
-- (an aux decoder) needs no FIFO of its own; it has the whole block period
-- (125 us) to read them. A new good block restarts the count.
-- fs96_i and sys_mode_i must be static while rst_i = '0'.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.aes50_pkg.all;

entity aes50_par_core is
	generic (
		G_ASSM_INIT			: natural := 2;			-- aes50_clk_audio (simulation: first ASSM early)
		G_ASSM_FRAMES		: natural := 2048;		-- sample periods between two ASSM
		G_TX_LEAD_ADJ		: integer := 0;			-- TX block alignment against the ASSM (frames)
		G_WD_CLK			: natural := 25;		-- the v2 timers, in 50 MHz clocks (aes50_core defaults)
		G_WD_RX_DV			: natural := 7500;
		G_MDIX_1MS			: natural := 50000;
		G_CLK_OK_REF		: natural := 500000
	);
	port (
		clk50_i					: in  std_logic;
		rst_i					: in  std_logic;		-- asynchronous
		fs96_i					: in  std_logic;		-- '0' 48 kHz, '1' 96 kHz
		sys_mode_i				: in  std_logic_vector(1 downto 0);	-- "00" AES50 slave, "01" AES50 master

		rmii_crs_dv_i			: in  std_logic;
		rmii_rxd_i				: in  std_logic_vector(1 downto 0);
		rmii_tx_en_o			: out std_logic;
		rmii_txd_o				: out std_logic_vector(1 downto 0);
		phy_rst_n_o				: out std_logic;

		aes50_clk_a_rx_i		: in  std_logic;
		aes50_clk_a_tx_o		: out std_logic;
		aes50_clk_a_tx_en_o		: out std_logic;
		aes50_clk_b_rx_i		: in  std_logic;
		aes50_clk_b_tx_o		: out std_logic;
		aes50_clk_b_tx_en_o		: out std_logic;

		clk_1024xfs_from_pll_i	: in  std_logic;
		pll_lock_n_i			: in  std_logic;
		clk_to_pll_o			: out std_logic;

		-- parallel audio (clk50_i)
		sample_tick_o			: out std_logic;
		par_in_we_i				: in  std_logic;
		par_in_ch_i				: in  std_logic_vector(5 downto 0);
		par_in_sample_i			: in  std_logic_vector(23 downto 0);
		par_out_valid_o			: out std_logic;
		par_out_ch_o			: out std_logic_vector(5 downto 0);
		par_out_phase_o			: out std_logic;
		par_out_sample_o		: out std_logic_vector(23 downto 0);

		-- aux words (clk50_i)
		aux_tx_req_o			: out std_logic;
		aux_tx_we_i				: in  std_logic;
		aux_tx_data_i			: in  std_logic_vector(15 downto 0);
		aux_rx_count_o			: out unsigned(5 downto 0);
		aux_rx_rd_i				: in  std_logic;
		aux_rx_first_o			: out std_logic;
		aux_rx_data_o			: out std_logic_vector(15 downto 0);

		-- status (levels) and events (one-clock pulses), clk50_i
		aes_ok_o				: out std_logic;		-- both sync pairs healthy (TX enable)
		rx_ok_o					: out std_logic;		-- RMII receive activity
		tx_started_o			: out std_logic;		-- TX blocks are being sent
		tx_frame_o				: out std_logic;
		rx_frame_ok_o			: out std_logic;
		rx_frame_err_o			: out std_logic;		-- bad FCS or cut short
		rx_block_o				: out std_logic;		-- a block was streamed out
		rx_block_drop_o			: out std_logic;		-- a block was dropped (bad frame)
		rx_assm_o				: out std_logic;		-- a block with the ASSM flag was received
		fmt_valid_o				: out std_logic;		-- aes50_rx_deframer's format report
		fmt_bad_o				: out std_logic;
		fmt_o					: out std_logic_vector(7 downto 0)
	);
end entity;

architecture rtl of aes50_par_core is

	constant AW				: natural := 9;			-- 48/96k only: 512-word sample rings

	signal rst_sync			: std_logic_vector(1 downto 0);
	signal phy_rst_cnt		: natural range 0 to 50000;
	signal core_rst			: std_logic := '1';
	signal rx_rst			: std_logic := '1';
	signal audio_rst_sync	: std_logic_vector(1 downto 0);
	signal audio_rst		: std_logic;

	signal mdix				: std_logic;
	signal audio_clock_ok	: std_logic;
	signal rx_ok			: std_logic;
	signal clk625			: std_logic;
	signal aes_clk_in		: std_logic;
	signal aes_clk_out		: std_logic;
	signal aes_clk_gen		: std_logic;
	signal assm_self_tgl	: std_logic;
	signal assm_remote_tgl	: std_logic;
	signal assm_tgl			: std_logic;

	-- sample periods: a 1024-clock counter in the audio clock, its first half as a level
	signal aud_phase		: unsigned(9 downto 0);
	signal aud_sq			: std_logic;
	signal sq_sync			: std_logic_vector(2 downto 0) := "000";
	signal assm_sync		: std_logic_vector(2 downto 0) := "000";

	-- TX block forming (as aes50_tdm_serdes, one period = one 48k frame period)
	signal half				: std_logic;			-- 96k: the second period of the frame period
	signal frames_since_assm: unsigned(10 downto 0);
	signal assm_pending		: std_logic;
	signal tx_aligned		: std_logic;
	signal tx_active		: std_logic;
	signal tx_frame_in_block: unsigned(2 downto 0);
	signal tx_block_cnt		: unsigned(9 downto 0);
	signal tx_frame_addr	: unsigned(AW - 1 downto 0);
	signal tx_block_addr	: unsigned(AW - 1 downto 0);
	signal txr_we			: std_logic;
	signal txr_waddr		: unsigned(AW - 1 downto 0);
	signal txr_wdata		: std_logic_vector(23 downto 0);
	signal txr_raddr		: unsigned(AW - 1 downto 0);
	signal txr_rdata		: std_logic_vector(23 downto 0);
	signal framer_start		: std_logic;
	signal framer_busy		: std_logic;
	signal framer_base		: unsigned(AW - 1 downto 0);
	signal framer_assm		: std_logic;
	signal framer_auxv		: std_logic;

	-- TX aux: two pages of 128 words, one filled by the producer, one sent
	signal fill_page		: std_logic;
	signal fill_cnt			: unsigned(6 downto 0);
	signal fill_busy		: std_logic;
	signal ready			: std_logic;
	signal ready_page		: std_logic;
	signal send_page		: std_logic;
	signal txa_we			: std_logic;
	signal txa_waddr		: unsigned(7 downto 0);
	signal txa_wdata		: std_logic_vector(15 downto 0);
	signal txa_raddr		: unsigned(7 downto 0);
	signal framer_aux_addr	: unsigned(6 downto 0);
	signal framer_aux_data	: std_logic_vector(15 downto 0);

	-- RX
	signal rxr_we			: std_logic;
	signal rxr_waddr		: unsigned(AW - 1 downto 0);
	signal rxr_wdata		: std_logic_vector(23 downto 0);
	signal rxr_raddr		: unsigned(AW - 1 downto 0) := (others => '0');
	signal rxr_rdata		: std_logic_vector(23 downto 0);
	signal rxa_we			: std_logic;
	signal rxa_waddr		: unsigned(7 downto 0);
	signal rxa_wdata		: std_logic_vector(15 downto 0);
	signal rxa_raddr		: unsigned(7 downto 0);
	signal rxa_rdata		: std_logic_vector(15 downto 0);
	signal blk_done			: std_logic;
	signal blk_base			: unsigned(AW - 1 downto 0);
	signal blk_page			: std_logic;
	signal blk_ok			: std_logic;
	signal blk_assm			: std_logic;
	signal fs48				: std_logic := '1';

	-- RX streaming: audio words 0..287, aux words 0..43, both read with one clock latency
	signal st_on			: std_logic;
	signal st_w				: unsigned(5 downto 0);		-- slot 0..47
	signal st_s				: unsigned(2 downto 0);		-- period 0..5
	signal st_addr			: unsigned(AW - 1 downto 0);
	signal st_v_d, st_v_dd	: std_logic;
	signal st_w_d, st_w_dd	: unsigned(5 downto 0);
	signal sa_left			: unsigned(5 downto 0) := (others => '0');	-- aux words not read yet
	signal sa_page			: std_logic;
	signal sa_j				: unsigned(6 downto 0);
	signal sa_f				: std_logic;

begin

	-- ================================================================ resets (as aes50_core)
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
				if phy_rst_cnt > 0 then core_rst <= '1'; else core_rst <= '0'; end if;
			end if;
			rx_rst <= core_rst or not rx_ok;
		end if;
	end process;

	process (clk_1024xfs_from_pll_i, core_rst)
	begin
		if core_rst = '1' then
			audio_rst_sync <= "11";
		elsif rising_edge(clk_1024xfs_from_pll_i) then
			audio_rst_sync <= audio_rst_sync(0) & '0';
		end if;
	end process;
	audio_rst <= audio_rst_sync(1);

	-- ================================================================ link supervision and sync signal
	u_link : entity work.aes50_link_ctrl
		port map (
			clk_i => clk50_i, rst_i => core_rst,
			aes_clk_a_rx_i => aes50_clk_a_rx_i, aes_clk_b_rx_i => aes50_clk_b_rx_i,
			pll_lock_n_i => pll_lock_n_i, rx_dv_i => rmii_crs_dv_i,
			wd_aes_clk_timeout_i => G_WD_CLK, wd_aes_rx_dv_timeout_i => G_WD_RX_DV,
			mdix_timer_1ms_i => G_MDIX_1MS, aes_clk_ok_ref_i => G_CLK_OK_REF,
			mdix_o => mdix, aes_clock_ok_o => open, clock_health_good_o => audio_clock_ok,
			rx_ok_o => rx_ok, clk625_o => clk625);

	aes_ok_o	<= audio_clock_ok;
	rx_ok_o		<= rx_ok;

	aes_clk_in	<= aes50_clk_b_rx_i when mdix = '0' else aes50_clk_a_rx_i;
	aes_clk_out	<= aes_clk_in when sys_mode_i = "00" else aes_clk_gen;
	aes50_clk_a_tx_o	<= aes_clk_out when (mdix = '0' and core_rst = '0') else '0';
	aes50_clk_b_tx_o	<= aes_clk_out when (mdix = '1' and core_rst = '0') else '0';
	aes50_clk_a_tx_en_o	<= '1' when (mdix = '0' and core_rst = '0') else '0';
	aes50_clk_b_tx_en_o	<= '1' when (mdix = '1' and core_rst = '0') else '0';
	clk_to_pll_o <= aes_clk_in when (sys_mode_i = "00" and core_rst = '0') else
					clk625     when (sys_mode_i = "01" and core_rst = '0') else '0';

	u_clk : entity work.aes50_clk_audio
		generic map (G_ASSM_SAMPLES => G_ASSM_FRAMES, G_ASSM_INIT => G_ASSM_INIT)
		port map (
			clk_i => clk_1024xfs_from_pll_i, rst_i => audio_rst,
			sys_mode_i => sys_mode_i, i2s_i => '0',
			aes_clk_in_i => aes_clk_in, aes_clk_gen_o => aes_clk_gen,
			assm_self_tgl_o => assm_self_tgl, assm_remote_tgl_o => assm_remote_tgl,
			wclk_readback_i => '0', mclk_o => open, bclk_o => open, wclk_o => open);
	assm_tgl <= assm_remote_tgl when sys_mode_i = "00" else assm_self_tgl;

	process (clk_1024xfs_from_pll_i, audio_rst)
	begin
		if audio_rst = '1' then
			aud_phase	<= (others => '0');
			aud_sq		<= '0';
		elsif rising_edge(clk_1024xfs_from_pll_i) then
			aud_phase	<= aud_phase + 1;
			aud_sq		<= not aud_phase(9);
		end if;
	end process;

	-- ================================================================ TX: periods, blocks, framer start
	process (clk50_i)
		variable frame_start, half_start : boolean;
		variable slot : unsigned(AW - 1 downto 0);
	begin
		if rising_edge(clk50_i) then
			sq_sync		<= sq_sync(1 downto 0) & aud_sq;
			assm_sync	<= assm_sync(1 downto 0) & assm_tgl;
			frame_start	:= sq_sync(2) = '0' and sq_sync(1) = '1';
			half_start	:= sq_sync(2) = '1' and sq_sync(1) = '0';
			framer_start	<= '0';
			aux_tx_req_o	<= '0';
			txr_we			<= '0';
			if frame_start or (half_start and fs96_i = '1') then
				sample_tick_o <= '1';
			else
				sample_tick_o <= '0';
			end if;
			if half_start then half <= '1'; end if;

			if assm_sync(2) /= assm_sync(1) then
				assm_pending <= '1';
			end if;
			if frame_start then
				half <= '0';
				frames_since_assm <= frames_since_assm + 1;
				if assm_pending = '1' then
					assm_pending		<= '0';
					frames_since_assm	<= (others => '0');
					if audio_clock_ok = '1' then
						tx_aligned <= '1';
					end if;
				end if;
				if tx_active = '1' then
					if tx_frame_in_block = block_frames('1') - 1 then			-- the block ends with this period
						tx_frame_in_block	<= (others => '0');
						tx_block_addr		<= tx_frame_addr + C_AUDIO_CHANNELS;
						tx_block_cnt		<= tx_block_cnt + 1;
						if framer_busy = '0' then
							framer_start	<= '1';
							framer_base		<= tx_block_addr;
							if tx_block_cnt = 0 then framer_assm <= '1'; else framer_assm <= '0'; end if;
							framer_auxv		<= ready;
							send_page		<= ready_page;
							ready			<= '0';
							-- the producer fills the other page for the next block
							aux_tx_req_o	<= '1';
							fill_page		<= not ready_page;
							fill_cnt		<= (others => '0');
							fill_busy		<= '1';
						end if;
					else
						tx_frame_in_block <= tx_frame_in_block + 1;
					end if;
					tx_frame_addr <= tx_frame_addr + C_AUDIO_CHANNELS;
				elsif tx_aligned = '1' and
					  frames_since_assm = to_unsigned(G_ASSM_FRAMES - 2 - G_TX_LEAD_ADJ - (block_frames('1') - 1), 11) then
					tx_active			<= '1';
					tx_frame_in_block	<= (others => '0');
					tx_block_cnt		<= (others => '0');
					tx_frame_addr		<= tx_frame_addr + C_AUDIO_CHANNELS;
					tx_block_addr		<= tx_frame_addr + C_AUDIO_CHANNELS;
				end if;
			end if;
			if audio_clock_ok = '0' then
				tx_aligned	<= '0';
				tx_active	<= '0';
			end if;

			-- producer writes into the current period
			if par_in_we_i = '1' and tx_active = '1' then
				slot := resize(unsigned(par_in_ch_i), AW);
				if fs96_i = '1' and half = '1' then slot := slot + 24; end if;
				txr_we		<= '1';
				txr_waddr	<= tx_frame_addr + slot;
				txr_wdata	<= par_in_sample_i;
			end if;

			-- aux words of the page being filled
			txa_we <= '0';
			if aux_tx_we_i = '1' and fill_busy = '1' then
				txa_we		<= '1';
				txa_waddr	<= fill_page & fill_cnt;
				txa_wdata	<= aux_tx_data_i;
				fill_cnt	<= fill_cnt + 1;
				if fill_cnt = C_AUX_WORDS_PER_FRAME - 1 then
					fill_busy	<= '0';
					ready		<= '1';
					ready_page	<= fill_page;
				end if;
			end if;

			if core_rst = '1' then
				half				<= '0';
				frames_since_assm	<= (others => '0');
				assm_pending		<= '0';
				tx_aligned			<= '0';
				tx_active			<= '0';
				tx_frame_addr		<= (others => '0');
				fill_busy			<= '0';
				ready				<= '0';
				ready_page			<= '0';
				fill_page			<= '0';
			end if;
		end if;
	end process;
	tx_started_o <= tx_active;
	aux_rx_count_o <= sa_left;
	rxa_raddr      <= sa_page & sa_j;
	aux_rx_data_o  <= rxa_rdata;
	aux_rx_first_o <= sa_f;

	u_tx_ram : entity work.aes50_dpram
		generic map (G_AW => AW, G_DW => 24)
		port map (wclk_i => clk50_i, we_i => txr_we, waddr_i => txr_waddr, wdata_i => txr_wdata,
				  rclk_i => clk50_i, raddr_i => txr_raddr, rdata_o => txr_rdata);
	u_tx_aux_ram : entity work.aes50_dpram
		generic map (G_AW => 8, G_DW => 16)
		port map (wclk_i => clk50_i, we_i => txa_we, waddr_i => txa_waddr, wdata_i => txa_wdata,
				  rclk_i => clk50_i, raddr_i => txa_raddr, rdata_o => framer_aux_data);

	txa_raddr <= send_page & framer_aux_addr;

	u_framer : entity work.aes50_tx_framer
		generic map (G_AW => AW)
		port map (
			clk_i => clk50_i, rst_i => core_rst, fs48_i => '1', fs96_i => fs96_i, i2s_i => '0',
			start_i => framer_start, base_i => framer_base, assm_i => framer_assm, aux_valid_i => framer_auxv,
			busy_o => framer_busy, frame_o => tx_frame_o,
			ram_addr_o => txr_raddr, ram_data_i => txr_rdata,
			aux_addr_o => framer_aux_addr, aux_data_i => framer_aux_data,
			rmii_txd_o => rmii_txd_o, rmii_tx_en_o => rmii_tx_en_o);

	-- ================================================================ RX
	u_deframer : entity work.aes50_rx_deframer
		generic map (G_AW => AW)
		port map (
			clk_i => clk50_i, rst_i => rx_rst, fs48_i => fs48, fs96_i => fs96_i,
			rmii_crs_dv_i => rmii_crs_dv_i, rmii_rxd_i => rmii_rxd_i,
			ram_we_o => rxr_we, ram_addr_o => rxr_waddr, ram_data_o => rxr_wdata,
			aux_we_o => rxa_we, aux_addr_o => rxa_waddr, aux_data_o => rxa_wdata,
			blk_done_o => blk_done, blk_base_o => blk_base, blk_page_o => blk_page,
			blk_ok_o => blk_ok, blk_assm_o => blk_assm,
			frame_ok_o => rx_frame_ok_o, frame_err_o => rx_frame_err_o,
			fmt_valid_o => fmt_valid_o, fmt_bad_o => fmt_bad_o, fmt_o => fmt_o, sync_o => open);

	u_rx_ram : entity work.aes50_dpram
		generic map (G_AW => AW, G_DW => 24)
		port map (wclk_i => clk50_i, we_i => rxr_we, waddr_i => rxr_waddr, wdata_i => rxr_wdata,
				  rclk_i => clk50_i, raddr_i => rxr_raddr, rdata_o => rxr_rdata);
	u_rx_aux_ram : entity work.aes50_dpram
		generic map (G_AW => 8, G_DW => 16)
		port map (wclk_i => clk50_i, we_i => rxa_we, waddr_i => rxa_waddr, wdata_i => rxa_wdata,
				  rclk_i => clk50_i, raddr_i => rxa_raddr, rdata_o => rxa_rdata);

	-- stream a good block out right after its frame (288 audio words, 44 aux words, in parallel)
	process (clk50_i)
	begin
		if rising_edge(clk50_i) then
			rx_block_o		<= '0';
			rx_block_drop_o	<= '0';
			rx_assm_o		<= '0';
			if blk_done = '1' then
				if blk_ok = '1' then
					rx_block_o	<= '1';
					rx_assm_o	<= blk_assm;
					st_on		<= '1';
					st_w		<= (others => '0');
					st_s		<= (others => '0');
					st_addr		<= blk_base;
					sa_left		<= to_unsigned(C_AUX_WORDS_PER_FRAME, 6);
					sa_j		<= (others => '0');
					sa_page		<= blk_page;
				else
					rx_block_drop_o <= '1';
				end if;
			end if;
			-- audio: the address is registered here, the RAM registers its data: valid / slot two clocks later
			st_v_d	<= st_on;	st_v_dd	<= st_v_d;
			st_w_d	<= st_w;	st_w_dd	<= st_w_d;
			if st_on = '1' then
				rxr_raddr	<= st_addr;
				st_addr		<= st_addr + 1;
				if st_w = C_AUDIO_CHANNELS - 1 then
					st_w <= (others => '0');
					if st_s = block_frames('1') - 1 then st_on <= '0'; else st_s <= st_s + 1; end if;
				else
					st_w <= st_w + 1;
				end if;
			end if;
			par_out_valid_o	<= st_v_dd;
			par_out_sample_o <= rxr_rdata;
			if fs96_i = '1' and st_w_dd >= 24 then
				par_out_ch_o	<= std_logic_vector(st_w_dd - 24);
				par_out_phase_o	<= '1';
			else
				par_out_ch_o	<= std_logic_vector(st_w_dd);
				par_out_phase_o	<= '0';
			end if;
			-- aux
			-- aux: the RAM reads the next unread word every clock (rxa_raddr follows the pointer), so a read
			-- (aux_rx_rd_i) finds its word on the RAM output in the next clock and moves the pointer on
			if aux_rx_rd_i = '1' and sa_left /= 0 and blk_done = '0' then
				if sa_j = 0 then sa_f <= '1'; else sa_f <= '0'; end if;
				sa_j		<= sa_j + 1;
				sa_left		<= sa_left - 1;
			end if;
			if rx_rst = '1' then
				st_on <= '0';
				sa_left <= (others => '0');
			end if;
		end if;
	end process;

end architecture;
