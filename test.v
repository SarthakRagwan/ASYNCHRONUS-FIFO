//=============================================================================
//  Project      : Asynchronous FIFO Verification
//  File Name    : testbench.v
//  Author       : Sarthak Kumar
//  Description  :
//
//  🧠 PURPOSE
//  ---------------------------------------------------------------------------
//  This testbench verifies the functional correctness of an asynchronous FIFO.
//  It drives independent write and read clocks, applies multiple stimulus
//  patterns, automatically checks data correctness, and logs pass/fail reports.
//
//  ✅ KEY FEATURES
//  ---------------------------------------------------------------------------
//  - Independent asynchronous write/read clocks (different frequencies).
//  - Self-checking mechanism using expected-data comparison.
//  - Multiple test scenarios (basic, boundary, interleaved, and concurrent).
//  - Human-readable simulation logs (OK / ERROR).
//  - Waveform generation compatible with GTKWave or other viewers.
//
//  🧩 HOW TO RUN
//  ---------------------------------------------------------------------------
//      iverilog -o fifo_tb testbench.v main.v
//      vvp fifo_tb
//      gtkwave test.vcd   // (optional waveform view)
//
//  ---------------------------------------------------------------------------
//  License : Open for educational and academic usage.
//=============================================================================

`timescale 1ps/1ps
`include "main.v"  // Include the FIFO design module

//-----------------------------------------------------------------------------
// Top-Level Testbench Module
//-----------------------------------------------------------------------------
module test();

//=============================================================================
// 1️⃣ Parameter Declarations
//-----------------------------------------------------------------------------
// Defines FIFO configuration: word width and depth.
//=============================================================================
parameter fifo_depth = 4;       // FIFO depth (number of storage entries)
parameter data_size  = 32;      // Data width in bits

//=============================================================================
// 2️⃣ Signal Declarations
//-----------------------------------------------------------------------------
// These signals connect the testbench and the DUT (Device Under Test).
//=============================================================================

//--- Clock and Control Signals ---
reg clk_w, clk_r;               // Asynchronous write and read clocks
reg reset;                      // Active-low reset for FIFO
reg chip_select;                // Enables FIFO for access
reg read_enable;                // Triggers read operation
reg write_enable;               // Triggers write operation

//--- Data Signals ---
reg  [data_size-1:0] data_in;   // Input data for writing into FIFO
wire [data_size-1:0] data_out;  // Output data read from FIFO

//--- Status Signals ---
wire fifo_full;                 // Indicates FIFO is full (cannot write)
wire fifo_empty;                // Indicates FIFO is empty (cannot read)

// Calculate internal address width based on FIFO depth
localparam address_bits = $clog2(fifo_depth);

//=============================================================================
// 3️⃣ Device Under Test (DUT) Instantiation
//-----------------------------------------------------------------------------
// Instantiates the asynchronous FIFO being tested.
//=============================================================================
asynch_fifo dut (
    .clk_w(clk_w),
    .clk_r(clk_r),
    .reset(reset),
    .chip_select(chip_select),
    .read_enable(read_enable),
    .write_enable(write_enable),
    .data_in(data_in),
    .data_out(data_out),
    .fifo_full(fifo_full),
    .fifo_empty(fifo_empty)
);

//=============================================================================
// 4️⃣ Clock and Reset Generation
//-----------------------------------------------------------------------------
// Two independent clocks simulate asynchronous domains.
//=============================================================================

// Write clock toggles every 5 ps (period = 10 ps)
always #5 clk_w = ~clk_w;

// Read clock toggles every 8 ps (period = 16 ps)
always #8 clk_r = ~clk_r;

// Initialization and reset sequence
initial begin
    clk_w        = 1'b0;
    clk_r        = 1'b0;
    chip_select  = 1'b0;
    read_enable  = 1'b0;
    write_enable = 1'b0;
    reset        = 1'b0;       // Assert reset initially (active low)
    #2 reset     = 1'b1;       // Deassert reset after 2 ps
end

//=============================================================================
// 5️⃣ Waveform Dump and Simulation Termination
//-----------------------------------------------------------------------------
// Generates VCD (waveform) file for post-simulation analysis.
// Prints summary results and terminates simulation.
//=============================================================================
initial begin
    $dumpfile("test.vcd");
    $dumpvars(0, test);

    // Allow full test to complete
    #2000;

    // Display summary statistics
    $display("--------------------------------------------------------");
    $display("TEST SUMMARY:");
    $display("Total OK    = %0d", total_ok);
    $display("Total ERROR = %0d", total_error);
    if (total_error == 0)
        $display("ALL TESTS PASSED SUCCESSFULLY!");
    else
        $display("TEST FAILED — ERRORS DETECTED!");
    $display("--------------------------------------------------------");
    $finish;
end

//=============================================================================
// 6️⃣ Internal Storage and Scoreboard Mechanism
//-----------------------------------------------------------------------------
// The testbench keeps track of all written data so that every read operation
// can be automatically verified against the expected result.
//=============================================================================
integer i;                                   // Loop counter
reg [data_size-1:0] expected [0:255];        // Memory for expected values
integer write_ptr = 0;                       // Pointer for expected write index
integer read_ptr  = 0;                       // Pointer for expected read index
integer total_ok = 0;                        // Count of successful comparisons
integer total_error = 0;                     // Count of mismatched data

