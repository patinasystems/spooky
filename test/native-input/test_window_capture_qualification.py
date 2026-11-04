"""Regression checks for visibility qualification, without UI or pixel capture."""
import unittest

from analyze_window_capture import Capture


class WindowQualificationTests(unittest.TestCase):
    def capture(self, changes=()):
        capture = Capture.__new__(Capture)
        capture.valid_time_frames = [{"display_uptime_s": 1}, {"display_uptime_s": 10}]
        capture.window_states = [{"uptime_s": 0, "metrics": {
            "visible": 1, "active_space": 1, "occlusion_visible": 1,
            "key": 1, "application_hidden": 0, "miniaturized": 0,
        }}]
        capture.window_states.extend(changes)
        return capture

    def test_late_occlusion_notification_flags_an_otherwise_visible_response(self):
        capture = self.capture([{"uptime_s": 5.02, "metrics": {"occlusion_visible": 0}}])
        self.assertEqual(capture.visibility_issues(4.85, 5), [])
        self.assertIn("window fully occluded", capture.steady_window_issues(4.85, 5, 500))

    def test_focus_loss_alone_does_not_make_visible_pixels_invalid(self):
        capture = self.capture([{"uptime_s": 4.7, "metrics": {"key": 0, "application_active": 0}}])
        self.assertEqual(capture.steady_window_issues(4.85, 5, 500), [])

    def test_prior_off_space_state_is_checked_before_the_input(self):
        capture = self.capture([
            {"uptime_s": 4.6, "metrics": {"active_space": 0}},
            {"uptime_s": 4.8, "metrics": {"active_space": 1}},
        ])
        self.assertIn("window outside active Space", capture.steady_window_issues(4.85, 5, 500))

    def test_guard_requires_observation_coverage_on_both_sides(self):
        capture = self.capture()
        self.assertTrue(capture.steady_window_issues(1.1, 1.2, 500))
        self.assertTrue(capture.steady_window_issues(9.7, 9.9, 500))
        self.assertEqual(capture.steady_window_issues(1.1, 1.2, 0), [])


if __name__ == "__main__":
    unittest.main()
