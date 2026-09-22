(set-logic QF_AUFBV)
; benchmark generated from python API
(set-info :status unknown)
(declare-fun balance_00 () (Array (_ BitVec 160) (_ BitVec 256)))
(declare-fun balance_319472a_01 () (Array (_ BitVec 160) (_ BitVec 256)))
(declare-fun p_pot_uint256_efa6d9c_00 () (_ BitVec 256))
(define-fun f_evm_bvudiv_256 ((x (_ BitVec 256)) (y (_ BitVec 256))) (_ BitVec 256) (ite (= y (_ bv0 256)) (_ bv0 256) (bvudiv x y)))
(define-fun f_evm_bvurem_256 ((x (_ BitVec 256)) (y (_ BitVec 256))) (_ BitVec 256) (ite (= y (_ bv0 256)) (_ bv0 256) (bvurem x y)))
(assert
 (= balance_319472a_01 (store balance_00 (_ bv728815563385977040452943777879061427756277306518 160) (_ bv79228162514264337593543950335 256))))
(assert
 (not (= p_pot_uint256_efa6d9c_00 (_ bv115792089237316195423570985008687907853269984665640564039457584007913129639935 256))))
(assert
 (let ((?x34 (f_evm_bvudiv_256 p_pot_uint256_efa6d9c_00 (_ bv10000 256))))
 (bvule ?x34 p_pot_uint256_efa6d9c_00)))
(assert
 (let (($x42 (bvule ((_ extract 13 0) (f_evm_bvurem_256 p_pot_uint256_efa6d9c_00 (_ bv10000 256))) (_ bv10000 14))))
 (let (($x39 (= ((_ extract 255 14) (f_evm_bvurem_256 p_pot_uint256_efa6d9c_00 (_ bv10000 256))) (_ bv0 242))))
 (and $x39 $x42))))
(assert
 (let ((?x36 (f_evm_bvurem_256 p_pot_uint256_efa6d9c_00 (_ bv10000 256))))
 (= ?x36 (_ bv0 256))))
(assert
 (not (= (f_evm_bvudiv_256 p_pot_uint256_efa6d9c_00 (_ bv10000 256)) (_ bv0 256))))
(assert
 (let ((?x49 (bvadd (_ bv1 256) p_pot_uint256_efa6d9c_00)))
 (bvule p_pot_uint256_efa6d9c_00 ?x49)))
(assert
 (let ((?x49 (bvadd (_ bv1 256) p_pot_uint256_efa6d9c_00)))
 (let ((?x51 (f_evm_bvudiv_256 ?x49 (_ bv10000 256))))
 (bvule ?x51 ?x49))))
(assert
 (let (($x57 (bvule ((_ extract 13 0) (f_evm_bvurem_256 (bvadd (_ bv1 256) p_pot_uint256_efa6d9c_00) (_ bv10000 256))) (_ bv10000 14))))
 (let (($x55 (= ((_ extract 255 14) (f_evm_bvurem_256 (bvadd (_ bv1 256) p_pot_uint256_efa6d9c_00) (_ bv10000 256))) (_ bv0 242))))
 (and $x55 $x57))))
(assert
 (not (= (f_evm_bvurem_256 (bvadd (_ bv1 256) p_pot_uint256_efa6d9c_00) (_ bv10000 256)) (_ bv0 256))))
(assert
 (not (= (f_evm_bvudiv_256 (bvadd (_ bv1 256) p_pot_uint256_efa6d9c_00) (_ bv10000 256)) (_ bv115792089237316195423570985008687907853269984665640564039457584007913129639935 256))))
(assert
 (let ((?x49 (bvadd (_ bv1 256) p_pot_uint256_efa6d9c_00)))
 (let ((?x51 (f_evm_bvudiv_256 ?x49 (_ bv10000 256))))
 (let ((?x63 (bvadd (_ bv1 256) ?x51)))
 (let ((?x34 (f_evm_bvudiv_256 p_pot_uint256_efa6d9c_00 (_ bv10000 256))))
 (bvule ?x34 ?x63))))))
(assert
 (let ((?x34 (f_evm_bvudiv_256 p_pot_uint256_efa6d9c_00 (_ bv10000 256))))
 (let ((?x65 (bvadd (_ bv1 256) ?x34)))
 (bvule ?x34 ?x65))))
(assert
 (let ((?x34 (f_evm_bvudiv_256 p_pot_uint256_efa6d9c_00 (_ bv10000 256))))
 (let ((?x65 (bvadd (_ bv1 256) ?x34)))
 (let ((?x49 (bvadd (_ bv1 256) p_pot_uint256_efa6d9c_00)))
 (let ((?x51 (f_evm_bvudiv_256 ?x49 (_ bv10000 256))))
 (let ((?x63 (bvadd (_ bv1 256) ?x51)))
 (not (bvule ?x63 ?x65))))))))


(check-sat)
(get-model)
