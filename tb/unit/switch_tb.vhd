-- =============================================================================
-- File    : switch_tb.vhd
-- Purpose : Directed and random test of noc_switch.
-- Author  : Aref Ghoreishi
-- License : MIT (see LICENSE)
-- SPDX-License-Identifier: MIT
-- =============================================================================
--   1. routing       every input sends one packet to every output (25 pairs)
--   2. fairness      all 5 inputs backlogged on one output: grants must rotate
--   3. backpressure  output not ready: nothing leaves, valid and packet are held,
--                    the input FIFOs fill and drop ready; all delivered on release
--   4. FIFO full     one input, output blocked: exactly FIFO_DEPTH packets are
--                    accepted, then in_ready = '0' and the sender holds
--   5. random        random destinations on all inputs, random ready on all outputs
-- Every packet carries src = input number and time_stamp = a per-input sequence
-- number. On every output transfer the scoreboard checks the output port, the
-- hop count, the payload, and that the sequence number is exactly the next one
-- for that input, which catches loss, duplication and reordering at once.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
use work.noc_pkg.all;

entity switch_tb is
  generic (
    FIFO_DEPTH : positive := 2;
    DELAY      : natural  := 1
  );
end entity switch_tb;

architecture sim of switch_tb is
  -- dest n leaves on port n, so the expected port of a packet is its destination
  constant ROUTE_TB : route_table_t := (0 => 0, 1 => 1, 2 => 2, 3 => 3, 4 => 4, others => 4);
  constant MAXP     : positive := 64;

  type plan_t       is array (0 to MAXP - 1) of natural;   -- destination per packet
  type plan_array_t is array (0 to 4) of plan_t;
  type int5_t       is array (0 to 4) of natural;
  type int55_t      is array (0 to 4, 0 to 4) of natural;
  type log_t        is array (0 to 255) of integer;
  type nat5_t       is array (0 to 4) of natural;

  signal clk       : std_logic := '0';
  signal rst       : std_logic := '1';
  signal in_valid  : port_bits_t := (others => '0');
  signal in_ready  : port_bits_t;
  signal out_valid : port_bits_t;
  signal out_ready : port_bits_t := (others => '0');
  signal in_pkt    : port_packets_t := (others => DEFAULT_PACKET);
  signal out_pkt   : port_packets_t;

  signal plan       : plan_array_t := (others => (others => 0));
  signal plan_len   : int5_t := (others => 0);
  signal go, done   : port_bits_t := (others => '0');
  signal ready_mode : int5_t := (others => 1);   -- 0 low, 1 high, 2 toggle, 3 random

  signal tx_cnt    : int5_t  := (others => 0);   -- accepted per input
  signal rx_cnt    : int5_t  := (others => 0);   -- delivered per input
  signal rx_pair   : int55_t := (others => (others => 0));
  signal rx_total  : natural := 0;
  signal sb_errors : natural := 0;
  signal log_port  : natural := 2;               -- output whose grant order is logged
  signal grant_log : log_t   := (others => -1);
  signal grant_len : natural := 0;
  signal log_clear : std_logic := '0';
  signal viol_out  : nat5_t;
  signal viol_in   : nat5_t;

  function payload_of(i, seq : natural) return std_logic_vector is
    variable p : std_logic_vector(PAYLOAD_BITS - 1 downto 0) := (others => '0');
  begin
    p(7 downto 0)   := std_logic_vector(to_unsigned(i, 8));
    p(23 downto 8)  := std_logic_vector(to_unsigned(seq, 16));
    p(63 downto 56) := x"A5";
    return p;
  end function;