//=============================================================================
// 7️⃣ WRITE TASK
//-----------------------------------------------------------------------------
// Performs one FIFO write operation. Logs actions and stores the value in the
// expected array for later verification.
//=============================================================================
task write(input [data_size-1:0] data);
begin
    @(posedge clk_w) begin
        chip_select  = 1'b1;
        write_enable = 1'b1;
        data_in      = data;

        if (!fifo_full) begin
            expected[write_ptr] = data; // Record data for later checking
            write_ptr = write_ptr + 1;
            $display($time, " : WRITE : FIFO[%2d] <= %0d", dut.write_address % fifo_depth, data_in);
        end else begin
            $display($time, " : WRITE : FIFO FULL, ignoring data %0d", data_in);
        end

        #1 write_enable = 1'b0; // Short pulse for one write cycle
    end
end
endtask

//=============================================================================
// 8️⃣ READ TASK
//-----------------------------------------------------------------------------
// Performs one FIFO read operation and checks if the output data matches
// the expected value stored during write. Reports "OK" or "ERROR" accordingly.
//=============================================================================
reg [address_bits:0] address_used;
reg fifo_was_empty;

task read();
begin
    // Trigger read request
    @(posedge clk_r) begin
        chip_select  = 1'b1;
        read_enable  = 1'b1;
        address_used   = dut.read_address;
        fifo_was_empty = fifo_empty;
    end

    // Validate output data
    @(posedge clk_r) begin
        if(!fifo_was_empty) begin
            if (data_out !== expected[read_ptr]) begin
                $display($time, " : READ  : FIFO[%2d] : MISMATCH  Expected=%0d Got=%0d",
                         address_used % fifo_depth, expected[read_ptr], data_out);
                total_error = total_error + 1;
            end else begin
                $display($time, " : READ  : FIFO[%2d] => %0d",
                         address_used % fifo_depth, data_out);
                total_ok = total_ok + 1;
            end
            read_ptr = read_ptr + 1;
        end else
            $display($time, " : READ  : FIFO[%2d] : EMPTY (No Data)", address_used % fifo_depth);

        chip_select  = 1'b1;
        read_enable  = 1'b0;
    end
end
endtask

//=============================================================================
// 9️⃣ TEST SEQUENCES
//-----------------------------------------------------------------------------
// Sequential and concurrent test patterns covering various FIFO scenarios.
//=============================================================================
initial begin
    //---------------------------------------------------------------------
    // TEST 1: Basic Sequential Write and Read
    //---------------------------------------------------------------------
    $display("TEST 1 : Basic Write/Read Verification");
    write(1);
    write(10);
    write(100);
    read();
    read();
    read();

    //---------------------------------------------------------------------
    // TEST 2: Interleaved Write and Read Operations
    //---------------------------------------------------------------------
    $display("TEST 2 : Interleaved Write/Read");
    for (i = 0; i < fifo_depth; i = i + 1) begin
        write(2**i);
        read();
    end

    //---------------------------------------------------------------------
    // TEST 3: Fill FIFO Completely Then Read All
    //---------------------------------------------------------------------
    $display("TEST 3 : Full FIFO Write/Read");
    for (i = 0; i < fifo_depth; i = i + 1)
        write(2**i);
    for (i = 0; i < fifo_depth; i = i + 1)
        read();

    //---------------------------------------------------------------------
    // TEST 4: Attempt Extra Write on Full FIFO
    //---------------------------------------------------------------------
    $display("TEST 4 : Overflow Protection Check");
    for (i = 0; i < fifo_depth; i = i + 1)
        write(2**i);
    write(16);  // Should trigger "FIFO FULL"
    for (i = 0; i < fifo_depth; i = i + 1)
        read();

    //---------------------------------------------------------------------
    // TEST 5: Attempt Read on Empty FIFO
    //---------------------------------------------------------------------
    $display("TEST 5 : Underflow Protection Check");
    read();  // Should display "EMPTY"

    //---------------------------------------------------------------------
    // TEST 6: Continuous Write with Delay
    //---------------------------------------------------------------------
    $display("TEST 6 : Continuous Write with Delay");
    chip_select = 1'b1;
    for (i = 0; i < fifo_depth; i = i + 1) begin
        write(i**2);
        #10; // Small delay between writes
    end

    //---------------------------------------------------------------------
    // TEST 7: Continuous Read with Delay
    //---------------------------------------------------------------------
    $display("TEST 7 : Continuous Read with Delay");
    for (i = 0; i < fifo_depth; i = i + 1) begin
        #10;
        read();
    end

    //---------------------------------------------------------------------
    // TEST 8: Write After FIFO Empty
    //---------------------------------------------------------------------
    $display("TEST 8 : Write After Empty FIFO");
    write(55);

    //---------------------------------------------------------------------
    // TEST 9: Immediate Read After Write
    //---------------------------------------------------------------------
    $display("TEST 9 : Immediate Read After Write");
    read();

    //---------------------------------------------------------------------
    // TEST 10: Concurrent Read and Write (Asynchronous Stress Test)
    //---------------------------------------------------------------------
    $display("TEST 10 : Concurrent Read/Write Operations");

    // Preload half the FIFO
    for (i = 0; i < fifo_depth/2; i = i + 1)
        write(i + 100);

    // Fork parallel read and write processes
    fork
        // Writer Thread
        begin : WRITE_THREAD
            for (i = fifo_depth/2; i < fifo_depth + 4; i = i + 1) begin
                write(i + 200);
                #6; // Slight offset to make clocks interact
            end
        end

        // Reader Thread
        begin : READ_THREAD
            for (i = 0; i < fifo_depth + 4; i = i + 1) begin
                #10;
                read();
            end
        end
    join
end // end initial
endmodule
