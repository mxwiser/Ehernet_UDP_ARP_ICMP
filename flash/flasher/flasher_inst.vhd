	component flasher is
		port (
			clk_clk               : in  std_logic                     := 'X';             -- clk
			reset_reset_n         : in  std_logic                     := 'X';             -- reset_n
			avl_csr_address       : in  std_logic_vector(5 downto 0)  := (others => 'X'); -- address
			avl_csr_read          : in  std_logic                     := 'X';             -- read
			avl_csr_readdata      : out std_logic_vector(31 downto 0);                    -- readdata
			avl_csr_write         : in  std_logic                     := 'X';             -- write
			avl_csr_writedata     : in  std_logic_vector(31 downto 0) := (others => 'X'); -- writedata
			avl_csr_waitrequest   : out std_logic;                                        -- waitrequest
			avl_csr_readdatavalid : out std_logic;                                        -- readdatavalid
			avl_mem_write         : in  std_logic                     := 'X';             -- write
			avl_mem_burstcount    : in  std_logic_vector(6 downto 0)  := (others => 'X'); -- burstcount
			avl_mem_waitrequest   : out std_logic;                                        -- waitrequest
			avl_mem_read          : in  std_logic                     := 'X';             -- read
			avl_mem_address       : in  std_logic_vector(18 downto 0) := (others => 'X'); -- address
			avl_mem_writedata     : in  std_logic_vector(31 downto 0) := (others => 'X'); -- writedata
			avl_mem_readdata      : out std_logic_vector(31 downto 0);                    -- readdata
			avl_mem_readdatavalid : out std_logic;                                        -- readdatavalid
			avl_mem_byteenable    : in  std_logic_vector(3 downto 0)  := (others => 'X')  -- byteenable
		);
	end component flasher;

	u0 : component flasher
		port map (
			clk_clk               => CONNECTED_TO_clk_clk,               --     clk.clk
			reset_reset_n         => CONNECTED_TO_reset_reset_n,         --   reset.reset_n
			avl_csr_address       => CONNECTED_TO_avl_csr_address,       -- avl_csr.address
			avl_csr_read          => CONNECTED_TO_avl_csr_read,          --        .read
			avl_csr_readdata      => CONNECTED_TO_avl_csr_readdata,      --        .readdata
			avl_csr_write         => CONNECTED_TO_avl_csr_write,         --        .write
			avl_csr_writedata     => CONNECTED_TO_avl_csr_writedata,     --        .writedata
			avl_csr_waitrequest   => CONNECTED_TO_avl_csr_waitrequest,   --        .waitrequest
			avl_csr_readdatavalid => CONNECTED_TO_avl_csr_readdatavalid, --        .readdatavalid
			avl_mem_write         => CONNECTED_TO_avl_mem_write,         -- avl_mem.write
			avl_mem_burstcount    => CONNECTED_TO_avl_mem_burstcount,    --        .burstcount
			avl_mem_waitrequest   => CONNECTED_TO_avl_mem_waitrequest,   --        .waitrequest
			avl_mem_read          => CONNECTED_TO_avl_mem_read,          --        .read
			avl_mem_address       => CONNECTED_TO_avl_mem_address,       --        .address
			avl_mem_writedata     => CONNECTED_TO_avl_mem_writedata,     --        .writedata
			avl_mem_readdata      => CONNECTED_TO_avl_mem_readdata,      --        .readdata
			avl_mem_readdatavalid => CONNECTED_TO_avl_mem_readdatavalid, --        .readdatavalid
			avl_mem_byteenable    => CONNECTED_TO_avl_mem_byteenable     --        .byteenable
		);

