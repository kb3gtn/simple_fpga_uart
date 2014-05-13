--------------------------------------------------------------------------------
-- Company: 
-- Engineer:
--
-- Create Date:   00:24:13 05/11/2014
-- Design Name:   
-- Module Name:   /home/kb3gtn/sandbox/mojo_board/running_lights/ISE/testbench.vhd
-- Project Name:  running_leds
-- Target Device:  
-- Tool versions:  
-- Description:   
-- 
-- VHDL Test Bench Created by ISE for module: mojo_top
-- 
-- Dependencies:
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
--
-- Notes: 
-- This testbench has been automatically generated using types std_logic and
-- std_logic_vector for the ports of the unit under test.  Xilinx recommends
-- that these types always be used for the top-level I/O of a design in order
-- to guarantee that the testbench will bind correctly to the post-implementation 
-- simulation model.
--------------------------------------------------------------------------------
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
 
-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--USE ieee.numeric_std.ALL;
 
ENTITY testbench IS
END testbench;
 
ARCHITECTURE behavior OF testbench IS 
 
    -- Component Declaration for the Unit Under Test (UUT)
 
    COMPONENT mojo_top
    PORT(
         clk50m : IN  std_logic;
         rst_n : IN  std_logic;
         cclk : IN  std_logic;
         led : OUT  std_logic_vector(7 downto 0);
         serial_tx : OUT  std_logic;
         serial_rx : IN  std_logic
        );
    END COMPONENT;
    

   --Inputs
   signal clk50m : std_logic := '0';
   signal rst_n : std_logic := '0';
   signal cclk : std_logic := '0';
   signal serial_rx : std_logic := '0';

 	--Outputs
   signal led : std_logic_vector(7 downto 0);
   signal serial_tx : std_logic;

   -- Clock period definitions
   constant clk50m_period : time := 20 ns;
   --constant cclk_period : time := 1/0 ns;
 
BEGIN
 
	-- Instantiate the Unit Under Test (UUT)
   uut: mojo_top PORT MAP (
          clk50m => clk50m,
          rst_n => rst_n,
          cclk => cclk,
          led => led,
          serial_tx => serial_tx,
          serial_rx => serial_rx
        );

   -- Clock process definitions
   clk50m_process :process
   begin
		clk50m <= '0';
		wait for clk50m_period/2;
		clk50m <= '1';
		wait for clk50m_period/2;
   end process;
 
   cclk <= '1';
	
   -- Stimulus process
   stim_proc: process
   begin		
      -- hold reset state for 100 ns.
      serial_rx <= '1'; -- idle
      rst_n <= '0'; -- reset asserted	
      wait for clk50m_period*10;
      rst_n <= '1'; -- deasserted

      wait for clk50m_period*10;
      -- insert stimulus here       
      -- serial send 0x5C
      serial_rx <= '0'; -- start bit
      wait for 8.68us;
      serial_rx <= '1'; -- bit 0
      wait for 8.68us;
      serial_rx <= '0'; -- bit 1
      wait for 8.68us;
      serial_rx <= '1'; -- bit 2
      wait for 8.68us;
      serial_rx <= '0'; -- bit 3
      wait for 8.68us;
      serial_rx <= '0'; -- bit 4
      wait for 8.68us;
      serial_rx <= '0'; -- bit 5
      wait for 8.68us;
      serial_rx <= '1'; -- bit 6
      wait for 8.68us;
      serial_rx <= '1'; -- bit 7
      wait for 8.68us;
      serial_rx <= '1'; -- stop bit
      
      -- wait for TX
      wait for 86.8us;
      
      wait;
   end process;

END;
