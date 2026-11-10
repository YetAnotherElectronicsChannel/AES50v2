-- Regression for header truncation and loss of either half of a 44.1k block.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.aes50_pkg.all;
entity tb_rx_recovery is end;
architecture sim of tb_rx_recovery is
 signal clk : std_logic := '0';
 signal rst : std_logic := '1';
 signal start, assm, busy, txen : std_logic := '0';
 signal txd, rd : std_logic_vector(1 downto 0);
 signal dv, synced, done, ok, fv, fb, ferr : std_logic;
 signal manual : boolean := false;
 signal mdv : std_logic := '0';
 signal mrd : std_logic_vector(1 downto 0) := "00";
 signal cut_half : integer := -1;
 signal half, dib : natural := 0;
 signal ndone, nfmt, nerr : natural := 0;
begin
 clk <= not clk after 10 ns;
 u_tx : entity work.aes50_tx_framer
 generic map (G_AW => 10)
 port map (clk_i => clk, rst_i => rst, fs48_i => '0', i2s_i => '0', start_i => start,
 base_i => (others => '0'), assm_i => assm, aux_valid_i => '0', busy_o => busy, frame_o => open,
 ram_addr_o => open, ram_data_i => x"123456", aux_addr_o => open, aux_data_i => x"0000",
 rmii_txd_o => txd, rmii_tx_en_o => txen);
 dv <= mdv when manual else '0' when half = cut_half and dib > 1000 else txen;
 rd <= mrd when manual else txd;
 u_rx : entity work.aes50_rx_deframer
 port map (clk_i => clk, rst_i => rst, fs48_i => '0', rmii_crs_dv_i => dv, rmii_rxd_i => rd,
 ram_we_o => open, ram_addr_o => open, ram_data_o => open,
 aux_we_o => open, aux_addr_o => open, aux_data_o => open,
 blk_done_o => done, blk_base_o => open, blk_page_o => open, blk_ok_o => ok, blk_assm_o => open,
 frame_ok_o => open, frame_err_o => ferr, fmt_valid_o => fv, fmt_bad_o => fb, fmt_o => open, sync_o => synced);
 process(clk)
 variable prev : std_logic := '0';
 begin
 if rising_edge(clk) then
  if start = '1' then half <= 0; end if;
  if txen = '1' then dib <= dib + 1;
  else dib <= 0; if prev = '1' then half <= half + 1; end if; end if;
  prev := txen;
  if done = '1' and ok = '1' then ndone <= ndone + 1; end if;
  if fv = '1' or fb = '1' then nfmt <= nfmt + 1; end if;
  if ferr = '1' then nerr <= nerr + 1; end if;
 end if;
 end process;
 process
 procedure clocks(n : natural) is begin for i in 1 to n loop wait until falling_edge(clk); end loop; end;
 procedure send(a : std_logic; cut : integer) is begin
  assm <= a; cut_half <= cut; start <= '1'; clocks(1); start <= '0';
  wait until busy = '0'; clocks(100);
 end;
 variable before, formats, errors : natural;
 variable octet : std_logic_vector(7 downto 0);
 begin
 clocks(5); rst <= '0'; clocks(5);
 for h in 0 to 1 loop
  send('1', -1); assert synced = '1' report "ASSM did not synchronize" severity failure;
  before := ndone;
  send('0', h);
  assert synced = '0' and ndone = before report "cut half did not invalidate phase" severity failure;
  send('0', -1);
  assert ndone = before report "unrelated halves played before ASSM" severity failure;
  send('1', -1);
  assert ndone = before + 1 report "ASSM did not restore blocks" severity failure;
 end loop;
 manual <= true;
 for stop_at in 0 to 87 loop
  formats := nfmt; errors := nerr;
  mdv <= '1'; mrd <= "01"; clocks(31); mrd <= "11"; clocks(1);
  for d in 0 to stop_at - 1 loop
   octet := hdr_byte(d / 4, '0', '1');
   mrd <= octet(2*(d mod 4)+1 downto 2*(d mod 4)); clocks(1);
  end loop;
  mdv <= '0'; mrd <= "00"; clocks(100);
  assert nfmt = formats report "truncated header published format" severity failure;
  assert nerr = errors + 1 report "truncated header not reported" severity failure;
 end loop;
 report "PASS tb_rx_recovery: both 44.1k halves and all header truncation offsets";
 -- Makefile expects an unprefixed PASS line.
 std.textio.write(std.textio.output, string'("PASS tb_rx_recovery") & LF);
 std.env.stop; wait;
 end process;
 process begin wait for 10 ms; assert false report "timeout" severity failure; end process;
end;
