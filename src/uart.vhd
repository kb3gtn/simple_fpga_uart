--------------------------------------------------------------------------
-- uart.vhd
-- Simple RS232 like uart tx/rx design
-- Does not handle any flow control.
-- Does not perform any meaning full buffering.
--
-- Peter Fetterer <kb3gtn@gmail.com>
--------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart is
    Port (
        i_clk               : in    std_logic;  -- system clock
        i_srst              : in    std_logic;  -- synchronious reset, 1 - active
        i_baud_div          : in    std_logic_vector(15 downto 0); -- clk divider to get to baud rate
        -- UART Interface
        o_uart_tx           : out   std_logic;  -- tx bit stream
        i_uart_rx           : in    std_logic;  -- uart rx bit stream input
        -- FPGA Side
        i_tx_send             : in    std_logic_vector(7 downto 0); -- data byte in
        i_tx_send_we          : in    std_logic;  -- write enable
        o_tx_send_busy        : out   std_logic;  -- tx is busy, writes are ignored.
        o_rx_read             : out   std_logic_vector(7 downto 0); -- data byte out
        o_rx_read_valid       : out   std_logic;  -- read data valid this clock cycle
        i_rx_read_rd          : in    std_logic  -- read request, get next byte..
    );
end entity uart;

architecture Behavioral of uart is

    -- holding registers (buffer, 1 byte deep)
    signal rx_byte_last                 : std_logic_vector( 7 downto 0 );   -- buffer byte next byte to receive
    signal rx_byte_last_valid           : std_logic;   -- if rx_byte_complete is holding a valid byte
    signal rx_byte_working              : std_logic_vector( 7 downto 0 );   -- working space for symbols be received
    signal tx_byte_next                 : std_logic_vector(7 downto 0 );    -- next byte to send
    signal tx_byte_valid                : std_logic;   -- if tx_byte_next is holding a valid byte
    signal tx_byte_working              : std_logic_vector( 7 downto 0 );   -- working byte being transmitted

    -- baud divider stuff
    signal divider_count                : unsigned( 15 downto 0);   -- symbol period
    signal divider_count_div2           : unsigned( 15 downto 0);   -- 1/2 symbol period
    signal rx_symbol_count              : unsigned( 15 downto 0);   -- rx clk count periods
    signal rx_gen_state                 : integer;
    signal tx_symbol_count              : unsigned( 15 downto 0);   -- tx clk count periods
    signal tx_gen_state                 : integer;
    signal tx_active                    : std_logic;
    signal uart_tx                      : std_logic;

    signal rx_start_det                 : std_logic; -- signals that we detected the rising edge of a start bit. (start symbol_ce)
    signal rx_symbol_ce                 : std_logic; -- clock enable on rx symbol sample
    signal rx_symbol_complete           : std_logic; -- last bit being received this clock enable
    signal rx_symbol_complete_d1        : std_logic; -- delayed 1 clock
    signal tx_symbol_ce                 : std_logic; -- clock enable on tx symbol sample
    --signal tx_complete                  : std_logic; -- finished sending working byte

    signal uart_rx                      : std_logic;
    signal uart_rx_d1                   : std_logic; -- rx_uart delayed 1  ( edge detction )

