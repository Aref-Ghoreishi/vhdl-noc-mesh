-- =============================================================================
-- File    : noc_sweep_tb.vhd
-- Purpose : Parametric system testbench: one NoC configuration, full instrumentation.
-- Author  : Aref Ghoreishi
-- License : MIT (see LICENSE)
-- SPDX-License-Identifier: MIT
-- =============================================================================
-- Writes, with prefix OUT_PREFIX:
--   o_P<n>.txt   every packet transferred to the local port of P<n>
--   summary.txt  injected / delivered counts, contract violations, stuck FIFOs,
--                maximum occupancy of every input FIFO and packets forwarded per switch
-- The masters add <OUT_PREFIX>P{1,9}_{responses,host}.txt. scripts/check.py
-- compares all of this with the golden model.
--
-- The DUT is observed through relative external names, so this testbench also
-- works when it is instantiated inside another one (see noc_tb).
library ieee;
use ieee.std_logic_1164.all;
use std.textio.all;
use std.env.all;
use work.noc_pkg.all;

entity noc_sweep_tb is
  generic (
    TOPOLOGY   : topology_t := NOC1;
    DEPTH      : positive := 2;
    DELAY      : natural  := 7;
    CYCLES     : positive := 20000;
    OUT_PREFIX : string   := "build/";
    DATA_DIR   : string   := "data/baseline/"
  );
end entity noc_sweep_tb;

architecture sim of noc_sweep_tb is
  constant CLK_PERIOD : time := 10 ns;

  type int_array_t is array (natural range <>) of natural;
  constant ENDPOINTS : int_array_t := (1, 2, 4, 6, 8, 9);

  type violation_array_t is array (1 to 9, 0 to NUM_PORTS) of natural;

  signal clk        : std_logic := '0';
  signal rst        : std_logic := '1';
  signal cyc        : natural   := 0;
  signal violations : violation_array_t := (others => (others => 0));
