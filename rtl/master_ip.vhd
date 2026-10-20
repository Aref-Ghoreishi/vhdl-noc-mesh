-- =============================================================================
-- File    : master_ip.vhd
-- Purpose : Master processor (P1 / P9): sends requests from a file, logs what it receives.
-- Author  : Aref Ghoreishi
-- License : MIT (see LICENSE)
-- SPDX-License-Identifier: MIT
-- =============================================================================
-- Send side: one request per line of DATA_FILE, "dest valid_size b0 .. b7".
-- valid_size must be 0..8 and every byte 0..255; a bad line stops the run with
-- "<file>:<line>: ...". Bytes from valid_size on are padding and are sent as
-- zero. Each packet is offered and held until out_ready, followed by
-- GAP_CYCLES idle cycles. After every FORWARD_EVERY-th request the same
-- payload is forwarded to the other master.
--
-- Receive side: always ready. Slave replies go to RESP_LOG, packets from the
-- other master to HOST_LOG, one line each:
--   requester responder send_cycle recv_cycle latency hops check data
-- requester = resp_addr, responder = src_addr, send_cycle = time_stamp (the
-- cycle the original request was first offered), recv_cycle = this transfer.
--
-- File I/O makes this a simulation model, not synthesizable logic.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.noc_pkg.all;

entity master_ip is
  generic (
    MY_ADDR       : addr_t       := "0001";
    OTHER_ADDR    : addr_t       := "1001";
    DATA_FILE     : string       := "data/baseline/P1_data.txt";
    SLAVE_ADDRS   : addr_array_t := ("0010", "0100", "0110", "1000");
    RESP_LOG      : string       := "build/P1_responses.txt";
    HOST_LOG      : string       := "build/P1_host.txt";
    GAP_CYCLES    : natural      := 6;
    FORWARD_EVERY : positive     := 4
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    out_valid  : out std_logic;
    out_packet : out packet_t;
    out_ready  : in  std_logic;
    in_valid   : in  std_logic;
    in_packet  : in  packet_t;
    in_ready   : out std_logic
  );
end entity master_ip;

architecture behavioral of master_ip is
  file input_file : text open read_mode  is DATA_FILE;
  file resp_file  : text open write_mode is RESP_LOG;
  file host_file  : text open write_mode is HOST_LOG;

  type send_state_t is (READ_LINE, OFFER, GAP, DONE);

  signal cycle_ctr : natural   := 0;
  signal valid_i   : std_logic := '0';
  signal pkt_i     : packet_t  := DEFAULT_PACKET;
  signal last_req  : packet_t  := DEFAULT_PACKET;   -- payload source for the forward
  signal state     : send_state_t := READ_LINE;
  signal gap_ctr   : natural   := 0;
  signal req_count : natural   := 0;
  signal is_fwd    : boolean   := false;

  procedure log_line(file f : text; p : packet_t; recv : natural) is
    variable ln : line;
  begin
    write(ln, to_string(p.resp_addr) & " " & to_string(p.src_addr) & " " &
              integer'image(p.time_stamp) & " " & integer'image(recv) & " " &
              integer'image(recv - p.time_stamp) & " " & integer'image(p.hop_count) & " " &
              to_hstring(p.check_byte) & " " & to_hstring(p.payload));
    writeline(f, ln);
  end procedure;
