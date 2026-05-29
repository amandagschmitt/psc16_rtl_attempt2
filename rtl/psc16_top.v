`timescale 1ns / 1ps

// PSC0016 top-level behavioral RTL model.
//
// Only the supplied documents are used as source material:
// - NXP_PCA9561_eeprom.pdf:
//   PCA9561 I2C address, control register, command table, EEPROM behavior,
//   MUX_SELECT behavior, MUX_IN readback, WP behavior, open-drain outputs,
//   START/STOP/ACK/NACK transaction behavior, and 3.6 ms EEPROM write busy.
// - PSC0016 EEPROM DIP SWITCH Proposal 020426.pdf:
//   PSC0016 is intended to recreate NXP PCA9561PW behavior in an FPGA, with
//   four 6-bit non-volatile storage registers, I2C up to 400 kHz, and the
//   FPGA implementation itself called out as a remaining risk.
// - SCH-PSC0016-A1.pdf:
//   External PSC0016 footprint names and pin-level signal set.
//
// No undocumented dummy commands, no undocumented output inversion, no assumed
// oscillator, and no vendor-specific FPGA non-volatile primitive are added here.

module psc16_top #(
    parameter integer EEPROM_WRITE_CYCLE_TIME = 3_600_000
) (
    input  wire scl,
    inout  wire sda,

    input  wire a0,
    input  wire a1,
    input  wire wp,
    input  wire mux_select,

    input  wire mux_in_a,
    input  wire mux_in_b,
    input  wire mux_in_c,
    input  wire mux_in_d,
    input  wire mux_in_e,
    input  wire mux_in_f,

    inout  wire mux_out_a,
    inout  wire mux_out_b,
    inout  wire mux_out_c,
    inout  wire mux_out_d,
    inout  wire mux_out_e,
    inout  wire mux_out_f
);

    localparam [2:0] I2C_IDLE               = 3'd0;
    localparam [2:0] I2C_RECEIVE_BYTE       = 3'd1;
    localparam [2:0] I2C_ACK_SETUP          = 3'd2;
    localparam [2:0] I2C_ACK_HOLD           = 3'd3;
    localparam [2:0] I2C_TRANSMIT_BYTE      = 3'd4;
    localparam [2:0] I2C_RECEIVE_MASTER_ACK = 3'd5;
    localparam [2:0] I2C_MASTER_ACK_DONE    = 3'd6;

    localparam [1:0] BYTE_IS_ADDRESS     = 2'd0;
    localparam [1:0] BYTE_IS_CONTROL     = 2'd1;
    localparam [1:0] BYTE_IS_EEPROM_DATA = 2'd2;

    localparam [2:0] AFTER_ACK_IDLE        = 3'd0;
    localparam [2:0] AFTER_ACK_IGNORE      = 3'd1;
    localparam [2:0] AFTER_ACK_CONTROL     = 3'd2;
    localparam [2:0] AFTER_ACK_EEPROM_DATA = 3'd3;
    localparam [2:0] AFTER_ACK_TRANSMIT    = 3'd4;

    wire [23:0] eeprom_data_packed;
    wire        eeprom_write_busy;

    reg         commit_eeprom_write;
    reg  [1:0]  pending_write_start_address;
    reg  [2:0]  pending_write_count;
    reg  [23:0] pending_write_data_packed;
    reg         pending_write_valid;
    reg         pending_write_overflow;

    reg         sda_drive_low;
    reg         previous_scl;
    reg         previous_sda;

    reg  [2:0]  i2c_state;
    reg  [1:0]  byte_phase;
    reg  [2:0]  after_ack_action;

    reg         ack_to_send;
    reg  [7:0]  received_byte;
    reg  [7:0]  transmit_byte;
    reg  [2:0]  bit_index;
    reg  [7:0]  control_register;
    reg  [1:0]  read_eeprom_pointer;
    reg         master_ack_received;

    reg         output_command_active;
    reg  [7:0]  output_command;

    wire [6:0] i2c_slave_address = {5'b10011, a1, a0};
    wire [5:0] mux_input_data = {
        mux_in_f,
        mux_in_e,
        mux_in_d,
        mux_in_c,
        mux_in_b,
        mux_in_a
    };

    reg [5:0] selected_mux_output_data;

    reg       scl_rising;
    reg       scl_falling;
    reg       start_condition;
    reg       stop_condition;
    reg [7:0] next_received_byte;

    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    // PCA9561 MUX_OUT pins are open-drain. A stored/selected 0 actively pulls
    // the pin low. A stored/selected 1 releases the pin to the external pullup.
    assign mux_out_a = selected_mux_output_data[0] ? 1'bz : 1'b0;
    assign mux_out_b = selected_mux_output_data[1] ? 1'bz : 1'b0;
    assign mux_out_c = selected_mux_output_data[2] ? 1'bz : 1'b0;
    assign mux_out_d = selected_mux_output_data[3] ? 1'bz : 1'b0;
    assign mux_out_e = selected_mux_output_data[4] ? 1'bz : 1'b0;
    assign mux_out_f = selected_mux_output_data[5] ? 1'bz : 1'b0;

    psc16_eeprom_nv #(
        .WRITE_CYCLE_TIME(EEPROM_WRITE_CYCLE_TIME)
    ) u_eeprom_nv (
        .commit_write(commit_eeprom_write),
        .write_start_address(pending_write_start_address),
        .write_count(pending_write_count),
        .write_data_packed(pending_write_data_packed),
        .write_busy(eeprom_write_busy),
        .eeprom_data_packed(eeprom_data_packed)
    );

    function [5:0] eeprom_register_value;
        input [1:0] address;
        begin
            case (address)
                2'd0: eeprom_register_value = eeprom_data_packed[5:0];
                2'd1: eeprom_register_value = eeprom_data_packed[11:6];
                2'd2: eeprom_register_value = eeprom_data_packed[17:12];
                2'd3: eeprom_register_value = eeprom_data_packed[23:18];
                default: eeprom_register_value = 6'b000000;
            endcase
        end
    endfunction

    function control_is_eeprom_address;
        input [7:0] value;
        begin
            control_is_eeprom_address = (value == 8'h00) ||
                                        (value == 8'h01) ||
                                        (value == 8'h02) ||
                                        (value == 8'h03);
        end
    endfunction

    function control_is_mux_input_address;
        input [7:0] value;
        begin
            control_is_mux_input_address = (value == 8'hFF);
        end
    endfunction

    function control_is_output_command;
        input [7:0] value;
        begin
            // NXP Table 5 command register values:
            // F0/F4/F8/FC select EEPROM byte 0/1/2/3.
            // F1/F5/F9/FD select MUX_IN when MUX_SELECT=1, otherwise EEPROM byte n.
            // F2/F6/FA/FE select MUX_IN.
            // F3/F7/FB are not listed as valid commands. FF is valid only as the
            // MUX_IN read address from Table 4, not as an output command.
            control_is_output_command = (value[7:4] == 4'hF) &&
                                        (value[1:0] != 2'b11);
        end
    endfunction

    function control_is_valid;
        input [7:0] value;
        begin
            control_is_valid = control_is_eeprom_address(value) ||
                               control_is_mux_input_address(value) ||
                               control_is_output_command(value);
        end
    endfunction

    function [7:0] read_data_for_control;
        input unused;
        begin
            if (control_is_eeprom_address(control_register)) begin
                read_data_for_control = {2'b00, eeprom_register_value(read_eeprom_pointer)};
            end else if (control_is_mux_input_address(control_register)) begin
                read_data_for_control = {2'b00, mux_input_data};
            end else begin
                // The supplied documents define output command effects, but do not
                // define readback data for command-register values. Return zeros so
                // no undocumented command-read behavior is invented.
                read_data_for_control = 8'h00;
            end
        end
    endfunction

    task clear_pending_write;
        begin
            pending_write_valid = 1'b0;
            pending_write_overflow = 1'b0;
            pending_write_count = 3'd0;
            pending_write_data_packed = 24'h000000;
        end
    endtask

    task store_pending_write_byte;
        input [5:0] data;
        begin
            case (pending_write_count)
                3'd0: pending_write_data_packed[5:0] = data;
                3'd1: pending_write_data_packed[11:6] = data;
                3'd2: pending_write_data_packed[17:12] = data;
                3'd3: pending_write_data_packed[23:18] = data;
                default: pending_write_overflow = 1'b1;
            endcase

            if (pending_write_count < 3'd4) begin
                pending_write_count = pending_write_count + 3'd1;
            end
        end
    endtask

    task pulse_eeprom_commit;
        begin
            commit_eeprom_write = 1'b1;
            #1;
            commit_eeprom_write = 1'b0;
        end
    endtask

    task finish_transaction_on_stop;
        begin
            sda_drive_low = 1'b0;
            i2c_state = I2C_IDLE;
            byte_phase = BYTE_IS_ADDRESS;

            if (pending_write_valid &&
                (pending_write_count != 3'd0) &&
                !pending_write_overflow &&
                !wp) begin
                pulse_eeprom_commit();
            end

            clear_pending_write();
        end
    endtask

    task request_ack;
        input ack_value;
        input [2:0] action;
        begin
            ack_to_send = ack_value;
            after_ack_action = ack_value ? action : AFTER_ACK_IGNORE;
            i2c_state = I2C_ACK_SETUP;
        end
    endtask

    task start_receiving;
        input [1:0] next_phase;
        begin
            received_byte = 8'h00;
            bit_index = 3'd7;
            byte_phase = next_phase;
            i2c_state = I2C_RECEIVE_BYTE;
        end
    endtask

    task begin_transmit_byte;
        input [7:0] value;
        begin
            transmit_byte = value;
            bit_index = 3'd7;
            sda_drive_low = (value[7] == 1'b0);
            i2c_state = I2C_TRANSMIT_BYTE;
        end
    endtask

    task handle_address_byte;
        input [7:0] value;
        reg address_matches;
        reg read_transfer;
        begin
            address_matches = (value[7:1] == i2c_slave_address);
            read_transfer = value[0];

            if (!address_matches || eeprom_write_busy) begin
                request_ack(1'b0, AFTER_ACK_IGNORE);
            end else if (read_transfer) begin
                if (control_is_eeprom_address(control_register)) begin
                    read_eeprom_pointer = control_register[1:0];
                end
                request_ack(1'b1, AFTER_ACK_TRANSMIT);
            end else begin
                clear_pending_write();
                request_ack(1'b1, AFTER_ACK_CONTROL);
            end
        end
    endtask

    task handle_control_byte;
        input [7:0] value;
        begin
            if (!control_is_valid(value)) begin
                request_ack(1'b0, AFTER_ACK_IGNORE);
            end else begin
                control_register = value;

                if (control_is_output_command(value)) begin
                    output_command_active = 1'b1;
                    output_command = value;
                    clear_pending_write();
                    request_ack(1'b1, AFTER_ACK_IGNORE);
                end else if (control_is_eeprom_address(value)) begin
                    pending_write_valid = 1'b1;
                    pending_write_start_address = value[1:0];
                    pending_write_count = 3'd0;
                    pending_write_overflow = 1'b0;
                    pending_write_data_packed = 24'h000000;
                    read_eeprom_pointer = value[1:0];
                    request_ack(1'b1, AFTER_ACK_EEPROM_DATA);
                end else begin
                    // FFh is the MUX_IN read address. Additional data bytes
                    // after it are not defined as a valid write operation.
                    clear_pending_write();
                    request_ack(1'b1, AFTER_ACK_IGNORE);
                end
            end
        end
    endtask

    task handle_eeprom_data_byte;
        input [7:0] value;
        begin
            if (wp || (pending_write_count >= 3'd4)) begin
                pending_write_overflow = (pending_write_count >= 3'd4);
                request_ack(1'b0, AFTER_ACK_IGNORE);
            end else begin
                store_pending_write_byte(value[5:0]);
                request_ack(1'b1, AFTER_ACK_EEPROM_DATA);
            end
        end
    endtask

    task handle_received_byte;
        input [7:0] value;
        begin
            case (byte_phase)
                BYTE_IS_ADDRESS:     handle_address_byte(value);
                BYTE_IS_CONTROL:     handle_control_byte(value);
                BYTE_IS_EEPROM_DATA: handle_eeprom_data_byte(value);
                default:             request_ack(1'b0, AFTER_ACK_IGNORE);
            endcase
        end
    endtask

    task advance_after_ack;
        begin
            sda_drive_low = 1'b0;

            case (after_ack_action)
                AFTER_ACK_CONTROL: begin
                    start_receiving(BYTE_IS_CONTROL);
                end

                AFTER_ACK_EEPROM_DATA: begin
                    start_receiving(BYTE_IS_EEPROM_DATA);
                end

                AFTER_ACK_TRANSMIT: begin
                    begin_transmit_byte(read_data_for_control(1'b0));
                end

                default: begin
                    i2c_state = I2C_IDLE;
                    byte_phase = BYTE_IS_ADDRESS;
                end
            endcase
        end
    endtask

    task prepare_next_read_byte_after_master_ack;
        begin
            if (master_ack_received) begin
                if (control_is_eeprom_address(control_register)) begin
                    read_eeprom_pointer = read_eeprom_pointer + 2'd1;
                end
                begin_transmit_byte(read_data_for_control(1'b0));
            end else begin
                sda_drive_low = 1'b0;
                i2c_state = I2C_IDLE;
                byte_phase = BYTE_IS_ADDRESS;
            end
        end
    endtask

    always @* begin
        if (!output_command_active) begin
            // PCA9561 function table when not overridden by I2C control:
            // MUX_SELECT=0 selects EEPROM byte 0. MUX_SELECT=1 selects MUX_IN.
            selected_mux_output_data = mux_select ? mux_input_data
                                                  : eeprom_register_value(2'd0);
        end else begin
            case (output_command[1:0])
                2'b00: selected_mux_output_data =
                    eeprom_register_value(output_command[3:2]);

                2'b01: selected_mux_output_data =
                    mux_select ? mux_input_data
                               : eeprom_register_value(output_command[3:2]);

                2'b10: selected_mux_output_data = mux_input_data;

                default: selected_mux_output_data = eeprom_register_value(2'd0);
            endcase
        end
    end

    initial begin
        sda_drive_low = 1'b0;
        previous_scl = 1'b1;
        previous_sda = 1'b1;
        i2c_state = I2C_IDLE;
        byte_phase = BYTE_IS_ADDRESS;
        after_ack_action = AFTER_ACK_IDLE;
        ack_to_send = 1'b0;
        received_byte = 8'h00;
        transmit_byte = 8'h00;
        bit_index = 3'd7;
        control_register = 8'h00;
        read_eeprom_pointer = 2'd0;
        master_ack_received = 1'b0;
        output_command_active = 1'b0;
        output_command = 8'h00;
        commit_eeprom_write = 1'b0;
        pending_write_start_address = 2'd0;
        clear_pending_write();
    end

    always @(scl or sda) begin
        scl_rising = (previous_scl == 1'b0) && (scl == 1'b1);
        scl_falling = (previous_scl == 1'b1) && (scl == 1'b0);
        start_condition = (previous_sda == 1'b1) && (sda == 1'b0) && (scl == 1'b1);
        stop_condition = (previous_sda == 1'b0) && (sda == 1'b1) && (scl == 1'b1);

        if (start_condition) begin
            sda_drive_low = 1'b0;
            clear_pending_write();
            start_receiving(BYTE_IS_ADDRESS);
        end else if (stop_condition) begin
            finish_transaction_on_stop();
        end else if (scl_rising) begin
            case (i2c_state)
                I2C_RECEIVE_BYTE: begin
                    next_received_byte = received_byte;
                    next_received_byte[bit_index] = sda;
                    received_byte = next_received_byte;

                    if (bit_index == 3'd0) begin
                        handle_received_byte(next_received_byte);
                    end else begin
                        bit_index = bit_index - 3'd1;
                    end
                end

                I2C_RECEIVE_MASTER_ACK: begin
                    master_ack_received = (sda == 1'b0);
                    i2c_state = I2C_MASTER_ACK_DONE;
                end

                default: begin
                    // Other states do not sample data on SCL rising edges.
                end
            endcase
        end else if (scl_falling) begin
            case (i2c_state)
                I2C_ACK_SETUP: begin
                    sda_drive_low = ack_to_send;
                    i2c_state = I2C_ACK_HOLD;
                end

                I2C_ACK_HOLD: begin
                    advance_after_ack();
                end

                I2C_TRANSMIT_BYTE: begin
                    if (bit_index == 3'd0) begin
                        sda_drive_low = 1'b0;
                        i2c_state = I2C_RECEIVE_MASTER_ACK;
                    end else begin
                        bit_index = bit_index - 3'd1;
                        sda_drive_low = (transmit_byte[bit_index] == 1'b0);
                    end
                end

                I2C_MASTER_ACK_DONE: begin
                    prepare_next_read_byte_after_master_ack();
                end

                default: begin
                    // No falling-edge action required.
                end
            endcase
        end

        previous_scl = scl;
        previous_sda = sda;
    end

endmodule
