-- =============================================================================
-- File    : handshake_check.vhd
-- Purpose : Simulation monitor for the valid/ready contract on one link.
-- Author  : Aref Ghoreishi
-- License : MIT (see LICENSE)
-- SPDX-License-Identifier: MIT
-- =============================================================================
-- A transfer happens on a rising edge where valid = '1' and ready = '1'. If an
-- edge passes with valid = '1' and ready /= '1', the sender must still offer
-- the same packet on the next edge; anything else would lose or corrupt it.
-- Each violation is reported (severity error) and counted on 'violations'.
library ieee;
use ieee.std_logic_1164.all;
use work.noc_pkg.all;

entity handshake_check is
  generic (
    NAME : string := "link"
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    valid      : in  std_logic;
    ready      : in  std_logic;
    packet     : in  packet_t;
    violations : out natural := 0
  );
end entity handshake_check;

architecture sim of handshake_check is
begin

  process (clk)
    variable pending : boolean := false;   -- offered but not accepted on the last edge
    variable held    : packet_t;
    variable n       : natural := 0;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        pending := false;
      else
        if valid /= '0' and valid /= '1' then
          report NAME & ": valid is " & std_logic'image(valid) severity error;
          n := n + 1;
        end if;
        if pending then
          if valid /= '1' then
            report NAME & ": contract violation, valid dropped before the receiver was ready (packet lost)"
              severity error;
            n := n + 1;
          elsif packet /= held then
            report NAME & ": contract violation, packet changed while waiting for ready"
              severity error;
            n := n + 1;
          end if;
        end if;
        pending := valid = '1' and ready /= '1';
        held    := packet;
      end if;
      violations <= n;
    end if;
  end process;

end architecture sim;
