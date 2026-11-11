-- =============================================================================
-- File    : slave_ip.vhd
-- Purpose : Slave processor (P2/P4/P6/P8): one operation per request, reply to a fixed master.
-- Author  : Aref Ghoreishi
-- License : MIT (see LICENSE)
-- SPDX-License-Identifier: MIT
-- =============================================================================
--   P2 "0010": sort ascending   -> reply to P9
--   P4 "0100": per-bit parity   -> reply to P9 (parity in check_byte)
--   P6 "0110": sort descending  -> reply to P1
--   P8 "1000": checksum mod 256 -> reply to P1 (sum in check_byte)
-- Only bytes 0 .. valid_size-1 are data; the reply's padding bytes are zero.
--
-- IDLE -> PROC -> SEND. in_ready is '1' only in IDLE, so a request can never
-- arrive while an earlier reply is still waiting to be sent. In SEND the reply
-- is held until out_ready.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.noc_pkg.all;

entity slave_ip is
  generic (
    MY_ADDR : addr_t := "0010"
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    in_valid   : in  std_logic;
    in_packet  : in  packet_t;
    in_ready   : out std_logic;
    out_valid  : out std_logic;
    out_packet : out packet_t;
    out_ready  : in  std_logic
  );
end entity slave_ip;

architecture behavioral of slave_ip is
  type state_t is (IDLE, PROC, SEND);
  type byte_array_t is array (0 to PAYLOAD_BYTES - 1) of unsigned(7 downto 0);

  signal state   : state_t   := IDLE;
  signal in_pkt  : packet_t;
  signal valid_i : std_logic := '0';
  signal pkt_i   : packet_t  := DEFAULT_PACKET;
begin

  in_ready   <= '1' when state = IDLE else '0';
  out_valid  <= valid_i;
  out_packet <= pkt_i;

  process (clk)
    variable data_arr   : byte_array_t;
    variable tmp_byte   : unsigned(7 downto 0);
    variable sum        : unsigned(15 downto 0);
    variable parity_vec : std_logic_vector(7 downto 0);
    variable reply      : packet_t;
    variable size       : natural range 0 to PAYLOAD_BYTES;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state   <= IDLE;
        valid_i <= '0';
      else
        case state is
          when IDLE =>
            if in_valid = '1' then
              assert in_packet.dst_addr = MY_ADDR
                report "slave " & to_string(MY_ADDR) & ": received packet for " &
                       to_string(in_packet.dst_addr)
                severity error;
              in_pkt <= in_packet;
              state  <= PROC;
            end if;

          when PROC =>
            -- The reply keeps resp_addr, valid_size, hop_count and time_stamp, so the
            -- requester can measure the round trip.
            reply            := in_pkt;
            reply.src_addr   := MY_ADDR;
            reply.check_byte := (others => '0');
            size             := in_pkt.valid_size;

            for i in 0 to PAYLOAD_BYTES - 1 loop
              if i < size then
                data_arr(i) := unsigned(in_pkt.payload((i + 1) * 8 - 1 downto i * 8));
              else
                data_arr(i) := (others => '0');
              end if;
            end loop;

            if MY_ADDR = "0010" then
              reply.dst_addr := "1001";
              for i in 0 to size - 2 loop
                for j in 0 to size - 2 - i loop
                  if data_arr(j) > data_arr(j + 1) then
                    tmp_byte        := data_arr(j);
                    data_arr(j)     := data_arr(j + 1);
                    data_arr(j + 1) := tmp_byte;
                  end if;
                end loop;
              end loop;

            elsif MY_ADDR = "0110" then
              reply.dst_addr := "0001";
              for i in 0 to size - 2 loop
                for j in 0 to size - 2 - i loop
                  if data_arr(j) < data_arr(j + 1) then
                    tmp_byte        := data_arr(j);
                    data_arr(j)     := data_arr(j + 1);
                    data_arr(j + 1) := tmp_byte;
                  end if;
                end loop;
              end loop;

            elsif MY_ADDR = "0100" then
              reply.dst_addr := "1001";
              parity_vec     := (others => '0');
              for i in 0 to size - 1 loop
                parity_vec := parity_vec xor std_logic_vector(data_arr(i));
              end loop;
              reply.check_byte := parity_vec;

            elsif MY_ADDR = "1000" then
              reply.dst_addr := "0001";
              sum            := (others => '0');
              for i in 0 to size - 1 loop
                sum := sum + resize(data_arr(i), 16);
              end loop;
              reply.check_byte := std_logic_vector(sum(7 downto 0));
            end if;

            for i in 0 to PAYLOAD_BYTES - 1 loop
              reply.payload((i + 1) * 8 - 1 downto i * 8) := std_logic_vector(data_arr(i));
            end loop;

            pkt_i   <= reply;
            valid_i <= '1';
            state   <= SEND;

          when SEND =>
            if out_ready = '1' then             -- valid_i = '1', so this edge transfers
              valid_i <= '0';
              state   <= IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;

end architecture behavioral;