begin

  clk <= not clk after CLK_PERIOD / 2;
  rst <= '0' after 100 ns;

  dut : entity work.noc_top
    generic map (
      TOPOLOGY            => TOPOLOGY,
      SWITCH_FIFO_DEPTH   => DEPTH,
      SWITCH_DELAY_CYCLES => DELAY,
      LOG_PREFIX          => OUT_PREFIX,
      DATA_DIR            => DATA_DIR
    )
    port map (
      clk => clk,
      rst => rst
    );

  -- Contract checkers on every switch output and on every endpoint output.
  -- (Declared after the DUT: external names may only refer to elaborated objects.)
  checkers : block
    alias out_valid is <<signal ^.dut.sw_out_valid : switch_bits_t>>;
    alias out_ready is <<signal ^.dut.sw_out_ready : switch_bits_t>>;
    alias out_pkt   is <<signal ^.dut.sw_out_pkt   : switch_packets_t>>;
    alias in_valid  is <<signal ^.dut.sw_in_valid  : switch_bits_t>>;
    alias in_ready  is <<signal ^.dut.sw_in_ready  : switch_bits_t>>;
    alias in_pkt    is <<signal ^.dut.sw_in_pkt    : switch_packets_t>>;
  begin
    gen_sw : for k in 1 to 9 generate
      gen_out : for p in 0 to NUM_PORTS - 1 generate
        chk : entity work.handshake_check
          generic map (
            NAME => "S" & integer'image(k) & " output " & integer'image(p)
          )
          port map (
            clk        => clk,
            rst        => rst,
            valid      => out_valid(k)(p),
            ready      => out_ready(k)(p),
            packet     => out_pkt(k)(p),
            violations => violations(k, p)
          );
      end generate gen_out;

      gen_ep : if k /= 3 and k /= 5 and k /= 7 generate
        chk : entity work.handshake_check
          generic map (
            NAME => "P" & integer'image(k) & " output"
          )
          port map (
            clk        => clk,
            rst        => rst,
            valid      => in_valid(k)(PORT_L),
            ready      => in_ready(k)(PORT_L),
            packet     => in_pkt(k)(PORT_L),
            violations => violations(k, NUM_PORTS)
          );
      end generate gen_ep;
    end generate gen_sw;
  end block checkers;

  monitor : process
    alias in_valid  is <<signal dut.sw_in_valid   : switch_bits_t>>;
    alias in_ready  is <<signal dut.sw_in_ready   : switch_bits_t>>;
    alias out_valid is <<signal dut.sw_out_valid  : switch_bits_t>>;
    alias out_ready is <<signal dut.sw_out_ready  : switch_bits_t>>;
    alias out_pkt   is <<signal dut.sw_out_pkt    : switch_packets_t>>;
    alias level     is <<signal dut.sw_fifo_level : switch_levels_t>>;

    file f1 : text open write_mode is OUT_PREFIX & "o_P1.txt";
    file f2 : text open write_mode is OUT_PREFIX & "o_P2.txt";
    file f4 : text open write_mode is OUT_PREFIX & "o_P4.txt";
    file f6 : text open write_mode is OUT_PREFIX & "o_P6.txt";
    file f8 : text open write_mode is OUT_PREFIX & "o_P8.txt";
    file f9 : text open write_mode is OUT_PREFIX & "o_P9.txt";
    file fs : text open write_mode is OUT_PREFIX & "summary.txt";

    variable injected, delivered, last_delivery : natural := 0;
    variable stuck, viol_total                  : natural := 0;
    variable ln                                 : line;
    variable k                                  : natural;
    variable max_level                          : switch_levels_t := (others => (others => 0));
    variable forwarded                          : int_array_t(1 to 9) := (others => 0);
    variable overall                            : natural := 0;

    procedure log_pkt(file f : text; p : packet_t) is
      variable l2 : line;
    begin
      write(l2, "cycle=" & integer'image(cyc) &
                " src=" & to_string(p.src_addr) &
                " dst=" & to_string(p.dst_addr) &
                " resp=" & to_string(p.resp_addr) &
                " hops=" & integer'image(p.hop_count) &
                " ts=" & integer'image(p.time_stamp) &
                " check=" & to_hstring(p.check_byte) &
                " data=" & to_hstring(p.payload));
      writeline(f, l2);
      delivered     := delivered + 1;
      last_delivery := cyc;
    end procedure;
  begin
    wait until rst = '0';
    while cyc < CYCLES loop
      wait until rising_edge(clk);
      cyc <= cyc + 1;
      for sw in 1 to 9 loop
        for i in 0 to NUM_PORTS - 1 loop
          if level(sw)(i) > max_level(sw)(i) then
            max_level(sw)(i) := level(sw)(i);
          end if;
          if out_valid(sw)(i) = '1' and out_ready(sw)(i) = '1' then
            forwarded(sw) := forwarded(sw) + 1;
          end if;
        end loop;
      end loop;
      for e in ENDPOINTS'range loop
        k := ENDPOINTS(e);
        if in_valid(k)(PORT_L) = '1' and in_ready(k)(PORT_L) = '1' then
          injected := injected + 1;
        end if;
        if out_valid(k)(PORT_L) = '1' and out_ready(k)(PORT_L) = '1' then
          case k is
            when 1      => log_pkt(f1, out_pkt(k)(PORT_L));
            when 2      => log_pkt(f2, out_pkt(k)(PORT_L));
            when 4      => log_pkt(f4, out_pkt(k)(PORT_L));
            when 6      => log_pkt(f6, out_pkt(k)(PORT_L));
            when 8      => log_pkt(f8, out_pkt(k)(PORT_L));
            when others => log_pkt(f9, out_pkt(k)(PORT_L));
          end case;
        end if;
      end loop;
    end loop;

    for sw in 1 to 9 loop
      for i in 0 to NUM_PORTS - 1 loop
        if level(sw)(i) > 0 then
          write(ln, "stuck S" & integer'image(sw) & " in" & integer'image(i) &
                    " level=" & integer'image(level(sw)(i)));
          writeline(fs, ln);
          stuck := stuck + 1;
        end if;
      end loop;
      for p in 0 to NUM_PORTS loop
        viol_total := viol_total + violations(sw, p);
      end loop;
    end loop;

    -- Maximum FIFO occupancy per input port (N E S W L) and packets forwarded per switch.
    -- Switches missing from the topology report zeros.
    for sw in 1 to 9 loop
      write(ln, "max_occupancy S" & integer'image(sw) & " :");
      for i in 0 to NUM_PORTS - 1 loop
        write(ln, " " & integer'image(max_level(sw)(i)));
        if max_level(sw)(i) > overall then
          overall := max_level(sw)(i);
        end if;
      end loop;
      write(ln, " forwarded : " & integer'image(forwarded(sw)));
      report ln.all;
      writeline(fs, ln);
    end loop;

    write(ln, "topology=" & topology_t'image(TOPOLOGY) & " depth=" & integer'image(DEPTH) & " delay=" & integer'image(DELAY) &
              " cycles=" & integer'image(CYCLES) & " injected=" & integer'image(injected) &
              " arrived=" & integer'image(delivered) & " stuck_fifos=" & integer'image(stuck) &
              " violations=" & integer'image(viol_total) &
              " max_occupancy=" & integer'image(overall) &
              " last_arrival=" & integer'image(last_delivery));
    writeline(fs, ln);

    -- Self-check of the network itself; packet contents are checked by scripts/check.py.
    if stuck = 0 and viol_total = 0 and injected = delivered and delivered > 0 then
      report "NOC_SWEEP_TB PASS delivered=" & integer'image(delivered);
    else
      report "NOC_SWEEP_TB FAIL injected=" & integer'image(injected) & " delivered=" &
             integer'image(delivered) & " stuck_fifos=" & integer'image(stuck) &
             " violations=" & integer'image(viol_total)
        severity failure;
    end if;
    finish;
  end process monitor;

end architecture sim;
