"""Regression checks that the proof runner cannot turn partial results green."""
import unittest

from run import classify, valid_bridge, COMPILER_CONFIG_KEYS


def payload(**changes):
    row = {"name": "check_p(uint256)", "exitcode": 0, "num_paths": [2, 1, 0],
           "num_bounded_loops": 0, "num_models": 0}
    row.update(changes)
    return {"test_results": {"Contract": [row]}}


class ResultGateTests(unittest.TestCase):
    def test_config_evidence_excludes_credentials(self):
        self.assertNotIn("etherscan_api_key", COMPILER_CONFIG_KEYS)
        self.assertNotIn("rpc_endpoints", COMPILER_CONFIG_KEYS)
        self.assertNotIn("eth_rpc_url", COMPILER_CONFIG_KEYS)

    def test_complete_result(self):
        self.assertEqual(classify(payload(), "check_p", "proof", 0), ("PROVED", True))

    def test_concrete_is_not_symbolic(self):
        self.assertEqual(classify(payload(), "check_p", "fixture", 0), ("CONCRETE_CHECK_PASSED", True))

    def test_incomplete_results_fail(self):
        for changes in ({"num_bounded_loops": 1}, {"num_paths": [1, 0, 0]},
                        {"num_paths": [2, 1, 1]}, {"num_paths": None}, {"num_paths": []}, {"num_paths": [0, 1, 0]},
                        {"exitcode": 2}, {"exitcode": 3}, {"exitcode": 5}):
            with self.subTest(changes=changes):
                self.assertFalse(classify(payload(**changes), "check_p", "proof", 0)[1])

    def test_missing_wrong_duplicate_results_fail(self):
        for data in ({}, {"test_results": {}}, payload(name="check_other(uint256)"),
                     {"test_results": {"A": payload()["test_results"]["Contract"] * 2}}):
            self.assertFalse(classify(data, "check_p", "proof", 0)[1])

    def test_process_failure_cannot_pass(self):
        self.assertFalse(classify(payload(), "check_p", "proof", 1)[1])

    def test_wrong_contract_cannot_pass(self):
        self.assertFalse(classify(payload(), "check_p", "proof", 0, "Other")[1])

    def test_bridge_requires_one_exact_passing_test(self):
        row = {"test_results": {"test_fixture_matches_constructor()": {"status": "Success"}}}
        self.assertTrue(valid_bridge({"path:HookRulesSymbolicTest": row}))
        self.assertFalse(valid_bridge({}))
        self.assertFalse(valid_bridge({"path:WrongContract": row}))
        self.assertFalse(valid_bridge({"path:HookRulesSymbolicTest": {"test_results": {}}}))
        self.assertFalse(valid_bridge({"path:HookRulesSymbolicTest": {"test_results": {
            "test_fixture_matches_constructor()": {"status": "Failure"}}}}))

    def test_negative_controls_require_expected_failure(self):
        self.assertFalse(classify(payload(), "check_p", "counterexample", 0)[1])
        self.assertTrue(classify(payload(exitcode=1, num_models=1), "check_p", "counterexample", 1)[1])
        self.assertFalse(classify(payload(exitcode=2), "check_p", "counterexample", 1)[1])
        self.assertTrue(classify(payload(exitcode=4, num_paths=[1, 0, 0]), "check_p", "empty-domain", 1)[1])
        self.assertFalse(classify(payload(exitcode=3, num_paths=[1, 0, 1]), "check_p", "empty-domain", 1)[1])


if __name__ == "__main__":
    unittest.main()
