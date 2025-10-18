//-----------------------------------------------------------------------------
//
// Module: asynch_fifo
//
// Description:
// An ASYNCHRONOUS (dual clock) First-In, First-Out (FIFO) buffer.
// This module safely passes data from a write clock domain (clk_w)
// to a read clock domain (clk_r).
//
// Design Strategy:
// 1. Dual-Port RAM: Uses an array of registers as a "pseudo-dual-port" RAM.
// 2. Binary and Gray Pointers: Uses binary pointers (read_address,
//    write_address) to calculate the next address and address the RAM. It also
//    maintains Gray code versions of these pointers (read_address_gray,
//    write_address_gray) for safe clock domain crossing (CDC).
// 3. Pointer Width: Pointers are ONE BIT WIDER than the address bus
//    (e.g., 3 bits for a 4-deep FIFO). This extra MSB acts as a "wrap"
//    indicator, which is the key to distinguishing a 'full' state from an
//    'empty' state.
// 4. Synchronization: Uses a 2-flip-flop synchronizer to pass the
//    Gray code pointers between the asynchronous clock domains. This is
//    the core logic that prevents metastability from corrupting the pointers.
// 5. Status Flags: Generates 'fifo_full' in the clk_w domain and
//    'fifo_empty' in the clk_r domain.
//
//-----------------------------------------------------------------------------
module asynch_fifo(
    // --- I/O Ports ---
    clk_w,
    clk_r,
    reset,
    chip_select,
    read_enable,
    write_enable,
    data_in,
    data_out,
    fifo_full,
    fifo_empty
);

//=============================================================================
// Port Declarations
//=============================================================================
input                       clk_w,clk_r;    // Write Clock (clk_w) and Read Clock (clk_r)
input                       reset;          // Asynchronous, active-low reset (affects BOTH domains)
input                       chip_select;    // Module enable (assumed synchronous to both clocks)
input                       read_enable;    // Assert high (synchronous to clk_r) to read data
input                       write_enable;   // Assert high (synchronous to clk_w) to write data
input       [data_size-1:0] data_in;        // Data to be written (synchronous to clk_w)

output reg  [data_size-1:0] data_out;       // Data read from FIFO (synchronous to clk_r)
output                      fifo_full;      // Flag: High when FIFO is full (synchronous to clk_w)
output                      fifo_empty;     // Flag: High when FIFO is empty (synchronous to clk_r)

//=============================================================================
// Parameters
//=============================================================================
parameter fifo_depth = 4;   // User-configurable: Number of words the FIFO can store
parameter data_size  = 32;   // User-configurable: Width of each data word in bits

// This calculates the number of bits for the memory address.
// For fifo_depth = 4, $clog2(4) = 2. So, address_bit = 2.
// The pointers will be [address_bit:0], making them 3 bits wide ([2:0]).
localparam address_bit = $clog2(fifo_depth);

//=============================================================================
// Internal Signals and Registers
//=============================================================================

// --- Pointers (Binary and Gray) ---
// We maintain two sets of pointers in each clock domain:
// 1. Binary: Easy to increment (ptr + 1). Used to address the RAM.
// 2. Gray: Safe to pass across clock domains (only 1 bit changes at a time).
reg [address_bit:0] read_address       = 0, read_address_gray  = 0;
reg [address_bit:0] write_address      = 0, write_address_gray = 0;

// --- SYNCHRONIZER REGISTERS ---
// These are the 2-flip-flop chains for crossing clock domains.
// We need one chain to pass the read pointer to the write domain,
// and another to pass the write pointer to the read domain.
// (* ASYNC_REG = "TRUE" *) is a vital synthesis attribute that tells the tool
// to place these two flops physically close together to maximize the
// time for metastability to resolve, increasing reliability.

// Synchronizes Read Pointer (clk_r) into the Write Domain (clk_w)
(* ASYNC_REG = "TRUE" *) reg [address_bit:0] read_address_gray_ff1  = 0; // Stage 1: Catches async signal (can go metastable)
(* ASYNC_REG = "TRUE" *) reg [address_bit:0] read_address_gray_ff2  = 0; // Stage 2: Samples Stage 1 (output is stable)

// Synchronizes Write Pointer (clk_w) into the Read Domain (clk_r)
(* ASYNC_REG = "TRUE" *) reg [address_bit:0] write_address_gray_ff1 = 0; // Stage 1
(* ASYNC_REG = "TRUE" *) reg [address_bit:0] write_address_gray_ff2 = 0; // Stage 2


// --- FIFO Memory ---
// The actual storage for the data.
// It's an array of registers, 'fifo_depth' deep and 'data_size' wide.
reg [data_size-1:0] FIFO [fifo_depth-1:0];

