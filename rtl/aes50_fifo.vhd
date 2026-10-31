-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE (v2)
-- File         : <aes50_fifo.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel) - based on code from: vhdlwhiz.com
--
-- Description  : Single-clock FIFO, depth 2**G_AW - 1.  Same read timing as
--                the v1 ring buffer: rd_data_o always shows the oldest entry
--                one clock after it was written / after the previous read.
--
-- License      : No license information in files form vhdlwhiz.com
-- ===========================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aes50_fifo is
	generic (
		G_AW			: natural := 4;			-- address width, depth = 2**G_AW - 1
		G_DW			: natural := 8
	);
	port (
		clk_i			: in  std_logic;
		rst_i			: in  std_logic;
		wr_en_i			: in  std_logic;		-- ignored when full
		wr_data_i		: in  std_logic_vector(G_DW - 1 downto 0);
		rd_en_i			: in  std_logic;		-- ignored when empty
		rd_data_o		: out std_logic_vector(G_DW - 1 downto 0);
		empty_o			: out std_logic;
		count_o			: out unsigned(G_AW - 1 downto 0)
	);
end entity;

architecture rtl of aes50_fifo is

	type mem_t is array (0 to 2 ** G_AW - 1) of std_logic_vector(G_DW - 1 downto 0);
	signal mem			: mem_t;
	signal wr_ptr		: unsigned(G_AW - 1 downto 0) := (others => '0');
	signal rd_ptr		: unsigned(G_AW - 1 downto 0) := (others => '0');
	signal count		: unsigned(G_AW - 1 downto 0);

begin

	count		<= wr_ptr - rd_ptr;
	count_o		<= count;
	empty_o		<= '1' when count = 0 else '0';

	process (clk_i)
	begin
		if rising_edge(clk_i) then
			if wr_en_i = '1' and count /= 2 ** G_AW - 1 then
				mem(to_integer(wr_ptr)) <= wr_data_i;
				wr_ptr <= wr_ptr + 1;
			end if;
			if rd_en_i = '1' and count /= 0 then
				rd_ptr <= rd_ptr + 1;
			end if;
			rd_data_o <= mem(to_integer(rd_ptr));
			if rst_i = '1' then
				wr_ptr <= (others => '0');
				rd_ptr <= (others => '0');
			end if;
		end if;
	end process;

end architecture;
