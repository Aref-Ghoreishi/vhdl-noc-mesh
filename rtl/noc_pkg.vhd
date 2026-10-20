-- =============================================================================
-- File    : noc_pkg.vhd
-- Purpose : Shared types, constants, routing tables and mesh geometry of the NoC.
-- Author  : Aref Ghoreishi
-- License : MIT (see LICENSE)
-- SPDX-License-Identifier: MIT
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package noc_pkg is

  constant PAYLOAD_BYTES : natural := 8;
  constant PAYLOAD_BITS  : natural := PAYLOAD_BYTES * 8;
  constant NUM_PORTS     : natural := 5;

  -- Switch port numbers. PORT_L connects the switch to its processor.
  constant PORT_N : natural := 0;
  constant PORT_E : natural := 1;
  constant PORT_S : natural := 2;
  constant PORT_W : natural := 3;
  constant PORT_L : natural := 4;

  subtype addr_t is std_logic_vector(3 downto 0);
  type addr_array_t is array (natural range <>) of addr_t;

  type packet_t is record
    src_addr   : addr_t;                          -- sender of this packet
    dst_addr   : addr_t;                          -- destination endpoint
    resp_addr  : addr_t;                          -- master that issued the request
    valid_size : integer range 0 to PAYLOAD_BYTES; -- bytes in use, byte 0 first
    check_byte : std_logic_vector(7 downto 0);
    hop_count  : integer range 0 to 255;          -- switches traversed so far
    time_stamp : integer;                         -- cycle the request was first offered
    payload    : std_logic_vector(PAYLOAD_BITS - 1 downto 0); -- byte i = bits 8i+7..8i
  end record;

  type packet_vector_t is array (natural range <>) of packet_t;

  constant DEFAULT_PACKET : packet_t := (
    src_addr   => (others => '0'),
    dst_addr   => (others => '0'),
    resp_addr  => (others => '0'),
    valid_size => 0,
    check_byte => (others => '0'),
    hop_count  => 0,
    time_stamp => 0,
    payload    => (others => '0')
  );

  -- One bit / packet / FIFO level per switch port
  subtype port_bits_t    is std_logic_vector(NUM_PORTS - 1 downto 0);
  subtype port_packets_t is packet_vector_t(NUM_PORTS - 1 downto 0);
  type    port_levels_t  is array (0 to NUM_PORTS - 1) of natural;

  -- The same per switch of the 3x3 mesh (switch k = 1..9, row-major)
  type switch_bits_t    is array (1 to 9) of port_bits_t;
  type switch_packets_t is array (1 to 9) of port_packets_t;
  type switch_levels_t  is array (1 to 9) of port_levels_t;

  -- Static routing: destination address -> output port.
  -- Unused destinations go to the local port, where a tie-off reports them.
  type route_table_t       is array (0 to 15) of natural range 0 to NUM_PORTS - 1;
  type route_table_array_t is array (1 to 9) of route_table_t;

  -- NoC1: full 3x3 mesh. Requests to the far slaves and the slave replies are spread over
  -- the outer ring (through S3 and S7) and the centre column.
  constant NOC1_S1 : route_table_t := (
    1 => PORT_L, 2 => PORT_E, 3 => PORT_E, 4 => PORT_S, 5 => PORT_E,
    6 => PORT_E, 7 => PORT_S, 8 => PORT_S, 9 => PORT_S, others => PORT_L);
  constant NOC1_S2 : route_table_t := (
    1 => PORT_W, 2 => PORT_L, 3 => PORT_E, 4 => PORT_W, 5 => PORT_S,
    6 => PORT_E, 7 => PORT_W, 8 => PORT_S, 9 => PORT_S, others => PORT_L);
  constant NOC1_S3 : route_table_t := (
    1 => PORT_W, 2 => PORT_W, 3 => PORT_L, 4 => PORT_W, 5 => PORT_W,
    6 => PORT_S, 7 => PORT_S, 8 => PORT_S, 9 => PORT_S, others => PORT_L);
  constant NOC1_S4 : route_table_t := (
    1 => PORT_N, 2 => PORT_N, 3 => PORT_E, 4 => PORT_L, 5 => PORT_E,
    6 => PORT_E, 7 => PORT_S, 8 => PORT_S, 9 => PORT_E, others => PORT_L);
  constant NOC1_S5 : route_table_t := (
    1 => PORT_N, 2 => PORT_N, 3 => PORT_E, 4 => PORT_W, 5 => PORT_L,
    6 => PORT_E, 7 => PORT_W, 8 => PORT_S, 9 => PORT_S, others => PORT_L);
  constant NOC1_S6 : route_table_t := (
    1 => PORT_W, 2 => PORT_N, 3 => PORT_N, 4 => PORT_W, 5 => PORT_W,
    6 => PORT_L, 7 => PORT_W, 8 => PORT_S, 9 => PORT_S, others => PORT_L);
  constant NOC1_S7 : route_table_t := (
    1 => PORT_N, 2 => PORT_N, 3 => PORT_N, 4 => PORT_N, 5 => PORT_E,
    6 => PORT_E, 7 => PORT_L, 8 => PORT_E, 9 => PORT_E, others => PORT_L);
  constant NOC1_S8 : route_table_t := (
    1 => PORT_N, 2 => PORT_N, 3 => PORT_N, 4 => PORT_W, 5 => PORT_N,
    6 => PORT_E, 7 => PORT_W, 8 => PORT_L, 9 => PORT_E, others => PORT_L);
  constant NOC1_S9 : route_table_t := (
    1 => PORT_N, 2 => PORT_N, 3 => PORT_N, 4 => PORT_W, 5 => PORT_W,
    6 => PORT_N, 7 => PORT_W, 8 => PORT_W, 9 => PORT_L, others => PORT_L);

  constant NOC1_ROUTES : route_table_array_t := (
    NOC1_S1, NOC1_S2, NOC1_S3, NOC1_S4, NOC1_S5, NOC1_S6, NOC1_S7, NOC1_S8, NOC1_S9);

  -- NoC2: S3 and S7 are removed, so every path between the two halves of the mesh
  -- crosses the centre switch S5.
  constant NOC2_S1 : route_table_t := (
    1 => PORT_L, 2 => PORT_E, 4 => PORT_S, 5 => PORT_E, 6 => PORT_E,
    8 => PORT_S, 9 => PORT_S, others => PORT_L);
  constant NOC2_S2 : route_table_t := (
    1 => PORT_W, 2 => PORT_L, 4 => PORT_S, 5 => PORT_S, 6 => PORT_S,
    8 => PORT_S, 9 => PORT_S, others => PORT_L);
  constant NOC2_S4 : route_table_t := (
    1 => PORT_N, 2 => PORT_E, 4 => PORT_L, 5 => PORT_E, 6 => PORT_E,
    8 => PORT_E, 9 => PORT_E, others => PORT_L);
  constant NOC2_S5 : route_table_t := (
    1 => PORT_N, 2 => PORT_N, 4 => PORT_W, 5 => PORT_L, 6 => PORT_E,
    8 => PORT_S, 9 => PORT_S, others => PORT_L);
  constant NOC2_S6 : route_table_t := (
    1 => PORT_W, 2 => PORT_W, 4 => PORT_W, 5 => PORT_W, 6 => PORT_L,
    8 => PORT_W, 9 => PORT_S, others => PORT_L);
  constant NOC2_S8 : route_table_t := (
    1 => PORT_N, 2 => PORT_N, 4 => PORT_N, 5 => PORT_N, 6 => PORT_N,
    8 => PORT_L, 9 => PORT_E, others => PORT_L);
  constant NOC2_S9 : route_table_t := (
    1 => PORT_N, 2 => PORT_N, 4 => PORT_W, 5 => PORT_N, 6 => PORT_N,
    8 => PORT_W, 9 => PORT_L, others => PORT_L);

  -- Placeholder for the switches NoC2 does not instantiate; never used.
  constant NO_ROUTES : route_table_t := (others => PORT_L);

  constant NOC2_ROUTES : route_table_array_t := (
    NOC2_S1, NOC2_S2, NO_ROUTES, NOC2_S4, NOC2_S5, NOC2_S6, NO_ROUTES, NOC2_S8, NOC2_S9);

  type topology_t is (NOC1, NOC2);

  function routes(topology : topology_t) return route_table_array_t;
  function switch_present(topology : topology_t; k : natural) return boolean;

  -- Mesh geometry: switch k sits at row (k-1)/3, column (k-1) mod 3 and has address k.
  -- mesh_neighbour returns the switch reached through port p (N/E/S/W) or 0 at the edge.
  function mesh_neighbour(k, p : natural) return natural;
  function opposite_port(p : natural) return natural;
  function switch_addr(k : natural) return addr_t;

end package noc_pkg;

package body noc_pkg is

  function mesh_neighbour(k, p : natural) return natural is
    constant row : natural := (k - 1) / 3;
    constant col : natural := (k - 1) mod 3;
  begin
    case p is
      when PORT_N => if row > 0 then return k - 3; end if;
      when PORT_E => if col < 2 then return k + 1; end if;
      when PORT_S => if row < 2 then return k + 3; end if;
      when PORT_W => if col > 0 then return k - 1; end if;
      when others => null;
    end case;
    return 0;
  end function;

  function opposite_port(p : natural) return natural is
  begin
    return (p + 2) mod 4;
  end function;

  function switch_addr(k : natural) return addr_t is
  begin
    return std_logic_vector(to_unsigned(k, 4));
  end function;

  function routes(topology : topology_t) return route_table_array_t is
  begin
    if topology = NOC2 then
      return NOC2_ROUTES;
    end if;
    return NOC1_ROUTES;
  end function;

  function switch_present(topology : topology_t; k : natural) return boolean is
  begin
    return not (topology = NOC2 and (k = 3 or k = 7));
  end function;

end package body noc_pkg;
