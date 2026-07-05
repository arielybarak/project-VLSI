LIBRARY IEEE;
  use IEEE.std_logic_1164.all;


PACKAGE dpram72x128_cb_timingP IS

  CONSTANT numOut    : INTEGER := 72;
  CONSTANT wordDepth : INTEGER := 128;
  CONSTANT numAddr   : INTEGER := 7;

  CONSTANT cycle     : TIME := 10 ns;
  CONSTANT tDelta    : TIME := 0.01 ns;

  CONSTANT tOUTU     : TIME := 1.066 ns;
  CONSTANT tACC0     : TIME := 1.62947 ns;
  CONSTANT tOE       : TIME := 0.699 ns;
  CONSTANT tOEZ0     : TIME := 0.744 ns;
  CONSTANT tCYC      : TIME := 2.2046 ns;
  CONSTANT tCLA     : TIME := 0.204 ns;
  CONSTANT tCLP     : TIME := 0.363 ns;
  CONSTANT tWS       : TIME := 0 ns;
  CONSTANT tWH       : TIME := 0.329 ns;
  CONSTANT tAS       : TIME := 0 ns;
  CONSTANT tAH       : TIME := 0.403 ns;
  CONSTANT tIS       : TIME := 0.025 ns;
  CONSTANT tIH       : TIME := 0.382533 ns;
  CONSTANT tCSS       : TIME := 0.294 ns;
  CONSTANT tCH       : TIME := 0.053 ns;

END dpram72x128_cb_timingP;

-- ---------------------------------------------------------------------------
-- SRAM timing terms -> generic naming
-- ---------------------------------------------------------------------------
-- vhd term        | generic name
-- ----------------|------------------------------------------------
-- tACC0           | t_pd  (read clk->Q / access time)
-- tCYC            | min cycle time
-- tAS/tIS/tCSS/tWS| t_setup (addr / data-in / chip-sel / write-en)
-- tAH/tIH/tCH/tWH | t_hold  (addr / data-in / chip-sel / write-en)
-- tOE             | out-enable -> valid
-- tOEZ0           | out-enable -> Z (tristate off)
-- tOUTU           | output hold (data valid until)
-- tCLA/tCLP       | min clk pulse (low / width)
-- cycle           | char reference cycle (10 ns, ignore)
-- ---------------------------------------------------------------------------
-- note: no t_cd (min/contamination delay) -- spec pkg lists worst-case only.
--       t_pd ~= tACC0.
-- ---------------------------------------------------------------------------