begin

  in_ready   <= '1';
  out_valid  <= valid_i;
  out_packet <= pkt_i;

  count_proc : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        cycle_ctr <= 0;
      else
        cycle_ctr <= cycle_ctr + 1;
      end if;
    end if;
  end process;

  -- Every transfer is either logged or reported; nothing is dropped silently.
  -- recv_proc and send_proc use "wait until" instead of a sensitivity list: GHDL cannot
  -- prove that the textio calls contain no wait and would warn about a sensitivity list.
  recv_proc : process
    variable header     : boolean := false;
    variable ln         : line;
    variable from_slave : boolean;
  begin
    wait until rising_edge(clk);
    if not header then
      write(ln, string'("# requester responder send_cycle recv_cycle latency hops check data"));
      writeline(resp_file, ln);
      write(ln, string'("# requester responder send_cycle recv_cycle latency hops check data"));
      writeline(host_file, ln);
      header := true;
    end if;
    if rst = '0' and in_valid = '1' then
      from_slave := false;
      for i in SLAVE_ADDRS'range loop
        if in_packet.src_addr = SLAVE_ADDRS(i) then
          from_slave := true;
        end if;
      end loop;
      assert in_packet.dst_addr = MY_ADDR
        report "master " & to_string(MY_ADDR) & ": received packet for " &
               to_string(in_packet.dst_addr)
        severity error;
      if from_slave then
        log_line(resp_file, in_packet, cycle_ctr);
      elsif in_packet.src_addr = OTHER_ADDR then
        log_line(host_file, in_packet, cycle_ctr);
      else
        report "master " & to_string(MY_ADDR) & ": packet from unexpected source " &
               to_string(in_packet.src_addr)
          severity error;
      end if;
    end if;
  end process recv_proc;

  send_proc : process
    variable ln          : line;
    variable line_no     : natural := 0;
    variable tmp         : integer;
    variable ok          : boolean;
    variable payload_arr : std_logic_vector(PAYLOAD_BITS - 1 downto 0);
    variable dest_addr   : integer;
    variable valid_size  : integer;
    variable p           : packet_t;
    variable got_line    : boolean;

    procedure bad_line(what : string) is
    begin
      report DATA_FILE & ":" & integer'image(line_no) & ": " & what severity failure;
    end procedure;
  begin
    wait until rising_edge(clk);
    if rst = '1' then
      state     <= READ_LINE;
      valid_i   <= '0';
      gap_ctr   <= 0;
      req_count <= 0;
      is_fwd    <= false;
    else
      case state is
        when READ_LINE =>
          got_line := false;
          while not got_line and not endfile(input_file) loop
            readline(input_file, ln);
            line_no := line_no + 1;
            for i in ln'range loop            -- blank lines are skipped
              if ln(i) /= ' ' and ln(i) /= HT and ln(i) /= CR then
                got_line := true;
              end if;
            end loop;
          end loop;

          if got_line then
            read(ln, dest_addr, ok);
            if not ok then
              bad_line("cannot read destination");
            end if;
            read(ln, valid_size, ok);
            if not ok then
              bad_line("cannot read valid_size");
            end if;
            if valid_size < 0 or valid_size > PAYLOAD_BYTES then
              bad_line("valid_size=" & integer'image(valid_size) & " out of range 0.." &
                       integer'image(PAYLOAD_BYTES));
            end if;
            payload_arr := (others => '0');
            for idx in 0 to PAYLOAD_BYTES - 1 loop
              read(ln, tmp, ok);
              if not ok then
                bad_line("cannot read payload byte " & integer'image(idx));
              end if;
              if tmp < 0 or tmp > 255 then
                bad_line("payload byte " & integer'image(idx) & "=" & integer'image(tmp) &
                         " out of range 0..255");
              end if;
              if idx < valid_size then
                payload_arr((idx + 1) * 8 - 1 downto idx * 8) := std_logic_vector(to_unsigned(tmp, 8));
              end if;
            end loop;

            p            := DEFAULT_PACKET;
            p.src_addr   := MY_ADDR;
            p.dst_addr   := std_logic_vector(to_unsigned(dest_addr, 4));
            p.resp_addr  := MY_ADDR;
            p.valid_size := valid_size;
            p.time_stamp := cycle_ctr;
            p.payload    := payload_arr;
            pkt_i    <= p;
            last_req <= p;
            valid_i  <= '1';
            is_fwd   <= false;
            state    <= OFFER;
          else
            state <= DONE;
          end if;

        when OFFER =>
          if out_ready = '1' then             -- valid_i = '1', so this edge transfers
            valid_i <= '0';
            if not is_fwd then
              req_count <= req_count + 1;
            end if;
            gap_ctr <= 0;
            state   <= GAP;
          end if;

        when GAP =>
          if gap_ctr + 1 < GAP_CYCLES then
            gap_ctr <= gap_ctr + 1;
          elsif not is_fwd and req_count mod FORWARD_EVERY = 0 then
            p            := last_req;
            p.dst_addr   := OTHER_ADDR;
            p.time_stamp := cycle_ctr;
            pkt_i   <= p;
            valid_i <= '1';
            is_fwd  <= true;
            state   <= OFFER;
          else
            state <= READ_LINE;
          end if;

        when DONE =>
          null;
      end case;
    end if;
  end process send_proc;

end architecture behavioral;