//=============================================================================
// Write Logic (All logic in this block is synchronous to clk_w)
//=============================================================================
always @(posedge clk_w or negedge reset) begin
    // Asynchronous Reset Logic:
    if (!reset) begin
        write_address         <= 0;
        write_address_gray    <= 0;
        // CRITICAL: Reset the synchronizer flops to a known '0' state.
        read_address_gray_ff1 <= 0;
        read_address_gray_ff2 <= 0;
    end
    // Synchronous Logic:
    else begin
        // --- Core Write Operation ---
        // A write only happens if enabled AND the FIFO is not full.
        if (chip_select && write_enable && !fifo_full) begin
            
            // Write data into the memory array.
            // We only use the lower bits [address_bit-1:0] of the binary
            // pointer as the actual memory address.
            FIFO[write_address[address_bit-1:0]] <= data_in;

            // Increment the local binary pointer.
            write_address <= write_address + 1;
            
            // Calculate the *next* Gray code value from the *next* binary value.
            // (write_address+1) is the next binary value.
            write_address_gray <= (write_address+1) ^ ((write_address+1) >> 1);
        end

        // --- SYNCHRONIZER (Read Pointer -> Write Domain) ---
        // This logic runs UNCONDITIONALLY on every positive clk_w edge.
        // This is required to prevent the FIFO from deadlocking (e.g.,
        // if it gets full, it stops writing, but it MUST keep sampling
        // the read pointer to know when a spot becomes free).
        
        // Stage 1: The 'read_address_gray' (from the clk_r domain) is
        // sampled by the first flip-flop (ff1). This signal is
        // asynchronous to clk_w, so ff1's output might be metastable.
        read_address_gray_ff1 <= read_address_gray;
        
        // Stage 2: The output of ff1 is given one full clk_w cycle
        // to settle. The second flip-flop (ff2) samples the
        // (now stable) output of ff1.
        // 'read_address_gray_ff2' is now a stable, synchronized copy
        // of the read pointer, safe to use in the clk_w domain.
        read_address_gray_ff2 <= read_address_gray_ff1;
    end
end

//=============================================================================
// Read Logic (All logic in this block is synchronous to clk_r)
//=============================================================================
always @(posedge clk_r or negedge reset) begin
    // Asynchronous Reset Logic:
    if (!reset) begin
        read_address           <= 0;
        read_address_gray      <= 0;
        data_out               <= 0; // Reset output to a known state
        
        // CRITICAL: Reset the synchronizer flops.
        write_address_gray_ff1 <= 0;
        write_address_gray_ff2 <= 0;
    end
    // Synchronous Logic:
    else begin 
        // --- Core Read Operation ---
        // A read only happens if enabled AND the FIFO is not empty.
        if (chip_select && read_enable && !fifo_empty) begin
            
            // Read data from the memory. This is a registered read,
            // so data will appear on 'data_out' on the *next* clk_r edge.
            data_out <= FIFO[read_address[address_bit-1:0]];

            // Increment the local binary pointer.
            read_address <= read_address + 1;
            
            // Calculate the *next* Gray code value.
            read_address_gray <= (read_address+1) ^ ((read_address+1) >> 1);
        end
        // Note: If no read occurs, 'data_out' holds its previous value
        // because it is a register and there is no 'else' condition.

        // --- SYNCHRONIZER (Write Pointer -> Read Domain) ---
        // This logic runs UNCONDITIONALLY on every positive clk_r edge.
        // This prevents the FIFO from deadlocking if it becomes empty.
        // It's identical to the other synchronizer, just in the other
        // clock domain.
        
        // Stage 1: Sample the asynchronous 'write_address_gray' (from clk_w).
        // ff1 might go metastable.
        write_address_gray_ff1 <= write_address_gray;
        
        // Stage 2: Sample the output of ff1 after one clk_r cycle.
        // 'write_address_gray_ff2' is now stable and safe to use
        // in the clk_r domain.
        write_address_gray_ff2 <= write_address_gray_ff1;
    end
end

//=============================================================================
// Status Logic (Combinational)
//=============================================================================

// --- Full Condition (Generated in clk_w domain) ---
// This 'assign' statement creates combinational logic that runs in the
// clk_w domain. It compares the *local* write pointer with the
// *synchronized* read pointer.
//
// The logic for 'full' is:
// 1. The MSBs are different (write has wrapped, read has not)
// 2. The second-MSBs are different
// 3. All other bits [N-2:0] are identical.
// This is the standard, robust check for a full FIFO using Gray code.
assign fifo_full = (write_address_gray == 
                    {~read_address_gray_ff2[address_bit],     // Invert MSB
                     ~read_address_gray_ff2[address_bit-1],   // Invert 2nd MSB
                     read_address_gray_ff2[address_bit-2:0] // Match lower bits
                    });

// --- Empty Condition (Generated in clk_r domain) ---
// This 'assign' statement creates combinational logic in the clk_r domain.
// It compares the *local* read pointer with the *synchronized* write pointer.
//
// The 'empty' condition is true when the pointers are *exactly equal*.
// This works because the 'full' check (above) looks for a different
// bit pattern, so there is no ambiguity.
assign fifo_empty = (read_address_gray == write_address_gray_ff2);

endmodule