begin

    -- baud_div is the counts of i_clks per bit period at the baudrate
    divider_count <= unsigned(i_baud_div);
    divider_count_div2 <= '0' & divider_count( 15 downto 1 );  -- shift left by 1 (divide by 1)

    o_uart_tx <= uart_tx;  -- register for output..
    o_tx_send_busy <= tx_byte_valid;

    o_rx_read <= rx_byte_last;
    o_rx_read_valid <= rx_byte_last_valid;

    ----------------------------------------------------------------------
    -- Receive State Machines
    -- Chain of affectors
    -- rx_start_dectector -> rx_sample_timing_gen -> rx_byte_builder
    --
    -- with TTL serial interface following the RS232 timing format, 
    -- when there is no data, the line should idle as a '1'
    -- The start of a byte transmission always starts with a start bit '0'
    -- which last 1 bit period in length ( 1/baudrate )
    -- 
    -- The rx_start_detector detect's when a falling_edge occurs on rx_uart.
    -- if the rx_sample_timing_gen is in state 0, it will start generating
    -- the sampling clock enables when rx_start_det = '1'.
    --
    -- The rx_byte_builder receives the sample_ce sigals from the sample 
    -- timing generator and shifts in the value of the rx_uart line on 
    -- each clock enable building a byte.
    --
    -- Note that the rx_sample_timing_gen does not produces a sample_ce
    -- for the start or stop bits.
    --
    -- In RS232 TTL levels, > 2.5v is a '0' and < 2.5v is a '1'.
    -- serial data is transmited as LSB first.
    --
    -- ** Top Level interaction Note:
    --
    -- There is no real output buffering going on in this code.
    -- if we finish receiving a incomming byte and the last working byte
    -- has not been read yet, we will overwrite it transparently.
    -- ( On overflow, ew drop the oldest data )
    --
    -- This shouldn't really be a big issue since the update rate is 
    -- very slow (500+ clock cycles) for each byte. It is assmed
    -- that upper level components will read the byte as soon as
    -- it is available and perform there own buffering if needed.
    --------------------------------------------------------------------------

    -- detect start bit
    rx_start_detector : process( i_clk )
    begin
        if ( rising_edge( i_clk ) ) then
            if ( i_srst = '1' ) then
                uart_rx_d1 <= '1';
                uart_rx <= i_uart_rx;  -- flop to resync to clock domain.
            else
                uart_rx <= i_uart_rx;  
                uart_rx_d1 <= uart_rx; -- detect falling edge on uart_rx
                if ( (uart_rx_d1 = '1') and ( uart_rx = '0' ) ) then
                    rx_start_det <= '1'; -- rising_edge detected
                    -- this will go high on other bits in the byte received, but the 
                    -- receive state machine will be active and ignore these pulses.
                else
                    rx_start_det <= '0'; -- no rising_edge detected
                end if;
            end if;
        end if;
    end process;
    
    -- rx sample ce generator
    rx_sample_timing_gen : process( i_clk )
    begin
        if ( rising_edge( i_clk ) ) then
            if ( i_srst = '1' ) then
                rx_symbol_ce <= '0';
                rx_symbol_count <= (others=>'0');
                rx_gen_state <= 0;
                rx_symbol_complete <= '0';
            else
                case rx_gen_state is
                when 0 =>
                    -- waiting for start detect
                    rx_symbol_ce <= '0';
                    rx_symbol_complete <= '0';
                    if ( rx_start_det = '1' ) then
                        rx_gen_state <= 1;  -- rising_edge detected (ignored for reset of byte receive)
                    end if;
                when 1 =>
                    -- need to wait 1/2 a symbol period
                    if ( rx_symbol_count = divider_count_div2 ) then
                        -- done!
                        rx_symbol_count <= (others=>'0'); -- reset bit period counter
                        rx_gen_state <= 2;
                    else
                        -- increment counter
                        rx_symbol_count <= rx_symbol_count + 1;
                        -- stay in this state.. until symbol count is reached
                    end if;
                when 2 =>
                    -- half way into the start bit...
                    -- test to see if we still see the start bit (rx_uart = 0)
                    if ( uart_rx = '0' ) then
                        rx_gen_state <= 3;
                    else
                        rx_gen_state <= 0; -- fail, go back, look for falling edge again..
                    end if;
                when 3 =>
                    -- need to wait 1 symbol period ad signal to sample bit0
                    if ( rx_symbol_count = divider_count ) then
                        rx_symbol_count <= (others=>'0');
                        rx_symbol_ce <= '1'; -- sample bit..
                        rx_gen_state <= 4;
                    else
                        rx_symbol_count <= rx_symbol_count + 1;
                        rx_symbol_ce <= '0';
                    end if;
                when 4 =>
                    -- need to wait 1 symbol period and signal to sample bit1
                    if ( rx_symbol_count = divider_count ) then
                        -- sample bit
                        rx_symbol_count <= (others=>'0');
                        rx_symbol_ce <= '1'; -- sample bit..
                        rx_gen_state <= 5;
                    else
                        -- wait
                        rx_symbol_count <= rx_symbol_count + 1;
                        rx_symbol_ce <= '0';
                    end if;
                 when 5 =>
                    -- need to wait 1 symbol period and signal to sample bit2
                    if ( rx_symbol_count = divider_count ) then
                        rx_symbol_count <= (others=>'0');
                        rx_symbol_ce <= '1'; -- sample bit..
                        rx_gen_state <= 6;
                    else
                        rx_symbol_count <= rx_symbol_count + 1;
                        rx_symbol_ce <= '0';
                    end if;
                 when 6 =>
                    -- need to wait 1 symbol period and signal to sample bit3
                    if ( rx_symbol_count = divider_count ) then
                        rx_symbol_count <= (others=>'0');
                        rx_symbol_ce <= '1'; -- sample bit..
                        rx_gen_state <= 7;
                    else
                        rx_symbol_count <= rx_symbol_count + 1;
                        rx_symbol_ce <= '0';
                    end if;
                 when 7 =>
                    -- need to wait 1 symbol period and signal to sample bit4
                    if ( rx_symbol_count = divider_count ) then
                        rx_symbol_count <= (others=>'0');
                        rx_symbol_ce <= '1'; -- sample bit..
                        rx_gen_state <= 8;
                    else
                        rx_symbol_count <= rx_symbol_count + 1;
                        rx_symbol_ce <= '0';
                    end if;
                 when 8 =>
                    -- need to wait 1 symbol period and signal to sample bit5
                    if ( rx_symbol_count = divider_count ) then
                        rx_symbol_count <= (others=>'0');
                        rx_symbol_ce <= '1'; -- sample bit..
                        rx_gen_state <= 9;
                    else
                        rx_symbol_count <= rx_symbol_count + 1;
                        rx_symbol_ce <= '0';
                    end if;
                 when 9 =>
                    -- need to wait 1 symbol period and signal to sample bit6
                    if ( rx_symbol_count = divider_count ) then
                        rx_symbol_count <= (others=>'0');
                        rx_symbol_ce <= '1'; -- sample bit..
                        rx_gen_state <= 10;
                    else
                        rx_symbol_count <= rx_symbol_count + 1;
                        rx_symbol_ce <= '0';
                    end if;
                 when 10 =>
                    -- need to wait 1 symbol period and signal to sample bit7
                    if ( rx_symbol_count = divider_count ) then
                        rx_symbol_count <= (others=>'0');
                        rx_symbol_ce <= '1'; -- sample bit..
                        rx_gen_state <= 11;
                    else
                        rx_symbol_count <= rx_symbol_count + 1;
                        rx_symbol_ce <= '0';
                    end if;
                when 11 =>
                    -- wait for stop bit, before resetting
                    -- this stops a stuck '1' line from spitting out a bunch of 0xff's
                    -- wait until the line goes idle..
                    if ( rx_symbol_count = divider_count ) then 
                        rx_symbol_count <= (others=>'0');
                        rx_symbol_ce <= '0';
                        if ( uart_rx = '1' ) then
                            rx_symbol_complete <= '1';
                            rx_gen_state <= 0;  -- ready for next byte
                        end if;
                    else
                        rx_symbol_count <= rx_symbol_count + 1;
                        rx_symbol_ce <= '0';
                    end if;
                when others =>
                    rx_gen_state <= 0; -- should never happen, reset if it does.
                end case;
            end if;
        end if;
    end process;

    rx_sym_delay1 : process( i_clk )
    begin
        if ( rising_edge(i_clk) ) then
            -- delay 1 clock cycle
            rx_symbol_complete_d1 <= rx_symbol_complete;
        end if;
    end process;
 
    rx_byte_builder : process ( i_clk )
    begin
        if ( rising_edge( i_clk ) ) then
            if ( i_srst = '1' ) then
                -- reset
                rx_byte_working <= (others=>'0');
                rx_byte_last_valid <= '0';
                rx_byte_last <= (others=>'0');
            else
                if (rx_symbol_ce = '1' ) then
                    -- shift in new input symbol
                    rx_byte_working <= uart_rx & rx_byte_working(7 downto 1);
                end if;
                -- complete_d1 will be 1 clock cycle after rx_symbol_ce for bit 7
                if ( rx_symbol_complete_d1 = '1' ) then
                    -- byte complete
                    rx_byte_last <= rx_byte_working;
                    rx_byte_last_valid <= '1';
                end if;
                -- handle rx_byte_last reads
                if ( rx_byte_last_valid = '1' ) then
                    if ( i_rx_read_rd = '1' ) then
                        rx_byte_last_valid <= '0'; -- reset valid flag for next byte.
                    end if;
                end if;
            end if;
        end if;
    end process;


    -------------------------------------------------------------------------
    -- ** Transmit State Machine
    -- * Chain of affectors
    --  tx_timing_generator -> tx_state_machine -> tx_shift_register
    --                                     tx_handler ----^
    --
    -- The tx_timing_generate just takes the i_clk signal and divides down
    -- to get the serial bit timing.  This is feed to the tx_state_machine
    -- to control what bit is being transmitted.
    --
    -- tx_state_machine checks to see if tx_byte_valid is a 1.
    -- This will cause the state machine to load the tx_shift_register
    -- with the new byte and to shift it own with a start bit prepended.
    --
    -- The tx_handler is reponsible for handling input from a higher level (UI)
    -- 
    -------------------------------------------------------------------------

    -- generater tx bit period clock enable signal tx_symbol_ce
    -- (clock divider)
    tx_timing_generator : process( i_clk )
    begin
        if ( rising_edge( i_clk )) then
            if ( i_srst = '1' ) then
                tx_symbol_count <= (others=>'0');
            else
                if ( tx_symbol_count = divider_count ) then
                    tx_symbol_ce <= '1';
                    tx_symbol_count <= (others=>'0');
                else
                    tx_symbol_ce <= '0';
                    tx_symbol_count <= tx_symbol_count + 1;
                end if;
            end if;
        end if;
    end process;

    -- transmit state machine
    tx_state_machine : process( i_clk )
    begin
        if ( rising_edge( i_clk) ) then
            if ( i_srst = '1' ) then
                tx_gen_state <= 0;
                tx_active <= '0';
                uart_tx <= '1'; -- idle state
                --tx_complete <= '0';
            else
                case tx_gen_state is
                when 0 =>
                    -- waiting for a tx byte to be ready to send
                    --tx_complete <= '0';
                    if ( tx_byte_valid = '1' ) then
                        -- got a byte to send, progress though states
                        tx_gen_state <= 1;
                        tx_byte_working <= tx_byte_next;
                        tx_active <= '1'; -- signal to tx_handler we have latched in the next byte and are going to start sending it.
                    else
                        tx_gen_state <= 0;
                        tx_active <= '0';
                        uart_tx <= '1'; -- idle
                    end if;
                when 1 =>
                    -- wait for a clock enable
                    if ( tx_symbol_ce = '1' ) then
                        -- send start bit
                        uart_tx <= '0';
                        tx_gen_state <= 2;
                    else
                        -- wait for clk enable
                        tx_gen_state <= 1;
                    end if;
                when 2 =>
                    -- wait for clock enable then send bit 0
                    if ( tx_symbol_ce = '1' ) then
                        -- send bit 1
                        uart_tx <= tx_byte_working(0);
                        tx_gen_state <= 3;
                    else
                        tx_gen_state <= 2;
                    end if;
                when 3 =>
                    -- wait for clock enable then send bit 1
                    if ( tx_symbol_ce = '1' ) then
                        uart_tx <= tx_byte_working(1);
                        tx_gen_state <= 4;
                    else
                        tx_gen_state <= 3;
                    end if;
                when 4 =>
                    -- wait for clock enable send bit 2
                    if ( tx_symbol_ce = '1' ) then
                        uart_tx <= tx_byte_working(2);
                        tx_gen_state <= 5;
                    else
                        tx_gen_state <= 4;
                    end if;
                when 5 =>
                    -- wait for clock enable send bit 3
                    if ( tx_symbol_ce = '1' ) then
                        uart_tx <= tx_byte_working(3);
                        tx_gen_state <= 6;
                    else
                        tx_gen_state <= 5;
                    end if;
                when 6 =>
                    -- wait for clock enable send bit 4
                    if ( tx_symbol_ce = '1' ) then
                        uart_tx <= tx_byte_working(4);
                        tx_gen_state <= 7;
                    else
                        tx_gen_state <= 6;
                    end if;
                when 7 =>
                    -- wait for clock enable send bit 5
                    if ( tx_symbol_ce = '1' ) then
                        uart_tx <= tx_byte_working(5);
                        tx_gen_state <= 8;
                    else
                        tx_gen_state <= 7;
                    end if;
                when 8 => 
                    -- wait for clock enable send bit 6
                    if ( tx_symbol_ce = '1' ) then
                        uart_tx <= tx_byte_working(6);
                        tx_gen_state <= 9;
                    else
                        tx_gen_state <= 8;
                    end if;
                when 9 =>
                    -- wait for clock eanble, send bit 7
                    if ( tx_symbol_ce = '1' ) then
                        uart_tx <= tx_byte_working(7);
                        tx_gen_state <= 10;
                    else
                        tx_gen_state <= 9;
                    end if;
                when 10 =>
                    -- send stop bit on next clock enable
                    if ( tx_symbol_ce = '1' ) then
                        uart_tx <= '1';
                        tx_gen_state <= 11;
                    else
                        tx_gen_state <= 10;
                    end if;
                when 11 =>
                    -- signal complete with transmit
                    -- finish stop bit period
                    if ( tx_symbol_ce = '1' ) then
                        tx_gen_state <= 0;
                        --tx_complete <= '1';
                    end if;
                when others =>
                    tx_gen_state <= 0;  -- should never get here..
                end case;
            end if;
        end if;
    end process;

                        
    -- tx input byte buffer handler
    -- handle UI to working_byte transfersin
    tx_handler : process( i_clk )
    begin
        if ( rising_edge( i_clk ) ) then
            if ( i_srst = '1' ) then
                tx_byte_valid <= '0';
            else
                -- handle new bytes comming in to transmit
                if ( i_tx_send_we = '1' ) then
                    if ( tx_byte_valid = '0' ) then
                        -- we can accept a new byte in.
                        tx_byte_next <= i_tx_send;
                        tx_byte_valid <= '1';  -- signal to tx state machine there is data ready to send
                        -- note: o_tx_send_busy <= tx_byte_valid 
                    end if;
                end if;
                -- clear event to load new incomming bytes.
                if ( tx_byte_valid = '1' ) then
                    if ( tx_active = '1' ) then
                        -- tx state machine sucked in the byte_next
                        tx_byte_valid <= '0'; -- next byte no longer valid, can accept a new data byte to go next.
                    end if;
                end if;
            end if;
        end if;
    end process;

end architecture Behavioral;

