simple_fpga_uart
================

A Simple Serial UART design in VHDL for an FPGA.


VHDL Templates
----------------

<pre>
   component uart is
    port (
        i_clk                 : in    std_logic;  -- system clock
        i_srst                : in    std_logic;  -- synchronious reset, 1 - active
        i_baud_div            : in    std_logic_vector(15 downto 0);  -- clk divider to get to baud rate
        -- uart interface
        o_uart_tx             : out   std_logic;  -- tx bit stream
        i_uart_rx             : in    std_logic;  -- uart rx bit stream input
        -- fpga side
        i_tx_send             : in    std_logic_vector(7 downto 0); -- data byte in
        i_tx_send_we          : in    std_logic;  -- write enable
        o_tx_send_busy        : out   std_logic;  -- tx is busy, writes are ignored.
        o_rx_read             : out   std_logic_vector(7 downto 0); -- data byte out
        o_rx_read_valid       : out   std_logic;  -- read data valid this clock cycle
        i_rx_read_rd          : in    std_logic  -- read request, get next byte..
    );
    end component uart;


    uart_1 : uart 
    port map (
        i_clk                   => clk,             -- Fast System Clock (mojoboard uses 50 MHz)
        i_srst                  => srst,            -- sync reset with system clock
        i_baud_div              => baud_div,        -- clockcycles per baud symbol.
        -- uart interface
        o_uart_tx               => serial_tx,       -- tx line serial to fpga io pin
        i_uart_rx               => serial_rx,       -- rx line serial from fpga io pin
        -- fpga side
        i_tx_send               => tx_byte,         -- byte to send
        i_tx_send_we            => tx_byte_we,      -- write enable for the byte to send
        o_tx_send_busy          => tx_byte_busy,    -- indication that the transmit is busy.
        o_rx_read               => rx_byte,         -- receive byte to read
        o_rx_read_valid         => rx_byte_valid,   -- indication the byte is valid for reading
        i_rx_read_rd            => rx_byte_rd       -- ack reading of the data.. 
    );

</pre>
