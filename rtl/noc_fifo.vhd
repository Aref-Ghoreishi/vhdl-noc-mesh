-- =============================================================================
-- File    : noc_fifo.vhd
-- Purpose : Circular packet FIFO used at every switch input.
-- Author  : Aref Ghoreishi
-- License : MIT (see LICENSE)
-- SPDX-License-Identifier: MIT
-- =============================================================================
-- Enqueue and dequeue are both judged against the state before the clock edge.
-- On a full FIFO a simultaneous enqueue is therefore refused even though the
-- dequeue frees a slot; this keeps "ready = not full" independent of the read
-- side, so no combinational path runs from a switch output back to its inputs.
library ieee;
use ieee.std_logic_1164.all;
use work.noc_pkg.all;

entity noc_fifo is
  generic (
    FIFO_DEPTH : positive
  );
  port (
    clk           : in  std_logic;
    rst           : in  std_logic;
    enq           : in  std_logic;
    input_packet  : in  packet_t;
    deq           : in  std_logic;
    output_packet : out packet_t;    -- head packet, meaningful while empty = '0'
    full          : out std_logic;
    empty         : out std_logic;
    level         : out natural      -- packets stored, exported for monitoring
  );
end entity noc_fifo;

architecture behavioral of noc_fifo is
  type mem_t is array (0 to FIFO_DEPTH - 1) of packet_t;
  signal mem      : mem_t := (others => DEFAULT_PACKET);
  signal head_ptr : natural range 0 to FIFO_DEPTH - 1 := 0;  -- next write slot
  signal tail_ptr : natural range 0 to FIFO_DEPTH - 1 := 0;  -- oldest packet
  signal count    : natural range 0 to FIFO_DEPTH := 0;
begin

  output_packet <= mem(tail_ptr);
  full          <= '1' when count = FIFO_DEPTH else '0';
  empty         <= '1' when count = 0 else '0';
  level         <= count;

  process (clk, rst)
    variable do_enq, do_deq : boolean;
  begin
    if rst = '1' then
      head_ptr <= 0;
      tail_ptr <= 0;
      count    <= 0;
    elsif rising_edge(clk) then
      do_enq := enq = '1' and count < FIFO_DEPTH;
      do_deq := deq = '1' and count > 0;

      if do_enq then
        mem(head_ptr) <= input_packet;
        head_ptr      <= (head_ptr + 1) mod FIFO_DEPTH;
      end if;
      if do_deq then
        tail_ptr <= (tail_ptr + 1) mod FIFO_DEPTH;
      end if;

      if do_enq and not do_deq then
        count <= count + 1;
      elsif do_deq and not do_enq then
        count <= count - 1;
      end if;
    end if;
  end process;

end architecture behavioral;
