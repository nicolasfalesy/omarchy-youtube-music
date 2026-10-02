"""tools/cdp-bridge checks that take longer than the quick part allows."""
from quick_bridge import race_once
from ytmtest import Case


class BridgeRaceSlowTest(Case):
    def test_two_bridges_at_once_start_one_app_30_times(self):
        results = []
        for _ in range(30):
            self.tearDown()
            self.setUp()
            results.append(race_once(self))
        self.assertEqual(results.count((1, False, True)), 30, results)
