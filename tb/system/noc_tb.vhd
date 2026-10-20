-- =============================================================================
-- File    : noc_tb.vhd
-- Purpose : System testbench for the default configuration (FIFO depth 2, delay 7).
-- Author  : Aref Ghoreishi
-- License : MIT (see LICENSE)
-- SPDX-License-Identifier: MIT
-- =============================================================================
-- The configuration of the original coursework runs. "make test" compares its
-- replies with the original ModelSim logs in data/golden/ for both topologies.
-- All instrumentation comes from noc_sweep_tb.
library ieee;
use ieee.std_logic_1164.all;
use work.noc_pkg.all;

entity noc_tb is
  generic (
    TOPOLOGY   : topology_t := NOC1;
    OUT_PREFIX : string     := "build/noc_tb_";
    DATA_DIR   : string     := "data/baseline/"
  );
end entity noc_tb;

architecture sim of noc_tb is
begin

  default_config : entity work.noc_sweep_tb
    generic map (
      TOPOLOGY   => TOPOLOGY,
      DEPTH      => 2,
      DELAY      => 7,
      CYCLES     => 2000,
      OUT_PREFIX => OUT_PREFIX,
      DATA_DIR   => DATA_DIR
    );

end architecture sim;
