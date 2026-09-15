// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {SineV3Math} from "../src/SineV3Math.sol";
import {SineV3TestData as SineV3Data} from "./helpers/SineV3TestData.sol";
import {SineV3DataInfo} from "../src/SineV3DataInfo.sol";
import {FixedPointMathLib as FPML} from "solady/src/utils/FixedPointMathLib.sol";
/// @notice Expose the primitive for independent endpoint checks.
contract SineV3IndependentHarness is SineV3Math {
    constructor(address[4] memory data) SineV3Math(data) {}
    function rawF(uint256 R,uint256 boot,uint256 lam) external view returns(int256) { return _fAtReserve(R,boot,lam); }
    function inverse(uint256 R,uint256 boot,uint256 lam,uint256 pL,uint256 q) external view returns(uint256) { return _reserveAtPrimitive(R,boot,lam,pL,q,_fAtReserve(0,boot,lam)); }
    function phase4(uint256 i) external pure returns(int256) { return _phase4(i); }
    function prepare(uint256 i) external view returns(uint256[18] memory controls) { return _prepare(i).controls; }
}
/// @notice Check every cell and physical knot boundary, plus inverse minimality
/// against fresh cumulative evaluations rather than the cached inverse cell.
contract SineV3IndependentTest is Test {
    SineV3IndependentHarness h;
    function setUp() public {
        assertEq(SineV3DataInfo.COUNT, 4938, "update exhaustive batches when the generated grid changes");
        h=new SineV3IndependentHarness(SineV3Data.deploy());
    }
    function test_OneSidedPhysicalDomainEndpoints() public view {
        uint256 boot=680000000e18; uint256 lam=h.lamAt(boot); uint256 pL=1e18;
        uint256 end=h.maxReserve(boot,lam,pL);
        assertEq(h.supplyWad(0,boot,lam,pL),0);
        assertGt(h.supplyWad(1,boot,lam,pL),0);
        assertLe(h.supplyWad(end-1,boot,lam,pL),h.supplyWad(end,boot,lam,pL));
    }
    function _ordered(uint256 start,uint256 end) internal view {
        for(uint256 i=start;i<end;++i) {
            uint256[18] memory c=h.prepare(i);
            for(uint256 j;j<17;++j) assertLe(c[j],c[j+1]);
        }
    }
    function _boundary(uint256 start,uint256 end) internal view {
        uint256 boot=680000000e18; uint256 lam=h.lamAt(boot); uint256 pL=1e18;
        assertGt(h.priceWad(0,boot,lam,pL),0);
        for(uint256 i=start;i<end;++i) {
            int256 phase=h.phase4(i);
            uint256 R;
            if(phase<0) {uint256 back=FPML.fullMulDiv(uint256(-phase),lam,4);if(back>=boot)continue; R=boot-back;}
            else R=boot+FPML.fullMulDiv(uint256(phase),lam,4);
            if(R==0 || R+1>boot+4096*lam)continue;
            uint256 a=h.supplyWad(R-1,boot,lam,pL);uint256 b=h.supplyWad(R,boot,lam,pL);uint256 c=h.supplyWad(R+1,boot,lam,pL);
            assertLe(a,b); assertLe(b,c);
        }
    }
    function testFuzz_AdjacentSupplies(uint256 raw,uint8 size) public view {
        uint256[5] memory boots=[uint256(1),1e12,450e18,100000e18,680000000e18];
        uint256 boot=boots[size%5];uint256 lam=h.lamAt(boot);uint256 pL=size%5==4?1e18:75e12;
        uint256 R=raw%(boot+4096*lam);
        assertLe(h.supplyWad(R,boot,lam,pL),h.supplyWad(R+1,boot,lam,pL));
    }
    function testFuzz_InverseReturnsEarliestFeasibleReserve(uint256 raw,uint256 portion,uint8 size) public view {
        uint256[5] memory boots=[uint256(1),1e12,450e18,100000e18,680000000e18];
        uint256 boot=boots[size%5];uint256 lam=h.lamAt(boot);uint256 pL=size%5==4?1e18:75e12;
        uint256 R=1+raw%(boot+4096*lam);uint256 q=h.supplyWad(R,boot,lam,pL);if(q==0)return;
        uint256 target=1+portion%q;
        uint256 r=h.inverse(R,boot,lam,pL,target);
        assertLe(r,R);assertGe(h.supplyWad(r,boot,lam,pL),target);
        if(r>0)assertLt(h.supplyWad(r-1,boot,lam,pL),target);
    }
    function test_AllControls_0() public view { _ordered(0,200); }
    function test_AllControls_200() public view { _ordered(200,400); }
    function test_AllControls_400() public view { _ordered(400,600); }
    function test_AllControls_600() public view { _ordered(600,800); }
    function test_AllControls_800() public view { _ordered(800,1000); }
    function test_AllControls_1000() public view { _ordered(1000,1200); }
    function test_AllControls_1200() public view { _ordered(1200,1400); }
    function test_AllControls_1400() public view { _ordered(1400,1600); }
    function test_AllControls_1600() public view { _ordered(1600,1800); }
    function test_AllControls_1800() public view { _ordered(1800,2000); }
    function test_AllControls_2000() public view { _ordered(2000,2200); }
    function test_AllControls_2200() public view { _ordered(2200,2400); }
    function test_AllControls_2400() public view { _ordered(2400,2600); }
    function test_AllControls_2600() public view { _ordered(2600,2800); }
    function test_AllControls_2800() public view { _ordered(2800,3000); }
    function test_AllControls_3000() public view { _ordered(3000,3200); }
    function test_AllControls_3200() public view { _ordered(3200,3400); }
    function test_AllControls_3400() public view { _ordered(3400,3600); }
    function test_AllControls_3600() public view { _ordered(3600,3800); }
    function test_AllControls_3800() public view { _ordered(3800,4000); }
    function test_AllControls_4000() public view { _ordered(4000,4200); }
    function test_AllControls_4200() public view { _ordered(4200,4400); }
    function test_AllControls_4400() public view { _ordered(4400,4600); }
    function test_AllControls_4600() public view { _ordered(4600,4800); }
    function test_AllControls_4800() public view { _ordered(4800,4937); }
    function test_AllBoundaries_0() public view { _boundary(0,200); }
    function test_AllBoundaries_200() public view { _boundary(200,400); }
    function test_AllBoundaries_400() public view { _boundary(400,600); }
    function test_AllBoundaries_600() public view { _boundary(600,800); }
    function test_AllBoundaries_800() public view { _boundary(800,1000); }
    function test_AllBoundaries_1000() public view { _boundary(1000,1200); }
    function test_AllBoundaries_1200() public view { _boundary(1200,1400); }
    function test_AllBoundaries_1400() public view { _boundary(1400,1600); }
    function test_AllBoundaries_1600() public view { _boundary(1600,1800); }
    function test_AllBoundaries_1800() public view { _boundary(1800,2000); }
    function test_AllBoundaries_2000() public view { _boundary(2000,2200); }
    function test_AllBoundaries_2200() public view { _boundary(2200,2400); }
    function test_AllBoundaries_2400() public view { _boundary(2400,2600); }
    function test_AllBoundaries_2600() public view { _boundary(2600,2800); }
    function test_AllBoundaries_2800() public view { _boundary(2800,3000); }
    function test_AllBoundaries_3000() public view { _boundary(3000,3200); }
    function test_AllBoundaries_3200() public view { _boundary(3200,3400); }
    function test_AllBoundaries_3400() public view { _boundary(3400,3600); }
    function test_AllBoundaries_3600() public view { _boundary(3600,3800); }
    function test_AllBoundaries_3800() public view { _boundary(3800,4000); }
    function test_AllBoundaries_4000() public view { _boundary(4000,4200); }
    function test_AllBoundaries_4200() public view { _boundary(4200,4400); }
    function test_AllBoundaries_4400() public view { _boundary(4400,4600); }
    function test_AllBoundaries_4600() public view { _boundary(4600,4800); }
    function test_AllBoundaries_4800() public view { _boundary(4800,4938); }
    function _smallSales(uint256 phase) internal view {
        uint256[5] memory boots=[uint256(1),1e12,450e18,100000e18,680000000e18];
        for(uint256 size;size<5;++size) {
            uint256 boot=boots[size];uint256 lam=h.lamAt(boot);uint256 pL=size==4?1e18:75e12;
            uint256 R=boot+phase*lam;uint256 q=h.supplyWad(R,boot,lam,pL);
            uint256[3] memory burns=[uint256(1),1e12,q/3];
            for(uint256 j;j<3;++j) {
                if(burns[j]>=q)continue;uint256 target=q-burns[j];
                uint256 r=h.inverse(R,boot,lam,pL,target);
                assertLe(r,R);assertGe(h.supplyWad(r,boot,lam,pL),target);
                if(r>0)assertLt(h.supplyWad(r-1,boot,lam,pL),target);
            }
        }
    }
    function test_SmallSalesAtWave_0() public view { _smallSales(0); }
    function test_SmallSalesAtWave_1() public view { _smallSales(1); }
    function test_SmallSalesAtWave_10() public view { _smallSales(10); }
    function test_SmallSalesAtWave_32() public view { _smallSales(32); }
    function test_SmallSalesAtWave_63() public view { _smallSales(63); }
    function test_SmallSalesAtWave_64() public view { _smallSales(64); }
    function test_SmallSalesAtWave_128() public view { _smallSales(128); }
    function test_SmallSalesAtWave_512() public view { _smallSales(512); }
    function test_SmallSalesAtWave_1024() public view { _smallSales(1024); }
    function test_SmallSalesAtWave_4096() public view { _smallSales(4096); }
}
