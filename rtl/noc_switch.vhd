-- =============================================================================
-- File    : noc_switch.vhd
-- Purpose : Five-port switch: input FIFOs, static routing, round-robin output arbiters.
-- Author  : Aref Ghoreishi
-- License : MIT (see LICENSE)
-- SPDX-License-Identifier: MIT
-- =============================================================================
-- Every port follows the valid/ready contract: a packet moves on a rising edge
-- where valid = '1' and ready = '1', and the sender holds it until then.
--
-- Each output arbitrates independently. When it is free it picks the first
-- non-empty input, starting after its round-robin pointer, whose head packet
-- routes to it. The grant is then locked, so the offered packet cannot change
-- while the output waits: first DELAY_CYCLES cycles (the switch delay model),
-- then for out_ready. The FIFO is dequeued on the same edge as the transfer,
-- which is why a packet can never be dequeued and then dropped. With
-- DELAY_CYCLES = 0 a head packet can leave on the next edge.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.noc_pkg.all;

entity noc_switch is
  generic (
    FIFO_DEPTH   : positive;
    DELAY_CYCLES : natural;
    SWITCH_ID    : addr_t;
    ROUTE_TABLE  : route_table_t
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    in_valid   : in  port_bits_t;
    in_packet  : in  port_packets_t;
    in_ready   : out port_bits_t;      -- input FIFO not full
    out_valid  : out port_bits_t;
    out_packet : out port_packets_t;
    out_ready  : in  port_bits_t;
    fifo_level : out port_levels_t     -- input FIFO levels, for monitoring only
  );
end entity noc_switch;

architecture rtl of noc_switch is
  subtype port_index_t is natural range 0 to NUM_PORTS - 1;
  type port_index_array_t is array (0 to NUM_PORTS - 1) of port_index_t;
  type delay_array_t      is array (0 to NUM_PORTS - 1) of natural range 0 to DELAY_CYCLES;

  signal enq_sig   : port_bits_t;
  signal deq_sig   : port_bits_t;
  signal empty_sig : port_bits_t;
  signal full_sig  : port_bits_t;
  signal head_pkt  : port_packets_t;

  -- Per-output arbiter state
  signal locked  : port_bits_t        := (others => '0');  -- grant held
  signal grant   : port_index_array_t := (others => 0);    -- input held while locked
  signal wait_ct : delay_array_t      := (others => 0);    -- delay cycles served
  signal rr_ptr  : port_index_array_t := (others => 0);    -- first input to consider

  -- Per-output decision for the current cycle
  signal sel     : port_index_array_t;
  signal has_sel : port_bits_t;
  signal valid_i : port_bits_t;
begin

  gen_fifos : for i in 0 to NUM_PORTS - 1 generate
    fifo_inst : entity work.noc_fifo
      generic map (
        FIFO_DEPTH => FIFO_DEPTH
      )
      port map (
        clk           => clk,
        rst           => rst,
        enq           => enq_sig(i),
        input_packet  => in_packet(i),
        deq           => deq_sig(i),
        output_packet => head_pkt(i),
        full          => full_sig(i),
        empty         => empty_sig(i),
        level         => fifo_level(i)
      );

    in_ready(i) <= not full_sig(i);
    enq_sig(i)  <= in_valid(i) and not full_sig(i);
  end generate gen_fifos;

  arb_comb : process (all)
    variable s      : port_index_t;
    variable found  : boolean;
    variable waited : natural;
    variable idx    : port_index_t;
    variable pkt    : packet_t;
    variable deq_v  : port_bits_t;
  begin
    deq_v := (others => '0');
    for o in 0 to NUM_PORTS - 1 loop
      s      := 0;
      found  := false;
      waited := 0;
      if locked(o) = '1' then
        s      := grant(o);
        found  := true;
        waited := wait_ct(o);
      else
        for k in 0 to NUM_PORTS - 1 loop
          idx := (rr_ptr(o) + k) mod NUM_PORTS;
          if not found and empty_sig(idx) = '0' and
             ROUTE_TABLE(to_integer(unsigned(head_pkt(idx).dst_addr))) = o then
            s     := idx;
            found := true;
          end if;
        end loop;
      end if;

      sel(o)     <= s;
      has_sel(o) <= '1' when found else '0';
      if found and waited >= DELAY_CYCLES then
        valid_i(o)        <= '1';
        pkt               := head_pkt(s);
        pkt.hop_count     := pkt.hop_count + 1;
        out_packet(o)     <= pkt;
        if out_ready(o) = '1' then
          deq_v(s) := '1';
        end if;
      else
        valid_i(o)    <= '0';
        out_packet(o) <= DEFAULT_PACKET;
      end if;
    end loop;
    deq_sig <= deq_v;
  end process arb_comb;

  out_valid <= valid_i;

  arb_reg : process (clk, rst)
    variable waited : natural;
  begin
    if rst = '1' then
      locked  <= (others => '0');
      grant   <= (others => 0);
      wait_ct <= (others => 0);
      rr_ptr  <= (others => 0);
    elsif rising_edge(clk) then
      for o in 0 to NUM_PORTS - 1 loop
        if valid_i(o) = '1' and out_ready(o) = '1' then
          -- Transfer: free the output and move the pointer past the winner
          locked(o)  <= '0';
          wait_ct(o) <= 0;
          rr_ptr(o)  <= (sel(o) + 1) mod NUM_PORTS;
        elsif has_sel(o) = '1' then
          -- Hold the grant until the packet is accepted
          if locked(o) = '1' then
            waited := wait_ct(o);
          else
            waited := 0;
          end if;
          locked(o) <= '1';
          grant(o)  <= sel(o);
          if waited < DELAY_CYCLES then
            wait_ct(o) <= waited + 1;
          end if;
        end if;
      end loop;
    end if;
  end process arb_reg;

end architecture rtl;
