-- =============================================================================
-- File    : regression_tb.vhd
-- Purpose : Black-box regression tests for the switch and slave bugs of the original design.
-- Author  : Aref Ghoreishi
-- License : MIT (see LICENSE)
-- SPDX-License-Identifier: MIT
-- =============================================================================
--   A1 switch: 4 packets to one output while out_ready toggles every cycle;
--      all must come out (the original dequeued, then lost the packet when
--      ready dropped, and the output stayed dead).
--   A2 switch: one more packet with out_ready high must also come out.
--   B  slave: a request offered while a reply is still waiting must not be
--      lost (the original read in_ready = '1' in that state and ignored it).
--   C  slave: back-to-back requests give exactly one reply each (the original
--      held out_valid for several cycles and duplicated replies).
-- All four fail on the original RTL.
library ieee;
use ieee.std_logic_1164.all;
use std.env.all;
use work.noc_pkg.all;

entity regression_tb is
end entity regression_tb;

architecture sim of regression_tb is
  signal clk    : std_logic := '0';
  signal rst    : std_logic := '1';
  -- switch
  signal s_iv   : port_bits_t    := (others => '0');
  signal s_ird  : port_bits_t;
  signal s_ov   : port_bits_t;
  signal s_ordy : port_bits_t    := (others => '0');
  signal s_ip   : port_packets_t := (others => DEFAULT_PACKET);
  signal s_op   : port_packets_t;
  signal toggle : std_logic      := '0';
  -- slave
  signal v_iv   : std_logic := '0';
  signal v_ird  : std_logic;
  signal v_ov   : std_logic;
  signal v_ordy : std_logic := '0';
  signal v_ip   : packet_t  := DEFAULT_PACKET;
  signal v_op   : packet_t;

  signal sw_out_cnt, sw_in_cnt, sl_in_cnt, sl_out_cnt : natural := 0;
begin

  clk <= not clk after 5 ns;

  sw : entity work.noc_switch
    generic map (
      FIFO_DEPTH   => 2,
      DELAY_CYCLES => 3,
      SWITCH_ID    => "0101",
      ROUTE_TABLE  => NOC1_S5
    )
    port map (
      clk        => clk,
      rst        => rst,
      in_valid   => s_iv,
      in_packet  => s_ip,
      in_ready   => s_ird,
      out_valid  => s_ov,
      out_packet => s_op,
      out_ready  => s_ordy,
      fifo_level => open
    );

  sl : entity work.slave_ip
    generic map (
      MY_ADDR => "1000"
    )
    port map (
      clk        => clk,
      rst        => rst,
      in_valid   => v_iv,
      in_packet  => v_ip,
      in_ready   => v_ird,
      out_valid  => v_ov,
      out_packet => v_op,
      out_ready  => v_ordy
    );

  s_ordy <= (PORT_E => toggle, others => '1');

  count : process (clk)
  begin
    if rising_edge(clk) then
      if s_iv(PORT_N) = '1' and s_ird(PORT_N) = '1' then
        sw_in_cnt <= sw_in_cnt + 1;
      end if;
      if s_ov(PORT_E) = '1' and s_ordy(PORT_E) = '1' then
        sw_out_cnt <= sw_out_cnt + 1;
      end if;
      if v_iv = '1' and v_ird = '1' then
        sl_in_cnt <= sl_in_cnt + 1;
      end if;
      if v_ov = '1' and v_ordy = '1' then
        sl_out_cnt <= sl_out_cnt + 1;
      end if;
    end if;
  end process count;

  stim : process
    variable p      : packet_t := DEFAULT_PACKET;
    variable errors : natural  := 0;

    -- offer one packet on switch input N and hold it until accepted (50-cycle limit)
    procedure send_sw is
    begin
      wait until falling_edge(clk);
      s_iv(PORT_N) <= '1';
      for i in 1 to 50 loop
        wait until rising_edge(clk);
        exit when s_ird(PORT_N) = '1';
      end loop;
      wait until falling_edge(clk);
      s_iv(PORT_N) <= '0';
    end procedure;

    -- offer one request to the slave for a single cycle, as the original switch did
    procedure pulse_sl is
    begin
      wait until falling_edge(clk);
      v_iv <= '1';
      wait until falling_edge(clk);
      v_iv <= '0';
    end procedure;

    procedure cycles(n : natural) is
    begin
      for i in 1 to n loop
        wait until rising_edge(clk);
      end loop;
    end procedure;

    procedure result(name : string; got, want : natural) is
    begin
      if got = want then
        report name & " PASS (" & integer'image(got) & "/" & integer'image(want) & ")";
      else
        report name & " FAIL (" & integer'image(got) & "/" & integer'image(want) & ")"
          severity error;
        errors := errors + 1;
      end if;
    end procedure;
  begin
    p.dst_addr   := "0110";                 -- S5 routes destination 6 to the east port
    s_ip(PORT_N) <= p;
    v_ip.dst_addr <= "1000";
    wait for 22 ns;
    rst <= '0';

    -- A: switch output with toggling ready
    for i in 1 to 4 loop
      send_sw;
    end loop;
    for i in 1 to 60 loop
      wait until falling_edge(clk);
      toggle <= not toggle;
    end loop;
    result("A1 switch, ready toggling: packets out", sw_out_cnt, sw_in_cnt);
    wait until falling_edge(clk);
    toggle <= '1';
    send_sw;
    cycles(30);
    result("A2 switch, ready high afterwards: packets out", sw_out_cnt, sw_in_cnt);

    -- B: slave, request offered while the previous reply waits to be sent
    v_ordy <= '0';
    pulse_sl;                               -- request 1
    cycles(3);                              -- the reply is now waiting
    pulse_sl;                               -- request 2, accepted only if in_ready = '1'
    wait until falling_edge(clk);
    v_ordy <= '1';
    cycles(20);
    result("B  slave, request during send: replies for accepted requests", sl_out_cnt, sl_in_cnt);

    -- C: slave, requests offered continuously
    v_iv <= '1';
    cycles(30);
    wait until falling_edge(clk);
    v_iv <= '0';
    cycles(20);
    result("C  slave, back-to-back requests: replies for accepted requests", sl_out_cnt, sl_in_cnt);

    if errors = 0 then
      report "REGRESSION_TB PASS";
    else
      report "REGRESSION_TB FAIL errors=" & integer'image(errors) severity failure;
    end if;
    finish;
  end process stim;

end architecture sim;
