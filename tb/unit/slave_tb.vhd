-- =============================================================================
-- File    : slave_tb.vhd
-- Purpose : Directed test of slave_ip: every operation, valid_size handling, reply header.
-- Author  : Aref Ghoreishi
-- License : MIT (see LICENSE)
-- SPDX-License-Identifier: MIT
-- =============================================================================
-- For every slave: valid_size 0, 1 and 8, and two requests with non-zero bytes
-- past valid_size (one is P9 line 4), which must be ignored. Expected payloads
-- and check bytes come from the Python golden model (scripts/check.py,
-- slave_op). The test also checks the reply header and that the reply is held
-- while out_ready = '0' and dropped right after its transfer.
library ieee;
use ieee.std_logic_1164.all;
use std.env.all;
use work.noc_pkg.all;

entity slave_tb is
end entity slave_tb;

architecture sim of slave_tb is
  type case_t is record
    slave : natural;
    size  : natural;
    data  : std_logic_vector(63 downto 0);   -- request payload, byte 0 = bits 7..0
    reply : std_logic_vector(63 downto 0);   -- expected reply payload
    check : std_logic_vector(7 downto 0);    -- expected check byte
    name  : string(1 to 48);
  end record;
  type case_array_t is array (natural range <>) of case_t;

  function mk(slave, size : natural; data, reply, check : std_logic_vector; name : string)
    return case_t is
    variable padded : string(1 to 48) := (others => ' ');
  begin
    padded(1 to name'length) := name;
    return (slave, size, data, reply, check, padded);
  end function;

  constant CASES : case_array_t := (
    mk(2, 0, x"0203040506070809", x"0000000000000000", x"00", "P2 valid_size=0, padding non-zero"),
    mk(2, 1, x"07060504030201C8", x"00000000000000C8", x"00", "P2 valid_size=1"),
    mk(2, 8, x"09080B0D0C0A0E0F", x"0F0E0D0C0B0A0908", x"00", "P2 valid_size=8"),
    mk(2, 2, x"0203040107060805", x"0000000000000805", x"00", "P2 valid_size=2, padding non-zero (P9 line 4)"),
    mk(2, 5, x"63584D0009020103", x"0000000903020100", x"00", "P2 valid_size=5, padding non-zero"),
    mk(4, 0, x"0203040506070809", x"0000000000000000", x"00", "P4 valid_size=0, padding non-zero"),
    mk(4, 1, x"07060504030201C8", x"00000000000000C8", x"C8", "P4 valid_size=1"),
    mk(4, 8, x"09080B0D0C0A0E0F", x"09080B0D0C0A0E0F", x"00", "P4 valid_size=8"),
    mk(4, 2, x"0203040107060805", x"0000000000000805", x"0D", "P4 valid_size=2, padding non-zero (P9 line 4)"),
    mk(4, 5, x"63584D0009020103", x"0000000009020103", x"09", "P4 valid_size=5, padding non-zero"),
    mk(6, 0, x"0203040506070809", x"0000000000000000", x"00", "P6 valid_size=0, padding non-zero"),
    mk(6, 1, x"07060504030201C8", x"00000000000000C8", x"00", "P6 valid_size=1"),
    mk(6, 8, x"09080B0D0C0A0E0F", x"08090A0B0C0D0E0F", x"00", "P6 valid_size=8"),
    mk(6, 2, x"0203040107060805", x"0000000000000508", x"00", "P6 valid_size=2, padding non-zero (P9 line 4)"),
    mk(6, 5, x"63584D0009020103", x"0000000001020309", x"00", "P6 valid_size=5, padding non-zero"),
    mk(8, 0, x"0203040506070809", x"0000000000000000", x"00", "P8 valid_size=0, padding non-zero"),
    mk(8, 1, x"07060504030201C8", x"00000000000000C8", x"C8", "P8 valid_size=1"),
    mk(8, 8, x"09080B0D0C0A0E0F", x"09080B0D0C0A0E0F", x"5C", "P8 valid_size=8"),
    mk(8, 2, x"0203040107060805", x"0000000000000805", x"0D", "P8 valid_size=2, padding non-zero (P9 line 4)"),
    mk(8, 5, x"63584D0009020103", x"0000000009020103", x"0F", "P8 valid_size=5, padding non-zero")
  );

  constant ADDRS : addr_array_t(0 to 3) := ("0010", "0100", "0110", "1000");

  type sl4_t  is array (0 to 3) of std_logic;
  type pkt4_t is array (0 to 3) of packet_t;
  type nat4_t is array (0 to 3) of natural;

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal iv   : sl4_t  := (others => '0');
  signal ir   : sl4_t;
  signal ov   : sl4_t;
  signal ordy : sl4_t  := (others => '0');
  signal ip   : pkt4_t := (others => DEFAULT_PACKET);
  signal op   : pkt4_t;
  signal viol : nat4_t;
begin

  clk <= not clk after 5 ns;

  gen : for i in 0 to 3 generate
    dut : entity work.slave_ip
      generic map (
        MY_ADDR => ADDRS(i)
      )
      port map (
        clk        => clk,
        rst        => rst,
        in_valid   => iv(i),
        in_packet  => ip(i),
        in_ready   => ir(i),
        out_valid  => ov(i),
        out_packet => op(i),
        out_ready  => ordy(i)
      );
    chk : entity work.handshake_check
      generic map (
        NAME => "slave_tb output " & integer'image(i)
      )
      port map (
        clk        => clk,
        rst        => rst,
        valid      => ov(i),
        ready      => ordy(i),
        packet     => op(i),
        violations => viol(i)
      );
  end generate gen;

  main : process
    variable errors : natural := 0;
    variable i      : natural;
    variable p, r   : packet_t;
    variable waited : natural;

    procedure check(cond : boolean; msg : string) is
    begin
      if not cond then
        report msg severity error;
        errors := errors + 1;
      end if;
    end procedure;
  begin
    wait for 22 ns;
    rst <= '0';
    for c in CASES'range loop
      i            := CASES(c).slave / 2 - 1;      -- 2, 4, 6, 8 -> 0..3
      p            := DEFAULT_PACKET;
      p.src_addr   := "1001";
      p.resp_addr  := "0001";
      p.dst_addr   := ADDRS(i);
      p.valid_size := CASES(c).size;
      p.hop_count  := 3;
      p.time_stamp := 1000 + c;
      p.payload    := CASES(c).data;

      -- offer the request and hold it until accepted
      wait until falling_edge(clk);
      ip(i) <= p;
      iv(i) <= '1';
      loop
        wait until rising_edge(clk);
        exit when ir(i) = '1';
      end loop;
      wait until falling_edge(clk);
      iv(i) <= '0';

      -- receiver not ready for a few cycles: the reply must stay offered
      for k in 1 to 4 loop
        wait until rising_edge(clk);
      end loop;
      check(ov(i) = '1', CASES(c).name & ": reply not offered or not held");
      wait until falling_edge(clk);
      ordy(i) <= '1';
      waited  := 0;
      loop
        wait until rising_edge(clk);
        exit when ov(i) = '1';
        waited := waited + 1;
        if waited > 20 then
          check(false, CASES(c).name & ": no reply");
          exit;
        end if;
      end loop;
      r := op(i);
      wait until falling_edge(clk);
      ordy(i) <= '0';

      check(r.payload = CASES(c).reply, CASES(c).name & ": payload " & to_hstring(r.payload) &
            " expected " & to_hstring(CASES(c).reply));
      check(r.check_byte = CASES(c).check, CASES(c).name & ": check " & to_hstring(r.check_byte) &
            " expected " & to_hstring(CASES(c).check));
      check(r.src_addr = ADDRS(i), CASES(c).name & ": wrong src_addr");
      if CASES(c).slave = 2 or CASES(c).slave = 4 then
        check(r.dst_addr = "1001", CASES(c).name & ": reply not sent to P9");
      else
        check(r.dst_addr = "0001", CASES(c).name & ": reply not sent to P1");
      end if;
      check(r.resp_addr = "0001" and r.valid_size = CASES(c).size and r.hop_count = 3 and
            r.time_stamp = 1000 + c, CASES(c).name & ": header fields not preserved");
      wait until rising_edge(clk);
      check(ov(i) = '0', CASES(c).name & ": out_valid still high after the transfer");
    end loop;

    for k in 0 to 3 loop
      check(viol(k) = 0, "contract violations on slave " & integer'image(k));
    end loop;
    if errors = 0 then
      report "SLAVE_TB PASS cases=" & integer'image(CASES'length);
    else
      report "SLAVE_TB FAIL errors=" & integer'image(errors) severity failure;
    end if;
    finish;
  end process main;

end architecture sim;
