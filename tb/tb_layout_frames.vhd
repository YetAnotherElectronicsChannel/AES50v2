-- Independent wire round trips check every audio/aux word across ring wrap at all three formats.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.aes50_pkg.all;
entity tb_layout_frames is end;
architecture sim of tb_layout_frames is
 signal clk : std_logic := '0';
 signal rst : std_logic := '1';
 signal fs48, fs96, start, assm, busy, txen : std_logic := '0';
 signal base, raddr, waddr, bbase, got_base : unsigned(9 downto 0);
 signal rdata, wdata : std_logic_vector(23 downto 0);
 signal txd : std_logic_vector(1 downto 0);
 signal aaddr : unsigned(6 downto 0);
 signal awaddr : unsigned(7 downto 0);
 signal adata, awdata : std_logic_vector(15 downto 0);
 signal we, awe, done, ok, page, got_page : std_logic;
 signal ndone : natural := 0;
 type ram_t is array(0 to 1023) of std_logic_vector(23 downto 0);
 signal ram : ram_t;
 type aux_t is array(0 to 255) of std_logic_vector(15 downto 0);
 signal aux : aux_t;
 function pat(a : natural) return std_logic_vector is begin
 return std_logic_vector(to_unsigned((a * 40503 + 12345) mod 2**24, 24)); end;
begin
 clk <= not clk after 10 ns;
 tx : entity work.aes50_tx_framer
 port map(clk_i => clk, rst_i => rst, fs48_i => fs48, fs96_i => fs96, i2s_i => '0',
 start_i => start, base_i => base, assm_i => assm, aux_valid_i => '1', busy_o => busy, frame_o => open,
 ram_addr_o => raddr, ram_data_i => rdata, aux_addr_o => aaddr, aux_data_i => adata,
 rmii_txd_o => txd, rmii_tx_en_o => txen);
 rx : entity work.aes50_rx_deframer
 port map(clk_i => clk, rst_i => rst, fs48_i => fs48, fs96_i => fs96,
 rmii_crs_dv_i => txen, rmii_rxd_i => txd, ram_we_o => we, ram_addr_o => waddr, ram_data_o => wdata,
 aux_we_o => awe, aux_addr_o => awaddr, aux_data_o => awdata, blk_done_o => done,
 blk_base_o => bbase, blk_page_o => page, blk_ok_o => ok, blk_assm_o => open,
 frame_ok_o => open, frame_err_o => open, sync_o => open);
 process(clk) begin
 if rising_edge(clk) then
  rdata <= pat(to_integer(raddr));
  adata <= std_logic_vector(resize(aaddr,16) + 1234);
  if we = '1' then ram(to_integer(waddr)) <= wdata; end if;
  if awe = '1' then aux(to_integer(awaddr)) <= awdata; end if;
  if done = '1' then
   assert ok = '1' report "round-trip FCS failed" severity failure;
   ndone <= ndone + 1; got_base <= bbase; got_page <= page;
  end if;
 end if;
 end process;
 process
 procedure clocks(n : natural) is begin for i in 1 to n loop wait until falling_edge(clk); end loop; end;
 variable n0, words, aux_count : natural;
 begin
 assert block_words('1') = 288 and block_words('0') = 528 severity failure;
 assert aux_words('1') = 44 and aux_words('0') = 88 severity failure;
 for rate in 0 to 2 loop
  rst <= '1';
  if rate = 0 then fs48 <= '0'; words := 528; aux_count := 88;
  else fs48 <= '1'; words := 288; aux_count := 44; end if;
  if rate = 2 then fs96 <= '1'; else fs96 <= '0'; end if;
  clocks(5); rst <= '0'; clocks(5);
  for block_no in 0 to 3 loop
   n0 := ndone; base <= to_unsigned((block_no * words) mod 1024, 10);
   if block_no = 0 then assm <= '1'; else assm <= '0'; end if;
   start <= '1'; clocks(1); start <= '0'; wait until busy = '0'; clocks(30);
   assert ndone = n0 + 1 report "missing complete block" severity failure;
   for j in 0 to words - 1 loop
    assert ram((to_integer(got_base) + j) mod 1024) = pat((block_no * words + j) mod 1024)
     report "audio layout mismatch at rate " & integer'image(rate) & " word " & integer'image(j) severity failure;
   end loop;
   for j in 0 to aux_count - 1 loop
    assert aux(to_integer(unsigned'(got_page & to_unsigned(j,7)))) = std_logic_vector(to_unsigned(j + 1234,16))
     report "aux layout mismatch" severity failure;
   end loop;
  end loop;
 end loop;
 write(output, string'("PASS tb_layout_frames: all audio and aux words at 44.1/48/96k, four blocks per rate including ring wrap") & LF);
 std.env.stop; wait;
 end process;
 process begin wait for 10 ms; assert false report "timeout" severity failure; end process;
end;
