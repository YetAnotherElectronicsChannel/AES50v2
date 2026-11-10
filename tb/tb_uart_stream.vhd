-- Continuous traffic must drain a small FIFO without a timeout-sized pause.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
entity tb_uart_stream is end;
architecture sim of tb_uart_stream is
 signal clk : std_logic := '0';
 signal rst : std_logic := '1';
 signal serial : std_logic := '1';
 signal req, awe, done, overflow : std_logic := '0';
 signal addr : unsigned(7 downto 0);
 signal word : std_logic_vector(15 downto 0);
 type aux_ram_t is array(0 to 127) of std_logic_vector(15 downto 0);
 signal aux_ram : aux_ram_t;
 signal dec_we : std_logic := '0';
 signal dec_word : std_logic_vector(15 downto 0);
 signal aux_start : std_logic := '0';
 signal uart_out, decoded : std_logic;
 signal byte : std_logic_vector(7 downto 0);
 signal received, drops : natural := 0;
 signal bit_time : natural range 0 to 65535 := 16;
 signal tx_start, tx_busy, tx_pin, rx_valid : std_logic := '0';
 signal fwr : std_logic := '0';
 signal foverflow : std_logic;
begin
 clk <= not clk after 10 ns;

 enc : entity work.aes50_aux_uart_enc
 generic map(G_FIFO_AW => 4)
 port map(clk_i => clk, rst_i => rst, uart_i => serial, clks_per_bit_i => 32,
 timeout_clks_i => 500000, fs48_i => '1', req_i => req, req_page_i => '0',
 aux_we_o => awe, aux_addr_o => addr, aux_data_o => word, done_o => done, overflow_o => overflow);
 dec : entity work.aes50_aux_uart_dec
 port map(clk_i => clk, rst_i => rst, aux_we_i => dec_we, aux_data_i => dec_word,
 aux_start_i => aux_start, clks_per_bit_i => 32, uart_o => uart_out);
 rx : entity work.aes50_uart_rx
 port map(clk_i => clk, rx_i => uart_out, clks_per_bit_i => 32, valid_o => decoded, data_o => byte);
 zero_tx : entity work.aes50_uart_tx
 port map(clk_i => clk, clks_per_bit_i => bit_time, start_i => tx_start, data_i => x"5A", busy_o => tx_busy, tx_o => tx_pin);
 zero_rx : entity work.aes50_uart_rx
 port map(clk_i => clk, clks_per_bit_i => bit_time, rx_i => tx_pin, valid_o => rx_valid, data_o => open);
 fifo : entity work.aes50_fifo
 generic map(G_AW => 2)
 port map(clk_i => clk, rst_i => rst, wr_en_i => fwr, wr_data_i => x"00", rd_en_i => '0',
 rd_data_o => open, empty_o => open, count_o => open, overflow_o => foverflow);
 process(clk) begin
 if rising_edge(clk) then
  if awe = '1' then aux_ram(to_integer(addr(6 downto 0))) <= word; end if;
  if overflow = '1' then drops <= drops + 1; end if;
  if decoded = '1' then
   assert byte = std_logic_vector(to_unsigned(received mod 256, 8)) report "UART stream got " & integer'image(to_integer(unsigned(byte))) & " expected " & integer'image(received) severity failure;
   received <= received + 1;
  end if;
 end if;
 end process;
 process
 begin
 wait until rst = '0';
 loop
  wait until falling_edge(clk); req <= '1';
  wait until falling_edge(clk); req <= '0';
  wait until done = '1'; wait for 20 us;
 end loop;
 end process;
 process
 begin
 loop
  wait until done = '1';
  for j in 0 to 43 loop
   wait until falling_edge(clk);
   dec_word <= aux_ram(j);
   if j = 0 then aux_start <= '1'; else aux_start <= '0'; end if;
   dec_we <= '1';
   wait until falling_edge(clk); dec_we <= '0';
   for c in 1 to 19 loop wait until falling_edge(clk); end loop;
  end loop;
 end loop;
 end process;
 process
 procedure clocks(n : natural) is begin for i in 1 to n loop wait until falling_edge(clk); end loop; end;
 variable data : std_logic_vector(7 downto 0);
 begin
 clocks(5); rst <= '0'; clocks(5);
 for b in 0 to 79 loop
  data := std_logic_vector(to_unsigned(b, 8));
  serial <= '0'; clocks(32);
  for k in 0 to 7 loop serial <= data(k); clocks(32); end loop;
  serial <= '1'; clocks(32);
 end loop;
 -- Short tail uses the normal idle flush; the continuous part must already be delivered.
 clocks(10000);
 assert received >= 72 and drops = 0 report "continuous UART stalled or overflowed" severity failure;
 clocks(500000);
 assert received = 80 report "short tail not flushed" severity failure;
 -- Full FIFO rejects a write with a visible pulse, then clears the pulse.
 fwr <= '1'; clocks(3); assert foverflow = '0' severity failure;
 clocks(1); assert foverflow = '1' report "overflow not exposed" severity failure;
 fwr <= '0'; clocks(1); assert foverflow = '0' severity failure;
 -- Disabling an active TX aborts it safely, and re-enabling starts a fresh byte.
 tx_start <= '1'; clocks(1); tx_start <= '0'; clocks(30);
 bit_time <= 0; clocks(70000);
 assert tx_busy = '0' and tx_pin = '1' and rx_valid = '0' report "zero bit time not disabled" severity failure;
 bit_time <= 16; clocks(5); tx_start <= '1'; clocks(1); tx_start <= '0'; clocks(200);
 assert tx_busy = '0' report "UART did not recover after enable" severity failure;
 write(output, string'("PASS tb_uart_stream: 80 ordered bytes, continuous input, idle tail, FIFO overflow and zero bit time") & LF);
 std.env.stop; wait;
 end process;
 process begin wait for 20 ms; assert false report "timeout" severity failure; end process;
end;
