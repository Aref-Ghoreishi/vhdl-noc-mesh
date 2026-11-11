-- =============================================================================
-- File    : master_tb.vhd
-- Purpose : Directed test of master_ip input handling.
-- Author  : Aref Ghoreishi
-- License : MIT (see LICENSE)
-- SPDX-License-Identifier: MIT
-- =============================================================================
-- CHECK_PADDING = true:  DATA_FILE = tb/unit/data/master_padding.txt. Every
--   transferred packet is compared with EXPECTED: bytes from valid_size on are
--   zero, the blank line is skipped, and the 4th request is forwarded to the
--   other master. out_ready toggles, so each packet must be held until accepted.
-- CHECK_PADDING = false: DATA_FILE has an invalid line. The master must stop the
--   run with "<file>:<line>: ..." (the Makefile checks message and exit code);
--   reaching the end of this testbench is a failure.
library ieee;
use ieee.std_logic_1164.all;
use std.env.all;
use work.noc_pkg.all;

entity master_tb is
  generic (
    DATA_FILE     : string  := "tb/unit/data/master_padding.txt";
    LOG_PREFIX    : string  := "build/master_tb_";
    CHECK_PADDING : boolean := true
  );
end entity master_tb;

architecture sim of master_tb is
  type exp_t is record
    dst  : addr_t;
    size : natural;
    data : std_logic_vector(63 downto 0);
  end record;
  type exp_array_t is array (natural range <>) of exp_t;

  constant EXPECTED : exp_array_t := (
    ("0010", 3, x"0000000000030201"),   -- 2 3 1 2 3 4 5 6 7 8
    ("0100", 0, x"0000000000000000"),   -- 4 0 9 9 9 9 9 9 9 9
    ("0110", 8, x"0807060504030201"),   -- 6 8 1 2 3 4 5 6 7 8   (after a blank line)
    ("1000", 1, x"00000000000000FF"),   -- 8 1 255 1 1 1 1 1 1 1
    ("1001", 1, x"00000000000000FF"),   -- forward of request 4 to P9
    ("0010", 2, x"0000000000000805")    -- 2 2 5 8 6 7 1 4 3 2
  );

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal ov   : std_logic;
  signal ordy : std_logic := '0';
  signal op   : packet_t;
  signal viol : natural;
begin

  clk <= not clk after 5 ns;

  dut : entity work.master_ip
    generic map (
      MY_ADDR    => "0001",
      OTHER_ADDR => "1001",
      DATA_FILE  => DATA_FILE,
      RESP_LOG   => LOG_PREFIX & "responses.txt",
      HOST_LOG   => LOG_PREFIX & "host.txt"
    )
    port map (
      clk        => clk,
      rst        => rst,
      out_valid  => ov,
      out_packet => op,
      out_ready  => ordy,
      in_valid   => '0',
      in_packet  => DEFAULT_PACKET,
      in_ready   => open
    );

  chk : entity work.handshake_check
    generic map (
      NAME => "master_tb output"
    )
    port map (
      clk        => clk,
      rst        => rst,
      valid      => ov,
      ready      => ordy,
      packet     => op,
      violations => viol
    );

  -- out_ready toggles every cycle once reset is released
  ordy <= '0' when rst = '1' else not ordy after 10 ns;

  main : process
    variable n, errors : natural := 0;
    variable p         : packet_t;
  begin
    wait for 22 ns;
    rst <= '0';
    for c in 1 to 400 loop
      wait until rising_edge(clk);
      if ov = '1' and ordy = '1' then
        p := op;
        if n > EXPECTED'high then
          report "unexpected extra packet to " & to_string(p.dst_addr) severity error;
          errors := errors + 1;
        elsif p.dst_addr /= EXPECTED(n).dst or p.valid_size /= EXPECTED(n).size or
              p.payload /= EXPECTED(n).data or p.src_addr /= "0001" or
              p.resp_addr /= "0001" or p.hop_count /= 0 then
          report "packet " & integer'image(n) & ": dst=" & to_string(p.dst_addr) &
                 " size=" & integer'image(p.valid_size) & " data=" & to_hstring(p.payload) &
                 " expected dst=" & to_string(EXPECTED(n).dst) & " size=" &
                 integer'image(EXPECTED(n).size) & " data=" & to_hstring(EXPECTED(n).data)
            severity error;
          errors := errors + 1;
        end if;
        n := n + 1;
      end if;
    end loop;

    if not CHECK_PADDING then
      report "MASTER_TB FAIL: invalid input was not rejected" severity failure;
    elsif errors = 0 and n = EXPECTED'length and viol = 0 then
      report "MASTER_TB PASS packets=" & integer'image(n);
    else
      report "MASTER_TB FAIL errors=" & integer'image(errors) & " packets=" & integer'image(n) &
             " violations=" & integer'image(viol)
        severity failure;
    end if;
    finish;
  end process main;

end architecture sim;