begin

  clk <= not clk after 5 ns;

  dut : entity work.noc_switch
    generic map (
      FIFO_DEPTH   => FIFO_DEPTH,
      DELAY_CYCLES => DELAY,
      SWITCH_ID    => "0101",
      ROUTE_TABLE  => ROUTE_TB
    )
    port map (
      clk        => clk,
      rst        => rst,
      in_valid   => in_valid,
      in_packet  => in_pkt,
      in_ready   => in_ready,
      out_valid  => out_valid,
      out_packet => out_pkt,
      out_ready  => out_ready,
      fifo_level => open
    );

  -- The drivers must obey the contract too, so both sides are checked.
  gen_chk : for i in 0 to 4 generate
    chk_out : entity work.handshake_check
      generic map (
        NAME => "switch_tb output " & integer'image(i)
      )
      port map (
        clk        => clk,
        rst        => rst,
        valid      => out_valid(i),
        ready      => out_ready(i),
        packet     => out_pkt(i),
        violations => viol_out(i)
      );
    chk_in : entity work.handshake_check
      generic map (
        NAME => "switch_tb input " & integer'image(i)
      )
      port map (
        clk        => clk,
        rst        => rst,
        valid      => in_valid(i),
        ready      => in_ready(i),
        packet     => in_pkt(i),
        violations => viol_in(i)
      );
  end generate gen_chk;

  -- Input drivers: send the plan in order, holding each packet until accepted
  gen_drv : for i in 0 to 4 generate
    drv : process
      variable seq : natural  := 0;
      variable p   : packet_t := DEFAULT_PACKET;
    begin
      wait until go(i) = '1';
      for k in 0 to plan_len(i) - 1 loop
        wait until falling_edge(clk);
        p.src_addr   := std_logic_vector(to_unsigned(i, 4));
        p.dst_addr   := std_logic_vector(to_unsigned(plan(i)(k), 4));
        p.time_stamp := seq;
        p.hop_count  := 0;
        p.payload    := payload_of(i, seq);
        in_pkt(i)    <= p;
        in_valid(i)  <= '1';
        loop
          wait until rising_edge(clk);
          exit when in_ready(i) = '1';         -- value at the edge: transfer
        end loop;
        seq := seq + 1;
      end loop;
      wait until falling_edge(clk);
      in_valid(i) <= '0';
      done(i)     <= '1';
      wait until go(i) = '0';
      done(i)     <= '0';
    end process drv;
  end generate gen_drv;

  ready_drv : process
    variable s1, s2 : positive := 42;
    variable r      : real;
    variable tog    : std_logic := '0';
  begin
    wait until falling_edge(clk);
    tog := not tog;
    for o in 0 to 4 loop
      case ready_mode(o) is
        when 0      => out_ready(o) <= '0';
        when 1      => out_ready(o) <= '1';
        when 2      => out_ready(o) <= tog;
        when others =>
          uniform(s1, s2, r);
          out_ready(o) <= '1' when r < 0.5 else '0';
      end case;
    end loop;
  end process ready_drv;

  scoreboard : process (clk)
    variable next_seq      : int5_t  := (others => 0);
    variable errs          : natural := 0;
    variable src, seq, dst : natural;
    variable txc, rxc      : int5_t  := (others => 0);
    variable pair          : int55_t := (others => (others => 0));
    variable total         : natural := 0;
    variable glog          : log_t   := (others => -1);
    variable glen          : natural := 0;
  begin
    if rising_edge(clk) and rst = '0' then
      if log_clear = '1' then
        glen := 0;
      end if;
      for i in 0 to 4 loop
        if in_valid(i) = '1' and in_ready(i) = '1' then
          txc(i) := txc(i) + 1;
        end if;
      end loop;
      for o in 0 to 4 loop
        if out_valid(o) = '1' and out_ready(o) = '1' then
          src := to_integer(unsigned(out_pkt(o).src_addr));
          seq := out_pkt(o).time_stamp;
          dst := to_integer(unsigned(out_pkt(o).dst_addr));
          if ROUTE_TB(dst) /= o then
            report "misrouted: dst " & integer'image(dst) & " left on port " & integer'image(o)
              severity error;
            errs := errs + 1;
          end if;
          if src > 4 or seq /= next_seq(src mod 5) then
            report "input " & integer'image(src) & ": got seq " & integer'image(seq) &
                   " expected " & integer'image(next_seq(src mod 5)) &
                   " (loss, duplicate or reorder)"
              severity error;
            errs := errs + 1;
          end if;
          if out_pkt(o).hop_count /= 1 or out_pkt(o).payload /= payload_of(src mod 5, seq) then
            report "packet corrupted on port " & integer'image(o) severity error;
            errs := errs + 1;
          end if;
          if src <= 4 then
            next_seq(src)  := seq + 1;
            rxc(src)       := rxc(src) + 1;
            pair(src, o)   := pair(src, o) + 1;
          end if;
          total := total + 1;
          if o = log_port and glen <= 255 then
            glog(glen) := src;
            glen       := glen + 1;
          end if;
        end if;
      end loop;
      tx_cnt    <= txc;
      rx_cnt    <= rxc;
      rx_pair   <= pair;
      rx_total  <= total;
      grant_log <= glog;
      grant_len <= glen;
      sb_errors <= errs;
    end if;
  end process scoreboard;

  main : process
    variable errors        : natural := 0;
    variable sent          : natural := 0;
    variable s1, s2        : positive := 7;
    variable r             : real;
    variable rx0, tx0, tx4 : natural;

    procedure check(cond : boolean; msg : string) is
    begin
      if not cond then
        report msg severity error;
        errors := errors + 1;
      end if;
    end procedure;

    procedure cycles(n : natural) is
    begin
      for k in 1 to n loop
        wait until rising_edge(clk);
      end loop;
    end procedure;

    -- start the drivers in 'mask' once the plan signals have settled
    procedure start(mask : port_bits_t) is
    begin
      wait until falling_edge(clk);
      for i in 0 to 4 loop
        if mask(i) = '1' then
          sent := sent + plan_len(i);
        end if;
      end loop;
      wait until falling_edge(clk);
      go <= mask;
    end procedure;

    -- wait until the drivers are done and everything sent has been delivered
    procedure finish_run(mask : port_bits_t; name : string) is
      variable n : natural := 0;
    begin
      loop
        wait until rising_edge(clk);
        n := n + 1;
        exit when (done and mask) = mask and rx_total = sent;
        if n > 5000 then
          report name & ": timeout, delivered " & integer'image(rx_total) & " of " &
                 integer'image(sent)
            severity error;
          errors := errors + 1;
          exit;
        end if;
      end loop;
      wait until falling_edge(clk);
      go <= (others => '0');
      wait until falling_edge(clk);
    end procedure;
  begin
    wait for 22 ns;
    rst <= '0';
    cycles(2);

    ---------------------------------------------------------------- 1. routing
    for i in 0 to 4 loop
      for k in 0 to 4 loop
        plan(i)(k) <= (k + i) mod 5;
      end loop;
      plan_len(i) <= 5;
    end loop;
    start("11111");
    finish_run("11111", "routing");
    for i in 0 to 4 loop
      for o in 0 to 4 loop
        check(rx_pair(i, o) = 1, "routing: input " & integer'image(i) & " -> output " &
              integer'image(o) & " delivered " & integer'image(rx_pair(i, o)) & " times");
      end loop;
    end loop;

    ---------------------------------------------------------------- 2. round-robin on output 2
    for i in 0 to 4 loop
      for k in 0 to 7 loop
        plan(i)(k) <= 2;
      end loop;
      plan_len(i) <= 8;
    end loop;
    ready_mode(2) <= 0;                        -- let every input queue up first
    log_clear     <= '1';
    wait until rising_edge(clk);
    log_clear     <= '0';
    start("11111");
    cycles(FIFO_DEPTH + 4);
    wait until falling_edge(clk);
    ready_mode(2) <= 1;
    finish_run("11111", "fairness");
    check(grant_len = 40, "fairness: logged " & integer'image(grant_len) & " grants, expected 40");
    for k in 1 to 39 loop
      check(grant_log(k) = (grant_log(k - 1) + 1) mod 5,
            "fairness: grant " & integer'image(k) & " went to input " & integer'image(grant_log(k)) &
            " after input " & integer'image(grant_log(k - 1)) & " (not round-robin)");
    end loop;

    ---------------------------------------------------------------- 3. backpressure on output 1
    plan_len <= (others => 0);
    for k in 0 to FIFO_DEPTH + 1 loop
      plan(0)(k) <= 1;
      plan(4)(k) <= 1;
    end loop;
    plan_len(0)   <= FIFO_DEPTH + 2;
    plan_len(4)   <= FIFO_DEPTH + 2;
    ready_mode(1) <= 0;
    cycles(2);
    rx0 := rx_total;
    tx0 := tx_cnt(0);
    tx4 := tx_cnt(4);
    start("10001");
    cycles(DELAY + FIFO_DEPTH + 30);
    check(rx_total = rx0, "backpressure: a packet left while out_ready = '0'");
    check(out_valid(1) = '1', "backpressure: out_valid not held while blocked");
    check(in_ready(0) = '0' and in_ready(4) = '0', "backpressure: full input FIFO still ready");
    check(done(0) = '0' and done(4) = '0', "backpressure: senders were not held back");
    check(tx_cnt(0) - tx0 = FIFO_DEPTH and tx_cnt(4) - tx4 = FIFO_DEPTH,
          "backpressure: accepted " & integer'image(tx_cnt(0) - tx0) & "/" &
          integer'image(tx_cnt(4) - tx4) & " packets while blocked, expected FIFO_DEPTH each");
    wait until falling_edge(clk);
    ready_mode(1) <= 1;
    finish_run("10001", "backpressure");

    ---------------------------------------------------------------- 4. FIFO full on input 3
    plan_len <= (others => 0);
    for k in 0 to FIFO_DEPTH + 2 loop
      plan(3)(k) <= 0;
    end loop;
    plan_len(3)   <= FIFO_DEPTH + 3;
    ready_mode(0) <= 0;
    cycles(2);
    tx0 := tx_cnt(3);
    start("01000");
    cycles(30);
    check(tx_cnt(3) - tx0 = FIFO_DEPTH, "FIFO full: input accepted " &
          integer'image(tx_cnt(3) - tx0) & " packets while blocked, expected " &
          integer'image(FIFO_DEPTH));
    check(in_ready(3) = '0', "FIFO full: in_ready not '0'");
    check(in_valid(3) = '1', "FIFO full: sender did not hold");
    wait until falling_edge(clk);
    ready_mode(0) <= 2;
    finish_run("01000", "FIFO full");
    ready_mode(0) <= 1;

    ---------------------------------------------------------------- 5. random traffic and ready
    for i in 0 to 4 loop
      for k in 0 to 39 loop
        uniform(s1, s2, r);
        plan(i)(k) <= integer(floor(r * 5.0)) mod 5;
      end loop;
      plan_len(i) <= 40;
    end loop;
    ready_mode <= (others => 3);
    start("11111");
    finish_run("11111", "random");
    ready_mode <= (others => 1);

    ---------------------------------------------------------------- verdict
    cycles(5);
    check(sb_errors = 0, "scoreboard errors: " & integer'image(sb_errors));
    for i in 0 to 4 loop
      check(viol_out(i) = 0 and viol_in(i) = 0, "contract violations on port " & integer'image(i));
      check(rx_cnt(i) = tx_cnt(i), "input " & integer'image(i) & ": accepted " &
            integer'image(tx_cnt(i)) & ", delivered " & integer'image(rx_cnt(i)));
    end loop;
    check(rx_total = sent, "delivered " & integer'image(rx_total) & " of " & integer'image(sent));
    if errors = 0 then
      report "SWITCH_TB PASS depth=" & integer'image(FIFO_DEPTH) & " delay=" &
             integer'image(DELAY) & " packets=" & integer'image(rx_total);
    else
      report "SWITCH_TB FAIL depth=" & integer'image(FIFO_DEPTH) & " delay=" &
             integer'image(DELAY) & " errors=" & integer'image(errors)
        severity failure;
    end if;
    finish;
  end process main;

end architecture sim;
