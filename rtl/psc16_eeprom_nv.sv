`timescale 1ns / 1ps

// PSC0016 / PCA9561 EEPROM behavior model.
//
// Source-only rule for this file:
// - NXP_PCA9561_eeprom.pdf says the PCA9561 contains four 6-bit
//   non-volatile EEPROM registers.
// - The factory default contents of those non-volatile registers are all 0.
// - A valid EEPROM write is programmed after the following STOP condition.
// - After a valid EEPROM write, the device does not acknowledge its I2C
//   address for 3.6 ms.
//
// Important implementation boundary:
// The supplied PSC proposal/schematic establish that an FPGA is used, but they
// do not specify the FPGA non-volatile-memory primitive, the programming flow,
// or an internal timer/oscillator for the 3.6 ms write-busy interval. Therefore
// this module is a behavioral EEPROM/NV model for simulation and source-level
// intent capture. A production FPGA implementation must replace this storage
// abstraction with the exact PSC-approved non-volatile storage mechanism.

module psc16_eeprom_nv #(
    // Datasheet-backed EEPROM write cycle time.
    parameter time WRITE_CYCLE_TIME = 3_600_000ns
) (
    input  logic        commit_write,
    input  logic [1:0]  write_start_address,
    input  logic [2:0]  write_count,
    input  logic [23:0] write_data_packed,

    output logic        write_busy,
    output logic [23:0] eeprom_data_packed
);

    // Four 6-bit EEPROM registers.
    // Register packing on eeprom_data_packed:
    //   [ 5: 0] = EEPROM byte 0 bits A..F
    //   [11: 6] = EEPROM byte 1 bits A..F
    //   [17:12] = EEPROM byte 2 bits A..F
    //   [23:18] = EEPROM byte 3 bits A..F
    logic [5:0] eeprom_register [0:3];

    assign eeprom_data_packed = {
        eeprom_register[3],
        eeprom_register[2],
        eeprom_register[1],
        eeprom_register[0]
    };

    function automatic logic [5:0] packed_write_byte(input logic [1:0] byte_index);
        case (byte_index)
            2'd0: packed_write_byte = write_data_packed[5:0];
            2'd1: packed_write_byte = write_data_packed[11:6];
            2'd2: packed_write_byte = write_data_packed[17:12];
            2'd3: packed_write_byte = write_data_packed[23:18];
        endcase
    endfunction

    initial begin
        // Datasheet factory default: all EEPROM register bits are logic 0.
        eeprom_register[0] = 6'b000000;
        eeprom_register[1] = 6'b000000;
        eeprom_register[2] = 6'b000000;
        eeprom_register[3] = 6'b000000;
        write_busy = 1'b0;
    end

    always @(posedge commit_write) begin : commit_eeprom_write
        // The datasheet says up to four bytes may be sent sequentially.
        // It does not explicitly state wrap behavior if a multi-byte write
        // starts near EEPROM byte 3. To avoid adding undocumented behavior,
        // this model commits only addresses that exist between the selected
        // starting address and EEPROM byte 3.
        for (int unsigned i = 0; i < write_count; i++) begin
            int unsigned absolute_address;

            absolute_address = int'(write_start_address) + i;
            if (absolute_address < 4) begin
                eeprom_register[absolute_address] = packed_write_byte(i[1:0]);
            end
        end

        // Behavioral model of the datasheet write-busy interval.
        // This delay is intentionally not hidden: it represents the PCA9561
        // behavior, while the exact FPGA timer implementation remains outside
        // the supplied documentation.
        write_busy = 1'b1;
        #(WRITE_CYCLE_TIME);
        write_busy = 1'b0;
    end

endmodule
