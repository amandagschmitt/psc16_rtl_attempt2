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

    localparam time I2C_HALF_PERIOD = 1250ns;       // 400 kHz max bus rate.
    localparam time EEPROM_WRITE_TIME = 3_600_000ns; // PCA9561 datasheet value.

    logic scl;
    tri1  sda;
    logic master_drive_sda_low;

    logic a0;
    logic a1;
    logic wp;
    logic mux_select;
    logic mux_in_a;
    logic mux_in_b;
    logic mux_in_c;
    logic mux_in_d;
    logic mux_in_e;
    logic mux_in_f;

    tri1 mux_out_a;
    tri1 mux_out_b;
    tri1 mux_out_c;
    tri1 mux_out_d;
    tri1 mux_out_e;
    tri1 mux_out_f;

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

    function automatic logic [7:0] i2c_address_byte(input logic read_transfer);
        i2c_address_byte = {5'b10011, a1, a0, read_transfer};
    endfunction

    function automatic logic [5:0] sampled_mux_out;
        sampled_mux_out = {
            mux_out_f,
            mux_out_e,
            mux_out_d,
            mux_out_c,
            mux_out_b,
            mux_out_a
        };
    endfunction

    task automatic fail(input string message);
        begin
            $error("%s at time %0t", message, $time);
            $fatal;
        end
    endtask

    task automatic expect_equal_byte(
        input string check_name,
        input logic [7:0] actual,
        input logic [7:0] expected
    );
        begin
            if (actual !== expected) begin
                $error("%s: actual=%02h expected=%02h", check_name, actual, expected);
                $fatal;
            end
        end
    endtask

    task automatic expect_equal_mux(
        input string check_name,
        input logic [5:0] expected
    );
        begin
            #10ns;
            if (sampled_mux_out() !== expected) begin
                $error("%s: mux_out=%06b expected=%06b",
                       check_name, sampled_mux_out(), expected);
                $fatal;
            end
        end
    endtask

    task automatic i2c_idle;
        begin
            master_drive_sda_low = 1'b0;
            scl = 1'b1;
            #(I2C_HALF_PERIOD);
        end
    endtask

    task automatic i2c_start;
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

    task automatic i2c_stop;
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

    task automatic i2c_write_bit(input logic bit_value);
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

    task automatic i2c_read_bit(output logic bit_value);
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

    task automatic i2c_write_byte(input logic [7:0] value, output logic ack_seen);
        begin
            for (int i = 7; i >= 0; i--) begin
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

    task automatic i2c_read_byte(input logic master_ack, output logic [7:0] value);
        logic sampled_bit;
        begin
            value = 8'h00;
            for (int i = 7; i >= 0; i--) begin
                i2c_read_bit(sampled_bit);
                value[i] = sampled_bit;
            end

            i2c_write_bit(master_ack ? 1'b0 : 1'b1);
            master_drive_sda_low = 1'b0;
        end
    endtask

    task automatic write_control_only(input logic [7:0] control, output logic control_ack);
        logic ack;
        begin
            i2c_start();
            i2c_write_byte(i2c_address_byte(1'b0), ack);
            if (!ack) fail("Expected address ACK before control write");
            i2c_write_byte(control, control_ack);
            i2c_stop();
        end
    endtask

    task automatic write_eeprom_one_byte(
        input logic [7:0] control,
        input logic [5:0] data,
        output logic address_ack,
        output logic control_ack,
        output logic data_ack
    );
        begin
            i2c_start();
            i2c_write_byte(i2c_address_byte(1'b0), address_ack);
            if (address_ack) begin
                i2c_write_byte(control, control_ack);
                i2c_write_byte({2'b00, data}, data_ack);
            end else begin
                control_ack = 1'b0;
                data_ack = 1'b0;
            end
            i2c_stop();
        end
    endtask

    task automatic read_register(
        input  logic [7:0] control,
        output logic [7:0] read_value
    );
        logic ack;
        begin
            i2c_start();
            i2c_write_byte(i2c_address_byte(1'b0), ack);
            if (!ack) fail("Expected address ACK before read control");
            i2c_write_byte(control, ack);
            if (!ack) fail("Expected control ACK before repeated START read");

            i2c_start();
            i2c_write_byte(i2c_address_byte(1'b1), ack);
            if (!ack) fail("Expected address ACK for read");
            i2c_read_byte(1'b0, read_value);
            i2c_stop();
        end
    endtask

    initial begin
        logic address_ack;
        logic control_ack;
        logic data_ack;
        logic [7:0] read_value;

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

        #(EEPROM_WRITE_TIME + 10_000ns);

        read_register(8'h00, read_value);
        expect_equal_byte("EEPROM byte 0 readback after write", read_value, 8'h15);
        expect_equal_mux("MUX_SELECT=0 uses updated EEPROM byte 0", 6'h15);

        write_eeprom_one_byte(8'h01, 6'h2A, address_ack, control_ack, data_ack);
        if (!address_ack || !control_ack || !data_ack) begin
            fail("Expected ACKs for WP=0 EEPROM byte 1 write");
        end

        #(EEPROM_WRITE_TIME + 10_000ns);

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
