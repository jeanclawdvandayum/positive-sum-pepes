(set-logic QF_AUFBV)
; benchmark generated from python API
(set-info :status unknown)
(declare-fun balance_00 () (Array (_ BitVec 160) (_ BitVec 256)))
(declare-fun balance_ce13436_01 () (Array (_ BitVec 160) (_ BitVec 256)))
(declare-fun p_pot_uint256_e39ccfa_00 () (_ BitVec 256))
(define-fun f_evm_bvudiv_256 ((x (_ BitVec 256)) (y (_ BitVec 256))) (_ BitVec 256) (ite (= y (_ bv0 256)) (_ bv0 256) (bvudiv x y)))
(define-fun f_evm_bvurem_256 ((x (_ BitVec 256)) (y (_ BitVec 256))) (_ BitVec 256) (ite (= y (_ bv0 256)) (_ bv0 256) (bvurem x y)))
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
 (let ((?x33 (f_evm_bvurem_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))))
 (= ?x33 (_ bv0 256))))
(assert
 (not (= (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256)) (_ bv0 256))))
(assert
 (let ((?x31 (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))))
 (bvule (_ bv1 256) ?x31)))
(assert
 (let (($x52 (bvule ((_ extract 242 0) (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))) (_ bv11579208923731619542357098500868790785326998466564056403945758400791312964 243))))
 (let (($x49 (= ((_ extract 255 243) (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))) (_ bv0 13))))
 (and $x49 $x52))))
(assert
 (not (= p_pot_uint256_e39ccfa_00 (_ bv0 256))))
(assert
 (let ((?x31 (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))))
 (let ((?x57 (bvadd (_ bv115792089237316195423570985008687907853269984665640564039457584007913129639935 256) ?x31)))
 (bvule ?x57 ?x31))))
(assert
 (let ((?x61 (bvadd (_ bv115792089237316195423570985008687907853269984665640564039457584007913129629936 256) (bvmul (_ bv10000 256) (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))))))
 (let ((?x31 (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))))
 (let ((?x57 (bvadd (_ bv115792089237316195423570985008687907853269984665640564039457584007913129639935 256) ?x31)))
 (let ((?x62 (f_evm_bvudiv_256 ?x61 ?x57)))
 (bvule ?x62 ?x61))))))
(assert
 (let ((?x31 (f_evm_bvudiv_256 p_pot_uint256_e39ccfa_00 (_ bv10000 256))))
 (let ((?x57 (bvadd (_ bv115792089237316195423570985008687907853269984665640564039457584007913129639935 256) ?x31)))
 (let ((?x61 (bvadd (_ bv115792089237316195423570985008687907853269984665640564039457584007913129629936 256) (bvmul (_ bv10000 256) ?x31))))
 (let ((?x62 (f_evm_bvudiv_256 ?x61 ?x57)))
 (let (($x65 (= ?x62 (_ bv10000 256))))
 (let (($x64 (= ?x31 (_ bv1 256))))
 (not (or $x64 $x65)))))))))


(check-sat)
(get-model)
