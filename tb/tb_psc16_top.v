`timescale 1ns / 1ps

// Self-checking PSC0016/PCA9561 behavioral testbench.
//
// This testbench verifies only behavior stated in the supplied documents:
// - External MUX_SELECT selects EEPROM byte 0 or MUX_IN when no I2C output
//   command is active.
// - MUX_OUT pins behave as open-drain outputs.
// - PCA9561 I2C address is 10011 A1 A0 plus R/W.
// - Control byte FFh reads MUX_IN.
// - EEPROM byte 0 can be written when WP=0 and is busy/NACKed during the
//   EEPROM write cycle.
// - WP=1 prevents EEPROM data-byte writes.
// - Table 5 command F5 selects MUX_IN when MUX_SELECT=1 and EEPROM byte 1
//   when MUX_SELECT=0.
// - Reserved control bytes are NACKed.

module tb_psc16_top;

    localparam I2C_HALF_PERIOD = 1250;        // 400 kHz max bus rate.
    localparam EEPROM_WRITE_TIME = 3_600_000; // PCA9561 datasheet value.

    reg scl;
    tri1 sda;
    reg master_drive_sda_low;

    reg a0;
    reg a1;
    reg wp;
    reg mux_select;
    reg mux_in_a;
    reg mux_in_b;
    reg mux_in_c;
    reg mux_in_d;
    reg mux_in_e;
    reg mux_in_f;

    tri1 mux_out_a;
    tri1 mux_out_b;
    tri1 mux_out_c;
    tri1 mux_out_d;
    tri1 mux_out_e;
    tri1 mux_out_f;

    reg address_ack;
    reg control_ack;
    reg data_ack;
    reg [7:0] read_value;

    assign sda = master_drive_sda_low ? 1'b0 : 1'bz;

    psc16_top #(
        .EEPROM_WRITE_CYCLE_TIME(EEPROM_WRITE_TIME)
    ) dut (
        .scl(scl),
        .sda(sda),
        .a0(a0),
        .a1(a1),
        .wp(wp),
        .mux_select(mux_select),
        .mux_in_a(mux_in_a),
        .mux_in_b(mux_in_b),
        .mux_in_c(mux_in_c),
        .mux_in_d(mux_in_d),
        .mux_in_e(mux_in_e),
        .mux_in_f(mux_in_f),
        .mux_out_a(mux_out_a),
        .mux_out_b(mux_out_b),
        .mux_out_c(mux_out_c),
        .mux_out_d(mux_out_d),
        .mux_out_e(mux_out_e),
        .mux_out_f(mux_out_f)
    );

    function [7:0] i2c_address_byte;
        input read_transfer;
        begin
            i2c_address_byte = {5'b10011, a1, a0, read_transfer};
        end
    endfunction

    function [5:0] sampled_mux_out;
        input unused;
        begin
            sampled_mux_out = {
                mux_out_f,
                mux_out_e,
                mux_out_d,
                mux_out_c,
                mux_out_b,
                mux_out_a
            };
        end
    endfunction

    task fail;
        input [1023:0] message;
        begin
            $display("ERROR: %0s at time %0t", message, $time);
            $finish;
        end
    endtask

    task expect_equal_byte;
        input [1023:0] check_name;
        input [7:0] actual;
        input [7:0] expected;
        begin
            if (actual !== expected) begin
                $display("ERROR: %0s: actual=%02h expected=%02h",
                         check_name, actual, expected);
                $finish;
            end
        end
    endtask

    task expect_equal_mux;
        input [1023:0] check_name;
        input [5:0] expected;
        begin
            #10;
            if (sampled_mux_out(1'b0) !== expected) begin
                $display("ERROR: %0s: mux_out=%06b expected=%06b",
                         check_name, sampled_mux_out(1'b0), expected);
                $finish;
            end
        end
    endtask

    task i2c_idle;
        begin
            master_drive_sda_low = 1'b0;
            scl = 1'b1;
            #(I2C_HALF_PERIOD);
        end
    endtask

    task i2c_start;
        begin
            master_drive_sda_low = 1'b0;
            scl = 1'b1;
            #(I2C_HALF_PERIOD);
            master_drive_sda_low = 1'b1;
            #(I2C_HALF_PERIOD);
            scl = 1'b0;
            #(I2C_HALF_PERIOD);
        end
    endtask

    task i2c_stop;
        begin
            master_drive_sda_low = 1'b1;
            scl = 1'b0;
            #(I2C_HALF_PERIOD);
            scl = 1'b1;
            #(I2C_HALF_PERIOD);
            master_drive_sda_low = 1'b0;
            #(I2C_HALF_PERIOD);
        end
    endtask

    task i2c_write_bit;
        input bit_value;
        begin
            scl = 1'b0;
            master_drive_sda_low = (bit_value == 1'b0);
            #(I2C_HALF_PERIOD);
            scl = 1'b1;
            #(I2C_HALF_PERIOD);
            scl = 1'b0;
            #(I2C_HALF_PERIOD);
        end
    endtask

    task i2c_read_bit;
        output bit_value;
        begin
            scl = 1'b0;
            master_drive_sda_low = 1'b0;
            #(I2C_HALF_PERIOD);
            scl = 1'b1;
            #(I2C_HALF_PERIOD / 2);
            bit_value = sda;
            #(I2C_HALF_PERIOD / 2);
            scl = 1'b0;
            #(I2C_HALF_PERIOD);
        end
    endtask

    task i2c_write_byte;
        input [7:0] value;
        output ack_seen;
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                i2c_write_bit(value[i]);
            end

            scl = 1'b0;
            master_drive_sda_low = 1'b0;
            #(I2C_HALF_PERIOD);
            scl = 1'b1;
            #(I2C_HALF_PERIOD / 2);
            ack_seen = (sda == 1'b0);
            #(I2C_HALF_PERIOD / 2);
            scl = 1'b0;
            #(I2C_HALF_PERIOD);
        end
    endtask

    task i2c_read_byte;
        input master_ack;
        output [7:0] value;
        reg sampled_bit;
        integer i;
        begin
            value = 8'h00;
            for (i = 7; i >= 0; i = i - 1) begin
                i2c_read_bit(sampled_bit);
                value[i] = sampled_bit;
            end

            i2c_write_bit(master_ack ? 1'b0 : 1'b1);
            master_drive_sda_low = 1'b0;
        end
    endtask

    task write_control_only;
        input [7:0] control;
        output control_ack;
        reg ack;
        begin
            i2c_start();
            i2c_write_byte(i2c_address_byte(1'b0), ack);
            if (!ack) fail("Expected address ACK before control write");
            i2c_write_byte(control, control_ack);
            i2c_stop();
        end
    endtask

    task write_eeprom_one_byte;
        input [7:0] control;
        input [5:0] data;
        output address_ack_out;
        output control_ack_out;
        output data_ack_out;
        begin
            i2c_start();
            i2c_write_byte(i2c_address_byte(1'b0), address_ack_out);
            if (address_ack_out) begin
                i2c_write_byte(control, control_ack_out);
                i2c_write_byte({2'b00, data}, data_ack_out);
            end else begin
                control_ack_out = 1'b0;
                data_ack_out = 1'b0;
            end
            i2c_stop();
        end
    endtask

    task read_register;
        input [7:0] control;
        output [7:0] read_value_out;
        reg ack;
        begin
            i2c_start();
            i2c_write_byte(i2c_address_byte(1'b0), ack);
            if (!ack) fail("Expected address ACK before read control");
            i2c_write_byte(control, ack);
            if (!ack) fail("Expected control ACK before repeated START read");

            i2c_start();
            i2c_write_byte(i2c_address_byte(1'b1), ack);
            if (!ack) fail("Expected address ACK for read");
            i2c_read_byte(1'b0, read_value_out);
            i2c_stop();
        end
    endtask

    initial begin
        scl = 1'b1;
        master_drive_sda_low = 1'b0;
        a0 = 1'b0;
        a1 = 1'b0;
        wp = 1'b0;
        mux_select = 1'b0;
        {mux_in_f, mux_in_e, mux_in_d, mux_in_c, mux_in_b, mux_in_a} = 6'b101010;

        i2c_idle();

        expect_equal_mux("Factory-default EEPROM byte 0 drives MUX_OUT low", 6'b000000);

        mux_select = 1'b1;
        expect_equal_mux("MUX_SELECT=1 selects MUX_IN when no I2C override exists", 6'b101010);

        read_register(8'hFF, read_value);
        expect_equal_byte("FFh reads MUX_IN with two MSBs padded low", read_value, 8'h2A);

        mux_select = 1'b0;
        write_eeprom_one_byte(8'h00, 6'h15, address_ack, control_ack, data_ack);
        if (!address_ack || !control_ack || !data_ack) begin
            fail("Expected ACKs for WP=0 EEPROM byte 0 write");
        end

        i2c_start();
        i2c_write_byte(i2c_address_byte(1'b0), address_ack);
        if (address_ack) begin
            fail("Device ACKed address during documented EEPROM write-busy interval");
        end
        i2c_stop();

        #(EEPROM_WRITE_TIME + 10000);

        read_register(8'h00, read_value);
        expect_equal_byte("EEPROM byte 0 readback after write", read_value, 8'h15);
        expect_equal_mux("MUX_SELECT=0 uses updated EEPROM byte 0", 6'h15);

        write_eeprom_one_byte(8'h01, 6'h2A, address_ack, control_ack, data_ack);
        if (!address_ack || !control_ack || !data_ack) begin
            fail("Expected ACKs for WP=0 EEPROM byte 1 write");
        end

        #(EEPROM_WRITE_TIME + 10000);

        write_control_only(8'hF5, control_ack);
        if (!control_ack) begin
            fail("Expected F5h output command ACK");
        end

        mux_select = 1'b0;
        expect_equal_mux("F5h with MUX_SELECT=0 selects EEPROM byte 1", 6'h2A);

        {mux_in_f, mux_in_e, mux_in_d, mux_in_c, mux_in_b, mux_in_a} = 6'b001111;
        mux_select = 1'b1;
        expect_equal_mux("F5h with MUX_SELECT=1 selects MUX_IN", 6'b001111);

        write_control_only(8'h04, control_ack);
        if (control_ack) begin
            fail("Reserved control byte 04h was ACKed");
        end

        wp = 1'b1;
        write_eeprom_one_byte(8'h00, 6'h3F, address_ack, control_ack, data_ack);
        if (!address_ack || !control_ack) begin
            fail("WP=1 should still ACK address and EEPROM command");
        end
        if (data_ack) begin
            fail("WP=1 should NACK EEPROM data byte");
        end

        wp = 1'b0;
        read_register(8'h00, read_value);
        expect_equal_byte("WP=1 blocked EEPROM byte 0 update", read_value, 8'h15);

        $display("PSC0016/PCA9561 documented-behavior testbench passed.");
        $finish;
    end

endmodule
