-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE (v2)
-- File         : <aes50_dpram.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
--
-- Description  : Simple dual-port RAM (1 write port, 1 registered read port)
--                with independent clocks.  Written as the common inference
--                template understood by Efinity, Diamond/Synplify, ISE/XST,
--                Vivado and Yosys.
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

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aes50_dpram is
	generic (
		G_AW			: natural := 9;
		G_DW			: natural := 24
	);
	port (
		wclk_i			: in  std_logic;
		we_i			: in  std_logic;
		waddr_i			: in  unsigned(G_AW - 1 downto 0);
		wdata_i			: in  std_logic_vector(G_DW - 1 downto 0);

		rclk_i			: in  std_logic;
		raddr_i			: in  unsigned(G_AW - 1 downto 0);
		rdata_o			: out std_logic_vector(G_DW - 1 downto 0)
	);
end entity;

architecture rtl of aes50_dpram is

	type ram_t is array (0 to 2 ** G_AW - 1) of std_logic_vector(G_DW - 1 downto 0);
	signal ram : ram_t := (others => (others => '0'));

begin

	process (wclk_i)
	begin
		if rising_edge(wclk_i) then
			if we_i = '1' then
				ram(to_integer(waddr_i)) <= wdata_i;
			end if;
		end if;
	end process;

	process (rclk_i)
	begin
		if rising_edge(rclk_i) then
			rdata_o <= ram(to_integer(raddr_i));
		end if;
	end process;

end architecture;
