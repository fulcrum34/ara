// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Matteo Perotti <mperotti@iis.ee.ethz.ch>
// Description: break down segmented memory operations into scalar
// memory operations. This is extremely bad in terms of IPC, but
// it has low-impact on the physical implementation.

module segment_sequencer import ara_pkg::*; import rvv_pkg::*; #(
    parameter bit SegSupport = 1'b0
  ) (
    // Clock and reset
    input  logic      clk_i,
    input  logic      rst_ni,
    input  logic      ara_idle_i,
    // Enable the segment sequencer?
    input  logic      is_segment_mem_op_i,
    input  logic      illegal_insn_i,
    input  logic      is_vload_i,
    output logic      segment_micro_op_on_o,
    input  logic      load_complete_i,
    output logic      load_complete_o,
    input  logic      store_complete_i,
    output logic      store_complete_o,
    // Ara frontend - backend info and handshakes
    input  ara_req_t  ara_req_i,
    output ara_req_t  ara_req_o,
    input  logic      ara_req_ready_i,
    input  ara_resp_t ara_resp_i,
    output ara_resp_t ara_resp_o,
    input  logic      ara_resp_valid_i,
    output logic      ara_resp_valid_o
  );

  import cf_math_pkg::idx_width;

  logic ara_resp_valid_d, ara_resp_valid_q;
  ara_resp_t ara_resp_d, ara_resp_q;
  logic is_vload_d, is_vload_q;
  logic [$bits(ara_req_i.vstart):0] next_vstart_cnt;

  typedef enum logic [1:0] {
    IDLE,
    SEGMENT_MICRO_OPS,
    SEGMENT_MICRO_OPS_END
  } state_e;
  state_e state_d, state_q;

  // Track the elements within each segment
  logic new_seg_mem_op;
  logic segment_cnt_en, segment_cnt_clear;
  logic [$bits(ara_req_i.nf)-1:0] segment_cnt_q;

  counter #(
    .WIDTH($bits(ara_req_i.nf)),
    .STICKY_OVERFLOW(1'b0)
  ) i_segment_cnt (
    .clk_i,
    .rst_ni,
    .clear_i(segment_cnt_clear),
    .en_i(segment_cnt_en),
    .load_i(1'b0),
    .down_i(1'b0),
    .d_i('0),
    .q_o(segment_cnt_q),
    .overflow_o( /* Unused */ )
  );
  assign segment_cnt_clear = new_seg_mem_op | (segment_cnt_en & (segment_cnt_q == ara_req_i.nf));

  // Track the number of segments
  logic vstart_cnt_en;
  logic [$bits(ara_req_i.vstart)-1:0] vstart_cnt_q;

  counter #(
    .WIDTH($bits(ara_req_i.vstart)),
    .STICKY_OVERFLOW(1'b0)
  ) i_vstart_cnt (
    .clk_i,
    .rst_ni,
    .clear_i( /* Unused */ ),
    .en_i(vstart_cnt_en),
    .load_i(new_seg_mem_op),
    .down_i(1'b0),
    .d_i(ara_req_i.vstart),
    .q_o(vstart_cnt_q),
    .overflow_o( /* Unused */ )
  );
  // Change destination vector index when all the fields of the segment have been processed
  assign vstart_cnt_en = segment_cnt_en & (segment_cnt_q == ara_req_i.nf);

  // Next vstart count
  assign next_vstart_cnt = vstart_cnt_q + 1;

  // Signal if the micro op seq is on
  assign segment_micro_op_on_o = state_q != IDLE;

  always_comb begin
    state_d = state_q;

    // Pass through
    ara_req_o        = ara_req_i;
    ara_resp_o       = ara_resp_i;
    ara_resp_valid_o = ara_resp_valid_i;
    // Block load/store_complete
    load_complete_o  = 1'b0;
    store_complete_o = 1'b0;

    ara_resp_d       = ara_resp_q;
    ara_resp_valid_d = ara_resp_valid_q;
    is_vload_d       = is_vload_q;

    // Don't count up by default
    new_seg_mem_op = 1'b0;
    segment_cnt_en = 1'b0;

    // Low-perf Moore's FSM
    unique case (state_q)
      IDLE: begin
        // Send a first micro operation upon valid segment mem op
		if (is_segment_mem_op_i && !illegal_insn_i) begin
          // If we are here, the backend is able to accept the request
          // Set-up sequencing
          new_seg_mem_op = 1'b1;
          // Set up the first micro operation
          ara_req_o.vl = 1;
          // Start sequencing
          state_d = SEGMENT_MICRO_OPS;
        end
      end
      SEGMENT_MICRO_OPS: begin
        // Manipulate the memory micro request in advance
        ara_req_o.vl     = 1;
        ara_req_o.vstart = vstart_cnt_q;
        ara_req_o.vs1    = ara_req_i.vs1 + segment_cnt_q;
        ara_req_o.vd     = ara_req_i.vd  + segment_cnt_q;
        ara_resp_valid_o = 1'b0;

        // Wait for an answer from Ara's backend
        if (ara_resp_valid_i) begin
          // Pass to the next field if the previous micro op finished
          segment_cnt_en = 1'b1;
          // If exception, stop the execution
          if (ara_resp_i.error) begin
            ara_resp_valid_o = ara_resp_valid_i;
          // If no exception, continue with the micro ops
          end else begin
            // If over - stop in the next cycle
            if (segment_cnt_clear && (next_vstart_cnt == ara_req_i.vl)) begin
              // Sample the last answer
              ara_resp_d       = ara_resp_i;
              ara_resp_valid_d = ara_resp_valid_i;
              is_vload_d       = is_vload_i;
              state_d = SEGMENT_MICRO_OPS_END;
            end
          end
        end
      end
      SEGMENT_MICRO_OPS_END: begin
        ara_resp_valid_o = 1'b0;
        // Wait for idle to give the final load/store_complete
        if (ara_idle_i) begin
          ara_resp_o       = ara_resp_q;
          ara_resp_valid_o = ara_resp_valid_q;
          load_complete_o  = is_vload_q;
          store_complete_o = ~is_vload_q;
          state_d = IDLE;
        end
      end
      default:;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q          <= IDLE;
      is_vload_q       <= 1'b0;
      ara_resp_q       <= '0;
      ara_resp_valid_q <= '0;
    end else begin
      state_q          <= state_d;
      is_vload_q       <= is_vload_d;
      ara_resp_q       <= ara_resp_d;
      ara_resp_valid_q <= ara_resp_valid_d;
    end
  end

endmodule
