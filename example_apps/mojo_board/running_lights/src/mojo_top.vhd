library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity mojo_top is
    Port ( 
        clk50m      : in  STD_LOGIC;
        rst_n       : in  STD_LOGIC;
        cclk        : in  STD_LOGIC; -- this comes from the AVR, it a clock when programing the FPGA, steady '1' when done.
        led         : out  STD_LOGIC_VECTOR (7 downto 0);

        -- spi interface shared with AVR and SPI flash chip
        --spi_mosi    : in  STD_LOGIC;
        --spi_miso    : out  STD_LOGIC;
        --spi_ss      : in  STD_LOGIC;
        --spi_sck     : in  STD_LOGIC;
        --spi_channel : in  STD_LOGIC_VECTOR (3 downto 0);

        -- avr rs232 interface (ttl levels)
        -- avr_tx      : in  STD_LOGIC;
        -- avr_rx      : in  STD_LOGIC;
        -- avr_rx_busy : in  STD_LOGIC

        -- RS232
        serial_tx   : out STD_LOGIC;  -- 3rd pin up from uC outside.
        serial_rx   : in  STD_LOGIC   -- 4th pin up from uC outside.
    );
end mojo_top;

architecture Behavioral of mojo_top is

    component uart is
    port (
        i_clk               : in    std_logic;  -- system clock
        i_srst              : in    std_logic;  -- synchronious reset, 1 - active
        i_baud_div          : in    std_logic_vector(15 downto 0);  -- clk divider to get to baud rate
        -- uart interface
        o_uart_tx           : out   std_logic;  -- tx bit stream
        i_uart_rx           : in    std_logic;  -- uart rx bit stream input
        -- fpga side
        i_tx_send             : in    std_logic_vector(7 downto 0); -- data byte in
        i_tx_send_we          : in    std_logic;  -- write enable
        o_tx_send_busy        : out   std_logic;  -- tx is busy, writes are ignored.
        o_rx_read             : out   std_logic_vector(7 downto 0); -- data byte out
        o_rx_read_valid       : out   std_logic;  -- read data valid this clock cycle
        i_rx_read_rd          : in    std_logic  -- read request, get next byte..
    );
    end component uart;

    --###########################################################
    --# Signal Definitions
    --###########################################################

    signal baud_div          : std_logic_vector( 15 downto 0);
    signal tx_byte           : std_logic_vector( 7 downto 0);
    signal tx_byte_we        : std_logic;
    signal tx_byte_busy      : std_logic;
    signal rx_byte           : std_logic_vector( 7 downto 0);
    signal rx_byte_valid     : std_logic;
    signal rx_byte_rd        : std_logic;

    -- output register for driving the LEDs
    signal led_reg          : std_logic_vector(7 downto 0);
    
    -- for the running lights example..
    -- Numerically Controlled Oscilator Phase Accumulator Reg
    signal nco_acc_reg      : unsigned( 31 downto 0 );
    -- NCO Frequency Turning word (constant for now..)
    -- new uart could be used to update this register and
    -- change the update rate of the LEDs.
    constant  nco_ftw       : unsigned( 31 downto 0 ) := x"000001AE";
    -- nco output clock enable
    signal nco_clk_en       : std_logic;
    -- nco acc msb last
    signal nco_acc_msb_last : std_logic;
    -- sync reset signal
    signal srst             : std_logic;

begin

    baud_div <= x"01B2";  -- 115200

    uart_1 : uart 
    port map (
        i_clk                   => clk50m,
        i_srst                  => srst,
        i_baud_div              => baud_div,
        -- uart interface
        o_uart_tx               => serial_tx,
        i_uart_rx               => serial_rx,
        -- fpga side
        i_tx_send               => tx_byte,
        i_tx_send_we            => tx_byte_we,
        o_tx_send_busy          => tx_byte_busy,
        o_rx_read               => rx_byte,
        o_rx_read_valid         => rx_byte_valid,
        i_rx_read_rd            => rx_byte_rd
    );

    -- serial loopback statemachine
    -- bytes received, are re-transmitted back out.
    serial_sm : process( clk50m )
    begin
        if ( rising_edge( clk50m ) ) then
            if ( srst = '1' ) then
                tx_byte <= (others=>'0');
                tx_byte_we <= '0';
                rx_byte_rd <= '0';
            else
                if ( rx_byte_valid = '1' and tx_byte_busy = '0' ) then
                    -- we have data we can read and send on tx
                    rx_byte_rd <= '1';  -- ack for uart read..
                    tx_byte <= rx_byte;
                    tx_byte_we <= '1';
                else
                    -- don't do anything
                    rx_byte_rd <= '0';
                    tx_byte_we <= '0';
                end if;
            end if;
        end if;
    end process;


    -- connect led reg to led output pins
    -- led <= led_reg;
    led <= tx_byte;  -- show value of byte on LEDs

    -- generate synchronious reset signal for
    -- synchronious blocks
    rst_sync : process( clk50m )
    begin
        if ( rising_edge(clk50m) ) then
            if ( rst_n = '0' ) then
                -- reset active
                srst <= '1';
                -- for now, just hardcode the nco rate at startup
                -- 0x1AE ~= 10 Hz rate.. (10.0117176818 Hz)
                -- freq = (nco_ftw / 2^31-1)*50e6
                -- nco_ftw = ( Freq / 50e6 ) * (2^31-1)
                -- nco_ftw <= x"000001AE";
            else
                srst <= '0';
            end if;
        end if;
    end process;

    -- generate an output clock enable
    -- at a defined rate
    NCO_1 : process( clk50m )
    begin
        if ( rising_edge( clk50m ) ) then
            if ( srst = '1' ) then
                -- in reset
                nco_acc_reg <= (others=>'0');
                nco_acc_msb_last <= '0';
            else
                -- not in reset
                nco_acc_reg <= nco_acc_reg + nco_ftw;
                nco_acc_msb_last <= nco_acc_reg(31);
                -- detect falling edge of MSB and generate a 1 clk period enable signal
                -- with it.
                if ( (nco_acc_reg(31) = '0') and (nco_acc_msb_last = '1')) then
                    nco_clk_en <= '1';
                else
                    nco_clk_en <= '0';
                end if;
            end if;
        end if;
    end process;

    -- update led register on nco_clk_en = '1'
    led_ring_1 : process( clk50m )
    begin
        if ( rising_edge( clk50m ) ) then
            if ( srst = '1' ) then
                -- reset state
                led_reg <= x"01";
            else
                -- not in reset
                if ( nco_clk_en = '1' ) then
                    -- shift led ring right 1
                    led_reg <= led_reg(6 downto 0 ) & led_reg(7); 
                end if;
            end if;
        end if;
    end process;

end Behavioral;

