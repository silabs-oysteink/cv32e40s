// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

////////////////////////////////////////////////////////////////////////////////
// Engineer:       Renzo Andri - andrire@student.ethz.ch                      //
//                                                                            //
// Additional contributions by:                                               //
//                 Igor Loi - igor.loi@unibo.it                               //
//                 Andreas Traber - atraber@student.ethz.ch                   //
//                 Sven Stucki - svstucki@student.ethz.ch                     //
//                 Michael Platzer - michael.platzer@tuwien.ac.at             //
//                                                                            //
// Design Name:    Instruction Fetch Stage                                    //
// Project Name:   RI5CY                                                      //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Instruction fetch unit: Selection of the next PC, and      //
//                 buffering (sampling) of the read instruction               //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

module cv32e40x_if_stage import cv32e40x_pkg::*;
#(
  parameter bit          A_EXT           = 0,
  parameter b_ext_e      B_EXT           = B_NONE,
  parameter bit          X_EXT           = 0,
  parameter int          X_ID_WIDTH      = 4,
  parameter int          PMA_NUM_REGIONS = 0,
  parameter pma_cfg_t    PMA_CFG[PMA_NUM_REGIONS-1:0] = '{default:PMA_R_DEFAULT},
  parameter int unsigned MTVT_ADDR_WIDTH = 26,
  parameter bit          SMCLIC          = 1'b0,
  parameter int          SMCLIC_ID_WIDTH = 5,
  parameter bit          ZC_EXT          = 0,
  parameter m_ext_e      M_EXT           = M_NONE
)
(
  input  logic          clk,
  input  logic          rst_n,

  // Target addresses
  input  logic [31:0]   boot_addr_i,            // Boot address
  input  logic [31:0]   branch_target_ex_i,     // Branch target address
  input  logic [31:0]   dm_exception_addr_i,    // Debug mode exception address
  input  logic [31:0]   dm_halt_addr_i,         // Debug mode halt address
  input  logic [31:0]   dpc_i,                  // Debug PC (restore upon return from debug)
  input  logic [31:0]   jump_target_id_i,       // Jump target address
  input  logic [31:0]   mepc_i,                 // Exception PC (restore upon return from exception/interrupt)
  input  logic [24:0]   mtvec_addr_i,           // Exception/interrupt address (MSBs)

  input  logic [MTVT_ADDR_WIDTH-1:0]   mtvt_addr_i,            // Base address for CLIC vectoring

  input  logic [JVT_ADDR_WIDTH-1:0]    jvt_addr_i,

  input ctrl_fsm_t      ctrl_fsm_i,
  input  logic          trigger_match_i,

  // Instruction bus interface
  if_c_obi.master       m_c_obi_instr_if,

  output if_id_pipe_t   if_id_pipe_o,           // IF/ID pipeline stage
  output logic [31:0]   pc_if_o,                // Program counter
  output logic          csr_mtvec_init_o,       // Tell CS regfile to init mtvec
  output logic          if_busy_o,              // Is the IF stage busy fetching instructions?
  output logic          ptr_in_if_o,            // The IF stage currently holds a pointer

  output logic          first_op_o,
  output logic          last_op_o,

  // Stage ready/valid
  output logic          if_valid_o,
  input  logic          id_ready_i,

  // eXtension interface
  if_xif.cpu_compressed xif_compressed_if,      // XIF compressed interface
  input  logic          xif_offloading_id_i     // ID stage attempts to offload an instruction
);

  logic              if_ready;

  // prefetch buffer related signals
  logic              prefetch_busy;

  logic       [31:0] branch_addr_n;

  logic              prefetch_valid;
  logic              prefetch_ready;
  inst_resp_t        prefetch_instr;
  logic              prefetch_is_clic_ptr;
  logic              prefetch_is_tbljmp_ptr;
  logic              prefetch_is_ptr_target;

  // flag for predecoded cm.jt / cm.jalt.
  // Maps to custom use of JAL instruction
  logic              tbljmp_raw; // Raw table jump from compressed decoder
  logic              tbljmp;     // Table jump which may deassert due to exceptions

  logic              illegal_c_insn;

  inst_resp_t        instr_decompressed;
  logic              instr_compressed;

  // Transaction signals to/from obi interface
  logic              prefetch_resp_valid;
  logic              prefetch_trans_valid;
  logic              prefetch_trans_ready;
  logic [31:0]       prefetch_trans_addr;
  inst_resp_t        prefetch_inst_resp;
  logic              prefetch_one_txn_pend_n;

  logic              bus_resp_valid;
  obi_inst_resp_t    bus_resp;
  logic              bus_trans_valid;
  logic              bus_trans_ready;
  obi_inst_req_t     bus_trans;
  obi_inst_req_t     core_trans;

  // Local instr_valid
  logic              instr_valid;

  // eXtension interface signals
  logic [X_ID_WIDTH-1:0] xif_id;

  // ready signal for predecoder, tied to id_ready_i
  logic              predec_ready;

  // Zc* sequencer signals
  logic              seq_valid;       // sequencer has valid output
  logic              seq_ready;       // sequencer is ready for new inputs
  logic              seq_instr_valid; // Sequencer has valid inputs
  logic              seq_first;       // sequencer is outputting the first operation
  logic              seq_last;        // sequencer is outputting the last operation
  inst_resp_t        seq_instr;       // Instruction for sequenced operation

  // Fetch address selection
  always_comb
  begin
    // Default assign PC_BOOT (should be overwritten in below case)
    branch_addr_n = {boot_addr_i[31:2], 2'b0};

    unique case (ctrl_fsm_i.pc_mux)
      PC_BOOT:       branch_addr_n = {boot_addr_i[31:2], 2'b0};
      PC_JUMP:       branch_addr_n = jump_target_id_i;
      PC_BRANCH:     branch_addr_n = branch_target_ex_i;
      PC_MRET:       branch_addr_n = mepc_i;                                                      // PC is restored when returning from IRQ/exception
      PC_DRET:       branch_addr_n = dpc_i;
      PC_WB_PLUS4:   branch_addr_n = ctrl_fsm_i.pipe_pc;                                          // Jump to next instruction forces prefetch buffer reload
      PC_TRAP_EXC:   branch_addr_n = {mtvec_addr_i, 7'h0};                                        // All the exceptions go to base address
      PC_TRAP_IRQ:   branch_addr_n = {mtvec_addr_i, ctrl_fsm_i.mtvec_pc_mux, 2'b00};     // interrupts are vectored
      PC_TRAP_DBD:   branch_addr_n = {dm_halt_addr_i[31:2], 2'b0};
      PC_TRAP_DBE:   branch_addr_n = {dm_exception_addr_i[31:2], 2'b0};
      PC_TRAP_NMI:   branch_addr_n = {mtvec_addr_i, NMI_MTVEC_INDEX, 2'b00};
      PC_TRAP_CLICV: branch_addr_n = {mtvt_addr_i, ctrl_fsm_i.mtvt_pc_mux[SMCLIC_ID_WIDTH-1:0], 2'b00};
      // CLIC and Zc* spec requires to clear bit 0. This clearing is done in the alignment buffer.
      PC_POINTER :   branch_addr_n = if_id_pipe_o.ptr;
      // JVT + (index << 2)
      PC_TBLJUMP :   branch_addr_n = {jvt_addr_i, ctrl_fsm_i.jvt_pc_mux[7:0], 2'b00};

      default:;
    endcase
  end

  // tell CS register file to initialize mtvec on boot
  assign csr_mtvec_init_o = (ctrl_fsm_i.pc_mux == PC_BOOT) & ctrl_fsm_i.pc_set;

  // prefetch buffer, caches a fixed number of instructions
  cv32e40x_prefetch_unit
  #(
      .SMCLIC (SMCLIC)
  )
  prefetch_unit_i
  (
    .clk                      ( clk                         ),
    .rst_n                    ( rst_n                       ),

    .ctrl_fsm_i               ( ctrl_fsm_i                  ),

    .branch_addr_i            ( {branch_addr_n[31:1], 1'b0} ),

    .prefetch_ready_i         ( prefetch_ready              ),
    .prefetch_valid_o         ( prefetch_valid              ),
    .prefetch_instr_o         ( prefetch_instr              ),
    .prefetch_addr_o          ( pc_if_o                     ),
    .prefetch_is_clic_ptr_o   ( prefetch_is_clic_ptr        ),
    .prefetch_is_tbljmp_ptr_o ( prefetch_is_tbljmp_ptr      ),
    .instr_is_ptr_target_o    ( prefetch_is_ptr_target      ),

    .trans_valid_o            ( prefetch_trans_valid        ),
    .trans_ready_i            ( prefetch_trans_ready        ),
    .trans_addr_o             ( prefetch_trans_addr         ),

    .resp_valid_i             ( prefetch_resp_valid         ),
    .resp_i                   ( prefetch_inst_resp          ),

    // Prefetch Buffer Status
    .prefetch_busy_o          ( prefetch_busy               ),
    .one_txn_pend_n           ( prefetch_one_txn_pend_n     )
  );

  //////////////////////////////////////////////////////////////////////////////
  // MPU
  //////////////////////////////////////////////////////////////////////////////

  assign core_trans.addr      = prefetch_trans_addr;
  assign core_trans.dbg       = ctrl_fsm_i.debug_mode_if;
  assign core_trans.prot[0]   = 1'b0;  // Transfers from IF stage all instruction fetches
  assign core_trans.prot[2:1] = PRIV_LVL_M;                // Machine mode
  assign core_trans.memtype   = 2'b00;                       // memtype is assigned in the MPU, tie off.

  cv32e40x_mpu
  #(
    .IF_STAGE             ( 1                           ),
    .A_EXT                ( A_EXT                       ),
    .CORE_REQ_TYPE        ( obi_inst_req_t              ),
    .CORE_RESP_TYPE       ( inst_resp_t                 ),
    .BUS_RESP_TYPE        ( obi_inst_resp_t             ),
    .PMA_NUM_REGIONS      ( PMA_NUM_REGIONS             ),
    .PMA_CFG              ( PMA_CFG                     )
  )
  mpu_i
  (
    .clk                  ( clk                         ),
    .rst_n                ( rst_n                       ),
    .atomic_access_i      ( 1'b0                        ), // No atomic transfers on instruction side
    .misaligned_access_i  ( 1'b0                        ), // MPU on instruction side will not issue misaligned access fault
                                                           // Misaligned access to main is allowed, and accesses outside main will
                                                           // result in instruction access fault (which will have priority over
                                                           //  misaligned from I/O fault)
    .core_if_data_access_i( 1'b0                        ), // No data access possible from IF
    .core_one_txn_pend_n  ( prefetch_one_txn_pend_n     ),
    .core_mpu_err_wait_i  ( 1'b1                        ),
    .core_mpu_err_o       (                             ), // Unconnected on purpose
    .core_trans_valid_i   ( prefetch_trans_valid        ),
    .core_trans_ready_o   ( prefetch_trans_ready        ),
    .core_trans_i         ( core_trans                  ),
    .core_resp_valid_o    ( prefetch_resp_valid         ),
    .core_resp_o          ( prefetch_inst_resp          ),

    .bus_trans_valid_o    ( bus_trans_valid             ),
    .bus_trans_ready_i    ( bus_trans_ready             ),
    .bus_trans_o          ( bus_trans                   ),
    .bus_resp_valid_i     ( bus_resp_valid              ),
    .bus_resp_i           ( bus_resp                    )
  );

  //////////////////////////////////////////////////////////////////////////////
  // OBI interface
  //////////////////////////////////////////////////////////////////////////////

  cv32e40x_instr_obi_interface
  instruction_obi_i
  (
    .clk                  ( clk              ),
    .rst_n                ( rst_n            ),

    .trans_valid_i        ( bus_trans_valid  ),
    .trans_ready_o        ( bus_trans_ready  ),
    .trans_i              ( bus_trans        ),

    .resp_valid_o         ( bus_resp_valid   ),
    .resp_o               ( bus_resp         ),
    .m_c_obi_instr_if     ( m_c_obi_instr_if )
  );

  // Local instr_valid when we have valid output from prefetcher
  // and IF stage is not halted or killed
  assign instr_valid = prefetch_valid && !ctrl_fsm_i.kill_if && !ctrl_fsm_i.halt_if;

  // if_stage ready when killed, otherwise when not halted and the sequencer and predecoder are both ready
  assign if_ready = ctrl_fsm_i.kill_if || (seq_ready && predec_ready && !ctrl_fsm_i.halt_if);


  // if stage valid when local instr_valid=1
  // Ideally this should be the following:
  //
  // assign if_valid_o = (seq_en    && seq_valid    ) ||
  //                     (predec_en && predec_valid ) && instr_valid;
  //
  // The predecoder is purely combinatorial module, and will produce a valid output for any valid input (instr_valid)
  // The Sequencer will output valid=1 for any instruction it can decode while not halted or killed
  //   when its valid_i (prefetch_valid) is high.

  assign if_valid_o = instr_valid;

  assign if_busy_o = prefetch_busy;

  assign ptr_in_if_o = prefetch_is_clic_ptr || prefetch_is_tbljmp_ptr;

  // Acknowledge prefetcher when IF stage is ready. This factors in seq_ready to avoid ack'ing the
  // prefetcher in the middle of a Zc sequence.
  // No need to ack the prefetcher when tbljmp==1, as this is will generate a pc_set and kill_if when
  // the table jump is taken in ID and the pointer fetch is initiated (or the table jump is killed).
  assign prefetch_ready = if_ready && !tbljmp;

  // Last operation of table jumps are set when the pointer is fed to ID stage
  // tbljmp (first operation) is set when a cm.jt or cm.jalt is decoded in the compressed decoder.
  // Trigger matches will get all write enables deasserted in ID, and debug entered before retiring
  // any operations once the first operation reaches WB. A trigger match is a last_op by definition.
  assign last_op_o = trigger_match_i        ? 1'b1 :
                     prefetch_is_ptr_target ? 1'b1 :
                     prefetch_is_clic_ptr   ? 1'b0 :
                     tbljmp                 ? 1'b0 :  // tbljmps are the first half
                     seq_valid              ? seq_last : 1'b1; // Any other regular instructions are single operation.

  // Flag first operation of a sequence.
  // Sequencer will set seq_first=1 when not in use - any other instruction handled by the compressed decoder (except table jumps)
  // will always have first_op=1 and may thus use seq_first.
  // Would ideally be something like "seq_valid ? : seq_first : 1'b1", but that causes combinatorial loops
  // through the controllers sequence_interruptible, via kill_ex and seq_valid and then into the first_op_o again.
  // Trigger matches will have all write enables deasserted in ID, and once the first operation reaches WB the debug entry will be made.
  // Marking as first (and last above) since we know it will not be a true sequence. Sequencer will keep sequencing, but will get killed
  // upon debug entry and no side effect will occur.
  assign first_op_o = prefetch_is_tbljmp_ptr ? 1'b0 :
                      prefetch_is_ptr_target ? 1'b0 :
                      prefetch_is_clic_ptr   ? 1'b1 :
                      trigger_match_i        ? 1'b1 : seq_first;



  // Populate instruction meta data
  // Fields 'compressed' and 'tbljmp' keep their old value by default.
  //   - In case of a table jump we need the fields to stay as 'compressed=1' and 'tbljmp=1'
  //     even when the pointer is sent to ID (operation 2/2)
  //   - For all cases except table jump pointer we update the values to the current values from predecoding.
  instr_meta_t instr_meta_n;
  always_comb begin
    instr_meta_n = '0;
    instr_meta_n.compressed    = if_id_pipe_o.instr_meta.compressed;
    instr_meta_n.clic_ptr      = prefetch_is_clic_ptr;
    instr_meta_n.tbljmp        = if_id_pipe_o.instr_meta.tbljmp;
  end

  // IF-ID pipeline registers, frozen when the ID stage is stalled
  // Todo: E40S: We will probably need to prevent dummy instructions between pointer fetcher and the pointer target fetch
  always_ff @(posedge clk, negedge rst_n)
  begin : IF_ID_PIPE_REGISTERS
    if (rst_n == 1'b0) begin
      if_id_pipe_o.instr_valid      <= 1'b0;
      if_id_pipe_o.instr            <= INST_RESP_RESET_VAL;
      if_id_pipe_o.instr_meta       <= '0;
      if_id_pipe_o.pc               <= '0;
      if_id_pipe_o.illegal_c_insn   <= 1'b0;
      if_id_pipe_o.compressed_instr <= '0;
      if_id_pipe_o.trigger_match    <= 1'b0;
      if_id_pipe_o.xif_id           <= '0;
      if_id_pipe_o.ptr              <= '0;
      if_id_pipe_o.last_op          <= 1'b0;
      if_id_pipe_o.first_op         <= 1'b0;
    end else begin
      // Valid pipeline output if we are valid AND the
      // alignment buffer has a valid instruction
      if (if_valid_o && id_ready_i) begin
        if_id_pipe_o.instr_valid      <= 1'b1;
        if_id_pipe_o.instr_meta       <= instr_meta_n;
        // seq_valid implies no illegal instruction, sequencer successfully decoded an instruction.
        // compressed decoder will still raise illegal_c_insn as it doesn't (currently) recognize Zc push/pop/dmove
        if_id_pipe_o.illegal_c_insn   <= seq_valid ? 1'b0 : illegal_c_insn;


        if_id_pipe_o.trigger_match    <= trigger_match_i;
        if_id_pipe_o.xif_id           <= xif_id;
        if_id_pipe_o.last_op          <= last_op_o;
        if_id_pipe_o.first_op         <= first_op_o;

        // No PC update for tablejump pointer, PC of instruction itself is needed later.
        // No update to the meta compressed, as this is used in calculating the link address.
        //   Any pointer could change instr_compressed and cause a wrong link address.
        // No update to tbljmp flag, we want flag to be high for both operations.
        if (!prefetch_is_tbljmp_ptr) begin
          if_id_pipe_o.pc                    <= pc_if_o;
          // todo: push/pop*/doublemoves are compressed, how (if at all) should we signal that when we emit uncompressed sequences?
          if_id_pipe_o.instr_meta.compressed <= instr_compressed;
          if_id_pipe_o.instr_meta.tbljmp     <= tbljmp;

          // Only update compressed_instr for compressed instructions
          if (instr_compressed) begin
            if_id_pipe_o.compressed_instr      <= prefetch_instr.bus_resp.rdata[15:0];
          end
        end

        // For pointers, we want to update the if_id_pipe.ptr field, but also any associated error conditions from bus or MPU.
        if (ptr_in_if_o) begin
          // Update pointer value
          if_id_pipe_o.ptr                <= instr_decompressed.bus_resp.rdata;

          // Need to update bus error status and mpu status, but may omit the 32-bit instruction word
          if_id_pipe_o.instr.bus_resp.err <= instr_decompressed.bus_resp.err;
          if_id_pipe_o.instr.mpu_status   <= instr_decompressed.mpu_status;
        end else begin
          // Regular instruction, update the whole instr field
          if_id_pipe_o.instr          <= seq_valid ? seq_instr : instr_decompressed;
        end
      end else if (id_ready_i) begin
        if_id_pipe_o.instr_valid      <= 1'b0;
      end
    end
  end

  cv32e40x_compressed_decoder
  #(
      .ZC_EXT ( ZC_EXT ),
      .B_EXT  ( B_EXT  ),
      .M_EXT  ( M_EXT  )
  )
  compressed_decoder_i
  (
    .instr_i            ( prefetch_instr          ),
    .instr_is_ptr_i     ( ptr_in_if_o             ),
    .instr_o            ( instr_decompressed      ),
    .is_compressed_o    ( instr_compressed        ),
    .illegal_instr_o    ( illegal_c_insn          ),
    .tbljmp_o           ( tbljmp_raw              )
  );

  // Setting predec_ready to id_ready_i here instead of passing it through the predecoder.
  // Predecoder is purely combinatorial and is always ready for new inputs
  assign predec_ready = id_ready_i;

  // Do not signal valid to the sequencer in case of a trigger match.
  // No need for the sequencer to start a sequence, the instruction will cause
  // debug entry on the first operation with no side effects done.
  assign seq_instr_valid = prefetch_valid && !trigger_match_i;

  generate
    if (ZC_EXT) begin : gen_seq
      cv32e40x_sequencer
      sequencer_i
      (
        .clk                ( clk                     ),
        .rst_n              ( rst_n                   ),

        .instr_i            ( prefetch_instr          ),
        .instr_is_ptr_i     ( ptr_in_if_o             ),

        .valid_i            ( seq_instr_valid         ),
        .ready_i            ( id_ready_i              ),
        .halt_i             ( ctrl_fsm_i.halt_if      ),
        .kill_i             ( ctrl_fsm_i.kill_if      ),


        .instr_o            ( seq_instr               ),
        .valid_o            ( seq_valid               ),
        .ready_o            ( seq_ready               ),
        .seq_first_o        ( seq_first               ),
        .seq_last_o         ( seq_last                )
      );
    end else begin : gen_no_seq
      assign seq_valid = 1'b0;
      assign seq_last  = 1'b0;
      assign seq_instr = '0;
      assign seq_ready = 1'b1;
      assign seq_first = 1'b1; // Tie high to enable default first_op when ZC_EXT=0
    end
  endgenerate


  // tbljmp below is used in calculating 'last_op_o'. If we have a faulted fetch, the instruction word may be anything
  // (not cleared on faulted fetches). A faulted fetch should not be decoded to anything and thus tbljmp is cleared.
  // One could instead set the instruction word itself to all zeros or another illegal instruction on known fetch faults,
  // but this may impact timing more than suppressing control bits.
  // Deassert also for trigger matches, as this will be a single operation and enter debug mode before executing. Similar to how
  // deassert_we is set in the ID stage for trigger matches.
  assign tbljmp = (instr_decompressed.bus_resp.err || (instr_decompressed.mpu_status != MPU_OK)) ? 1'b0 :
                  trigger_match_i ? 1'b0 : tbljmp_raw;

  //---------------------------------------------------------------------------
  // eXtension interface
  //---------------------------------------------------------------------------

  generate
    if (X_EXT) begin : x_ext

      // TODO: implement offloading of compressed instruction
      assign xif_compressed_if.compressed_valid = '0;
      assign xif_compressed_if.compressed_req   = '0;

      // TODO: assert that the oustanding IDs are unique
      assign xif_id = xif_offloading_id_i ? if_id_pipe_o.xif_id + 1 : if_id_pipe_o.xif_id;

    end else begin : no_x_ext

      assign xif_compressed_if.compressed_valid = '0;
      assign xif_compressed_if.compressed_req   = '0;

      assign xif_id                             = '0;

    end
  endgenerate

endmodule
