-- Real I2C master: successful init, NACK at each byte and a stuck bus, plus PLL lock qualification.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
entity tb_pll_faults is end;
architecture sim of tb_pll_faults is
 signal clk : std_logic := '0';
 signal rst : std_logic := '1';
 signal busy, error, scl_en, sda_en, scl, sda : std_logic;
 signal stuck : boolean := false;
 signal nack : natural := 0;
 signal stretch_at : natural := 0;
 signal late_stuck : boolean := false;
 signal bit_count : natural := 0;
 signal transfers : natural := 0;
 signal lock_n : std_logic := '1';
 signal sync_pin : std_logic := '0';
 signal health, clock_ok : std_logic;
begin
 clk <= not clk after 10 ns;
 sync_pin <= not sync_pin after 80 ns;
 scl <= '0' when stuck or scl_en = '1' or late_stuck else '1';
 sda <= '1' when nack /= 0 and bit_count = nack else '0';
 process(scl_en, rst) begin
 if rst = '1' then late_stuck <= false;
 elsif rising_edge(scl_en) and stretch_at /= 0 and transfers = 12 and bit_count = stretch_at then late_stuck <= true; end if;
 end process;
 process(scl, sda_en, rst) begin
 if rst = '1' then bit_count <= 0; transfers <= 0;
 elsif rising_edge(sda_en) and scl = '1' then bit_count <= 0; transfers <= transfers + 1;
 elsif rising_edge(scl) then bit_count <= bit_count + 1; end if;
 end process;
 dut : entity work.aes50_cs2x00_pll_controller
 generic map(G_CLK_HZ => 1000000, G_I2C_HZ => 100000)
 port map(clk_i => clk, rst_i => rst, pll_mult_value_i => 8246337,
 cs2x00_init_busy_o => busy, cs2x00_init_error_o => error,
 sda_i => sda, scl_i => scl, sda_en_o => sda_en, scl_en_o => scl_en, scl_o => open, sda_o => open);
 link : entity work.aes50_link_ctrl
 port map(clk_i => clk, rst_i => rst, aes_clk_a_rx_i => sync_pin, aes_clk_b_rx_i => sync_pin,
 pll_lock_n_i => lock_n, rx_dv_i => '0', wd_aes_clk_timeout_i => 25,
 wd_aes_rx_dv_timeout_i => 7500, mdix_timer_1ms_i => 50000, aes_clk_ok_ref_i => 20,
 mdix_o => open, aes_clock_ok_o => clock_ok, clock_health_good_o => health, rx_ok_o => open, clk625_o => open);
 process
 procedure clocks(n : natural) is begin for i in 1 to n loop wait until falling_edge(clk); end loop; end;
 procedure reset is begin rst <= '1'; clocks(5); rst <= '0'; clocks(1); end;
 begin
 reset; clocks(100);
 assert health = '0' report "unlocked PLL reported healthy" severity failure;
 lock_n <= '0'; clocks(30);
 assert health = '1' and clock_ok = '1' report "lock did not qualify" severity failure;
 lock_n <= '1'; clocks(5);
 assert health = '0' and clock_ok = '0' report "lock loss ignored" severity failure;
 lock_n <= '0'; clocks(10);
 assert health = '0' report "lock recovered without qualification" severity failure;
 clocks(20); assert health = '1' severity failure;
 clocks(10000);
 assert busy = '0' and error = '0' report "ACKed init failed" severity failure;
 for byte in 1 to 3 loop
  nack <= byte * 9; reset; clocks(3000);
  assert error = '1' and busy = '1' report "NACK did not latch failure" severity failure;
  clocks(1000); assert error = '1' report "failure not latched" severity failure;
 end loop;
 nack <= 0;
 -- On the final register's last data bit, busy falls before the final ACK and STOP.
 stretch_at <= 26; reset; clocks(12000);
 assert late_stuck and transfers = 12 and error = '1' and busy = '1' report "late stuck SCL was reported successful" severity failure;
 stretch_at <= 0; stuck <= true; reset; clocks(3000);
 assert error = '1' and busy = '1' report "stuck SCL did not time out" severity failure;
 stuck <= false; reset; clocks(10000);
 assert error = '0' and busy = '0' report "reset did not recover" severity failure;
 write(output, string'("PASS tb_pll_faults: ACKs, three NACK positions, early/final-ACK stuck SCL, reset recovery and lock health") & LF);
 std.env.stop; wait;
 end process;
 process begin wait for 5 ms; assert false report "timeout" severity failure; end process;
end;
