-- =============================================================================
-- File    : noc_top.vhd
-- Purpose : 3x3 mesh of switches with two masters (P1, P9) and four slaves (P2..P8).
-- Author  : Aref Ghoreishi
-- License : MIT (see LICENSE)
-- SPDX-License-Identifier: MIT
-- =============================================================================
--     S1 --- S2 --- S3        P1 (master) on S1, P9 (master) on S9
--     |      |      |         P2, P4, P6, P8 (slaves) on S2, S4, S6, S8
--     S4 --- S5 --- S6        S3, S5, S7 have nothing on their local port
--     |      |      |
--     S7 --- S8 --- S9        ports: 0 = N, 1 = E, 2 = S, 3 = W, 4 = local
--
-- TOPOLOGY = NOC1 builds the full mesh. NOC2 does not instantiate S3 and S7;
-- the ports of S2, S4, S6 and S8 that faced them become tie-offs, and the NoC2
-- routing tables send everything through S5 instead.
--
-- Ports with nothing attached are tied to valid = '0' and ready = '1'. A tie-off
-- accepts anything, so a packet routed into one would vanish; an assertion
-- reports it instead.
library ieee;
use ieee.std_logic_1164.all;
use work.noc_pkg.all;

entity noc_top is
  generic (
    TOPOLOGY            : topology_t := NOC1;
    SWITCH_FIFO_DEPTH   : positive;
    SWITCH_DELAY_CYCLES : natural;
    LOG_PREFIX          : string := "build/";          -- <prefix>P{1,9}_{responses,host}.txt
    DATA_DIR            : string := "data/baseline/"   -- holds P1_data.txt and P9_data.txt
  );
  port (
    clk : in std_logic;
    rst : in std_logic
  );
end entity noc_top;

architecture structural of noc_top is
  -- Switch-side view of every port: sw_in_* enter switch k, sw_out_* leave it
  signal sw_in_valid   : switch_bits_t    := (others => (others => '0'));
  signal sw_in_pkt     : switch_packets_t := (others => (others => DEFAULT_PACKET));
  signal sw_in_ready   : switch_bits_t    := (others => (others => '0'));
  signal sw_out_valid  : switch_bits_t    := (others => (others => '0'));
  signal sw_out_pkt    : switch_packets_t := (others => (others => DEFAULT_PACKET));
  signal sw_out_ready  : switch_bits_t    := (others => (others => '0'));
  signal sw_fifo_level : switch_levels_t  := (others => (others => 0));

  function is_master(k : natural) return boolean is
  begin
    return k = 1 or k = 9;
  end function;

  function is_slave(k : natural) return boolean is
  begin
    return k = 2 or k = 4 or k = 6 or k = 8;
  end function;
begin

  gen_sw : for k in 1 to 9 generate
    gen_present : if switch_present(TOPOLOGY, k) generate

      sw : entity work.noc_switch
        generic map (
          FIFO_DEPTH   => SWITCH_FIFO_DEPTH,
          DELAY_CYCLES => SWITCH_DELAY_CYCLES,
          SWITCH_ID    => switch_addr(k),
          ROUTE_TABLE  => routes(TOPOLOGY)(k)
        )
        port map (
          clk        => clk,
          rst        => rst,
          in_valid   => sw_in_valid(k),
          in_packet  => sw_in_pkt(k),
          in_ready   => sw_in_ready(k),
          out_valid  => sw_out_valid(k),
          out_packet => sw_out_pkt(k),
          out_ready  => sw_out_ready(k),
          fifo_level => sw_fifo_level(k)
        );

      gen_port : for p in PORT_N to PORT_W generate
        gen_link : if mesh_neighbour(k, p) /= 0 and
                      switch_present(TOPOLOGY, mesh_neighbour(k, p)) generate
          sw_in_valid(k)(p)  <= sw_out_valid(mesh_neighbour(k, p))(opposite_port(p));
          sw_in_pkt(k)(p)    <= sw_out_pkt(mesh_neighbour(k, p))(opposite_port(p));
          sw_out_ready(k)(p) <= sw_in_ready(mesh_neighbour(k, p))(opposite_port(p));
        else generate
          sw_in_valid(k)(p)  <= '0';
          sw_in_pkt(k)(p)    <= DEFAULT_PACKET;
          sw_out_ready(k)(p) <= '1';
          assert not (rising_edge(clk) and sw_out_valid(k)(p) = '1')
            report "S" & integer'image(k) & " routed a packet to port " & integer'image(p) &
                   ", which has no neighbour in this topology"
            severity error;
        end generate gen_link;
      end generate gen_port;

      gen_master : if is_master(k) generate
        pm : entity work.master_ip
          generic map (
            MY_ADDR     => switch_addr(k),
            OTHER_ADDR  => switch_addr(10 - k),
            DATA_FILE   => DATA_DIR & "P" & integer'image(k) & "_data.txt",
            SLAVE_ADDRS => ("0010", "0100", "0110", "1000"),
            RESP_LOG    => LOG_PREFIX & "P" & integer'image(k) & "_responses.txt",
            HOST_LOG    => LOG_PREFIX & "P" & integer'image(k) & "_host.txt"
          )
          port map (
            clk        => clk,
            rst        => rst,
            out_valid  => sw_in_valid(k)(PORT_L),
            out_packet => sw_in_pkt(k)(PORT_L),
            out_ready  => sw_in_ready(k)(PORT_L),
            in_valid   => sw_out_valid(k)(PORT_L),
            in_packet  => sw_out_pkt(k)(PORT_L),
            in_ready   => sw_out_ready(k)(PORT_L)
          );
      end generate gen_master;

      gen_slave : if is_slave(k) generate
        ps : entity work.slave_ip
          generic map (
            MY_ADDR => switch_addr(k)
          )
          port map (
            clk        => clk,
            rst        => rst,
            in_valid   => sw_out_valid(k)(PORT_L),
            in_packet  => sw_out_pkt(k)(PORT_L),
            in_ready   => sw_out_ready(k)(PORT_L),
            out_valid  => sw_in_valid(k)(PORT_L),
            out_packet => sw_in_pkt(k)(PORT_L),
            out_ready  => sw_in_ready(k)(PORT_L)
          );
      end generate gen_slave;

      gen_no_ip : if not is_master(k) and not is_slave(k) generate
        sw_in_valid(k)(PORT_L)  <= '0';
        sw_in_pkt(k)(PORT_L)    <= DEFAULT_PACKET;
        sw_out_ready(k)(PORT_L) <= '1';
        assert not (rising_edge(clk) and sw_out_valid(k)(PORT_L) = '1')
          report "S" & integer'image(k) & " delivered a packet to its empty local port"
          severity error;
      end generate gen_no_ip;

    end generate gen_present;
  end generate gen_sw;

end architecture structural;
