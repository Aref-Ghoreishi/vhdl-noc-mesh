-- =============================================================================
-- File    : fifo_tb.vhd
-- Purpose : Corner-case test for noc_fifo.
-- Author  : Aref Ghoreishi
-- License : MIT (see LICENSE)
-- SPDX-License-Identifier: MIT
-- =============================================================================
-- Order, wrap-around, overflow and underflow, reset, and simultaneous enqueue
-- and dequeue on an empty, a partly full and a full FIFO (the original count
-- bug). Inputs change on the falling edge; checks run 1 ns after the rising edge.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.noc_pkg.all;

entity fifo_tb is
  generic (
    DEPTH : positive := 4
  );
end entity fifo_tb;

architecture sim of fifo_tb is
  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal enq   : std_logic := '0';
  signal deq   : std_logic := '0';
  signal din   : packet_t  := DEFAULT_PACKET;
  signal dout  : packet_t;
  signal full  : std_logic;
  signal empty : std_logic;

  function tag(n : natural) return packet_t is
    variable p : packet_t := DEFAULT_PACKET;
  begin
    p.time_stamp          := n;
    p.payload(7 downto 0) := std_logic_vector(to_unsigned(n mod 256, 8));
    return p;
  end function;
begin

  clk <= not clk after 5 ns;

  dut : entity work.noc_fifo
    generic map (
      FIFO_DEPTH => DEPTH
    )
    port map (
      clk           => clk,
      rst           => rst,
      enq           => enq,
      input_packet  => din,
      deq           => deq,
      output_packet => dout,
      full          => full,
      empty         => empty,
      level         => open
    );

  stim : process
    variable errors : natural := 0;

    -- apply enq/deq for exactly one rising edge
    procedure step(e, d : std_logic; n : natural := 0) is
    begin
      wait until falling_edge(clk);
      enq <= e;
      deq <= d;
      din <= tag(n);
      wait until rising_edge(clk);
      wait for 1 ns;
      enq <= '0';
      deq <= '0';
    end procedure;

    procedure expect(name : string; e_empty, e_full : std_logic; head : integer := -1) is
    begin
      if empty /= e_empty or full /= e_full then
        report name & ": empty=" & std_logic'image(empty) & " full=" & std_logic'image(full) &
               " expected empty=" & std_logic'image(e_empty) & " full=" & std_logic'image(e_full)
          severity error;
        errors := errors + 1;
      elsif head >= 0 and dout.time_stamp /= head then
        report name & ": head=" & integer'image(dout.time_stamp) &
               " expected " & integer'image(head)
          severity error;
        errors := errors + 1;
      end if;
    end procedure;

    function full_after(n : natural) return std_logic is
    begin
      if n = DEPTH then
        return '1';
      end if;
      return '0';
    end function;
  begin
    wait for 22 ns;
    rst <= '0';
    expect("after reset", '1', '0');

    -- 1. underflow is ignored
    step('0', '1');
    expect("deq on empty", '1', '0');

    -- 2. enqueue + dequeue on an empty FIFO: the write must be kept
    step('1', '1', 100);
    expect("enq+deq on empty", '0', full_after(1), 100);
    step('0', '1');
    expect("drain after enq+deq on empty", '1', '0');

    -- 3. fill in order; overflow is ignored
    for i in 1 to DEPTH loop
      step('1', '0', i);
      expect("fill " & integer'image(i), '0', full_after(i), 1);
    end loop;
    step('1', '0', 999);
    expect("enq on full", '0', '1', 1);

    -- 4. enqueue + dequeue on a full FIFO: the read happens, the write is refused
    step('1', '1', 998);
    if DEPTH > 1 then
      expect("enq+deq on full", '0', '0', 2);
    else
      expect("enq+deq on full", '1', '0');
    end if;

    -- the refused 998/999 must never appear
    for i in 2 to DEPTH loop
      expect("drain order " & integer'image(i), '0', '0', i);
      step('0', '1');
    end loop;
    expect("drained", '1', '0');

    -- 5. enqueue + dequeue on a partly full FIFO, across the wrap-around
    if DEPTH > 1 then
      step('1', '0', 10);
      for i in 11 to 10 + 3 * DEPTH loop
        step('1', '1', i);
        expect("stream " & integer'image(i), '0', '0', i);
      end loop;
      step('0', '1');
      expect("stream drained", '1', '0');
    end if;

    -- 6. reset clears a non-empty FIFO
    step('1', '0', 50);
    rst <= '1';
    wait for 12 ns;
    rst <= '0';
    expect("reset clears", '1', '0');

    if errors = 0 then
      report "FIFO_TB PASS depth=" & integer'image(DEPTH);
    else
      report "FIFO_TB FAIL depth=" & integer'image(DEPTH) & " errors=" & integer'image(errors)
        severity failure;
    end if;
    finish;
  end process stim;

end architecture sim;
