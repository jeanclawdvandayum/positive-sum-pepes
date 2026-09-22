(set-logic QF_AUFBV)
; benchmark generated from python API
(set-info :status unknown)
(declare-fun balance_00 () (Array (_ BitVec 160) (_ BitVec 256)))
(declare-fun balance_ce13436_01 () (Array (_ BitVec 160) (_ BitVec 256)))
(declare-fun p_pot_uint256_e39ccfa_00 () (_ BitVec 256))
(declare-fun f_evm_bvudiv_256 ((_ BitVec 256) (_ BitVec 256)) (_ BitVec 256))
(declare-fun f_evm_bvurem_256 ((_ BitVec 256) (_ BitVec 256)) (_ BitVec 256))
(assert
 (= balance_ce13436_01 (store balance_00 (_ bv728815563385977040452943777879061427756277306518 160) (_ bv79228162514264337593543950335 256))))
(assert
 (let ((?x31 (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))))
 (bvule ?x31 p_pot_uint256_e39ccfa_00)))
(assert
 (let (($x39 (bvule ((_ extract 13 0) (f_evm_bvurem_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))) (_ bv10000 14))))
 (let (($x36 (= ((_ extract 255 14) (f_evm_bvurem_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))) (_ bv0 242))))
 (and $x36 $x39))))
(assert
 (not (= (f_evm_bvurem_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256)) (_ bv0 256))))
(assert
 (not (= (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256)) (_ bv115792089237316195423570985008687907853269984665640564039457584007913129639935 256))))
(assert
 (let ((?x31 (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))))
 (bvule ?x31 (_ bv115792089237316195423570985008687907853269984665640564039457584007913129639934 256))))
(assert
 (let (($x58 (bvule (bvadd (_ bv1 243) ((_ extract 242 0) (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256)))) (_ bv11579208923731619542357098500868790785326998466564056403945758400791312964 243))))
 (let (($x53 (= ((_ extract 255 243) (bvadd (_ bv1 256) (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256)))) (_ bv0 13))))
 (and $x53 $x58))))
(assert
 (not (= p_pot_uint256_e39ccfa_00 (_ bv0 256))))
(assert
 (let ((?x31 (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))))
 (let ((?x50 (bvadd (_ bv1 256) ?x31)))
 (bvule ?x31 ?x50))))
(assert
 (let ((?x31 (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))))
 (let ((?x63 (bvmul (_ bv10000 256) ?x31)))
 (let ((?x64 (f_evm_bvudiv_256 ?x63 ?x31)))
 (bvule ?x64 ?x63)))))
(assert
 (let ((?x31 (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))))
 (let ((?x63 (bvmul (_ bv10000 256) ?x31)))
 (let ((?x64 (f_evm_bvudiv_256 ?x63 ?x31)))
 (or (= ?x31 (_ bv0 256)) (= ?x64 (_ bv10000 256)))))))
(assert
 (let ((?x31 (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))))
 (let ((?x63 (bvmul (_ bv10000 256) ?x31)))
 (not (bvule p_pot_uint256_e39ccfa_00 ?x63)))))
(assert
 (let ((?x73 (bvadd p_pot_uint256_e39ccfa_00 (bvmul (_ bv115792089237316195423570985008687907853269984665640564039457584007913129629936 256) (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))))))
 (not (bvule ?x73 p_pot_uint256_e39ccfa_00))))


(check-sat)
(get-model)
