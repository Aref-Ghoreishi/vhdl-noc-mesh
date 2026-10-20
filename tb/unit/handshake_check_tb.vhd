-- =============================================================================
-- File    : handshake_check_tb.vhd
-- Purpose : Negative test: handshake_check must flag every kind of contract violation.
-- Author  : Aref Ghoreishi
-- License : MIT (see LICENSE)
-- SPDX-License-Identifier: MIT
-- =============================================================================
-- Planted violations: valid dropped before ready, packet changed while waiting,
-- and an unknown valid. A correct hold-until-ready sender and back-to-back
-- transfers must not count. The checker's own error reports (3 of them) are
-- expected; the verdict is the violation count.
library ieee;
use ieee.std_logic_1164.all;
use std.env.all;
use work.noc_pkg.all;

entity handshake_check_tb is
end entity handshake_check_tb;

architecture sim of handshake_check_tb is
  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal valid : std_logic := '0';
  signal ready : std_logic := '0';
  signal pkt   : packet_t  := DEFAULT_PACKET;
  signal viol  : natural;
begin

  clk <= not clk after 5 ns;

  dut : entity work.handshake_check
    generic map (
      NAME => "handshake_check_tb (planted violation)"
    )
    port map (
      clk        => clk,
      rst        => rst,
      valid      => valid,
      ready      => ready,
      packet     => pkt,
      violations => viol
    );

  main : process
    variable errors : natural := 0;

    procedure drive(v, r : std_logic; tag : natural) is
    begin
      wait until falling_edge(clk);
      valid          <= v;
      ready          <= r;
      pkt.time_stamp <= tag;
    end procedure;

    procedure expect(name : string; n : natural) is
    begin
      wait until falling_edge(clk);
      if viol /= n then
        report name & ": violations=" & integer'image(viol) & " expected " & integer'image(n)
          severity error;
        errors := errors + 1;
      end if;
    end procedure;
  begin
    wait for 22 ns;
    rst <= '0';
    -- correct: held for 3 cycles, then accepted
    drive('1', '0', 1); drive('1', '0', 1); drive('1', '0', 1); drive('1', '1', 1); drive('0', '0', 0);
    expect("correct hold", 0);
    -- valid dropped before ready
    drive('1', '0', 2); drive('0', '0', 0); drive('0', '0', 0);
    expect("dropped valid", 1);
    -- packet changed while waiting
    drive('1', '0', 3); drive('1', '0', 4); drive('1', '1', 4); drive('0', '0', 0);
    expect("changed packet", 2);
    -- unknown valid
    drive('X', '1', 0); drive('0', '0', 0);
    expect("X on valid", 3);
    -- back-to-back transfers are fine
    drive('1', '1', 5); drive('1', '1', 6); drive('0', '0', 0);
    expect("back-to-back", 3);

    if errors = 0 then
      report "HANDSHAKE_CHECK_TB PASS violations_detected=" & integer'image(viol);
    else
      report "HANDSHAKE_CHECK_TB FAIL errors=" & integer'image(errors) severity failure;
    end if;
    finish;
  end process main;

end architecture sim;
