# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=11", "numpy>=2"]
# ///
"""Synthetic regressions for pixel evidence admission; no app or capture runs."""
import unittest

import numpy as np
from PIL import Image

from benchmark_window_pixels import finite, landmark_positions, sample_report, summarize, track_landmark


class CaptureFixture:
    def __init__(self, *, missing=False, transition=False):
        self.frames = [dict(i=1, display_uptime_s=10.010, callback_uptime_s=10.020, status=0),
                       dict(i=2, display_uptime_s=10.020, callback_uptime_s=10.030, status=3 if missing else 1),
                       dict(i=3, display_uptime_s=10.030, callback_uptime_s=10.050, status=0)]
        self.by_id = {frame['i']: frame for frame in self.frames}
        self.transition = transition

    def has_time(self, frame):
        return finite(frame.get('display_uptime_s')) and frame['display_uptime_s'] > 0

    def has_pixels(self, frame):
        return frame['status'] == 0

    def visibility_issues(self, start, end):
        return []

    def steady_window_issues(self, start, end, margin):
        return ['near Space transition'] if self.transition else []


class WindowPixelTests(unittest.TestCase):
    def sample(self, capture=None, handler_time=10.002, **changes):
        item = dict(input_id=1, confirmed=True, target='new glyph m', last_absent_frame=1, first_present_frame=3)
        item.update(changes)
        event = dict(id=1, stage='inputReceived', event_uptime_s=10.000, uptime_s=handler_time)
        return sample_report(item, capture or CaptureFixture(), [event], {1: event}, 500)

    def test_display_timestamp_not_callback_defines_bounds(self):
        sample = self.sample()
        self.assertTrue(sample['eligible'])
        self.assertAlmostEqual(sample['key_to_pixel_ms'][0], 10)
        self.assertAlmostEqual(sample['key_to_pixel_ms'][1], 30)
        self.assertAlmostEqual(sample['callback_lag_ms'], 20)

    def test_unavailable_intervening_frame_keeps_bounds_but_excludes_sample(self):
        sample = self.sample(CaptureFixture(missing=True))
        self.assertFalse(sample['eligible'])
        self.assertEqual(sample['intervening_unavailable_frames'], [2])
        self.assertIn('key_to_pixel_ms', sample)

    def test_post_source_but_pre_handler_endpoint_keeps_bounds_without_attribution(self):
        sample = self.sample(handler_time=10.040)
        self.assertFalse(sample['eligible'])
        self.assertEqual(len(sample['causality_exclusions']), 1)
        self.assertAlmostEqual(sample['key_to_pixel_ms'][0], 10)
        self.assertAlmostEqual(sample['key_to_pixel_ms'][1], 30)

    def test_later_absent_frame_does_not_hide_earlier_source_interval_gap(self):
        capture = CaptureFixture(missing=True)
        capture.frames.insert(0, dict(i=0, display_uptime_s=9.990, callback_uptime_s=9.995, status=0))
        capture.frames.append(dict(i=4, display_uptime_s=10.040, callback_uptime_s=10.050, status=0))
        capture.by_id = {frame['i']: frame for frame in capture.frames}
        sample = self.sample(capture, last_absent_frame=3, first_present_frame=4)
        self.assertFalse(sample['eligible'])
        self.assertEqual(sample['intervening_unavailable_frames'], [2])
        self.assertAlmostEqual(sample['key_to_pixel_ms'][0], 30)
        self.assertAlmostEqual(sample['key_to_pixel_ms'][1], 40)

    def test_untimed_frame_before_final_absent_observation_is_not_skipped(self):
        capture = CaptureFixture()
        capture.frames[0]['display_uptime_s'] = 9.990
        capture.frames[1].pop('display_uptime_s')
        capture.frames.append(dict(i=4, display_uptime_s=10.040, callback_uptime_s=10.050, status=0))
        capture.by_id = {frame['i']: frame for frame in capture.frames}
        sample = self.sample(capture, last_absent_frame=3, first_present_frame=4)
        self.assertFalse(sample['eligible'])
        self.assertEqual(sample['intervening_unavailable_frames'], [2])
        self.assertIn('key_to_pixel_ms', sample)

    def test_nearby_space_change_keeps_raw_sample(self):
        sample = self.sample(CaptureFixture(transition=True))
        self.assertFalse(sample['eligible'])
        self.assertIn('key_to_pixel_ms', sample)

    def test_unconfirmed_roi_change_is_not_a_latency_sample(self):
        sample = self.sample(confirmed=False)
        self.assertFalse(sample['eligible'])
        self.assertNotIn('key_to_pixel_ms', sample)

    def test_coalesced_glyphs_count_one_endpoint_frame(self):
        one = self.sample()
        two = dict(one, input_id=2)
        result = summarize([one, two])['all_qualifying']
        self.assertEqual(result['n'], 2)
        self.assertEqual(result['distinct_endpoint_frames'], 1)

    def test_landmark_matching_measures_pixel_positions_without_row_assumptions(self):
        template = np.array([[[10, 20, 30], [40, 50, 60]], [[70, 80, 90], [100, 110, 120]]], dtype=np.uint8)
        image = np.zeros((20, 5, 3), dtype=np.uint8)
        image[3:5, 1:3] = template
        image[12:14, 1:3] = template
        self.assertEqual(landmark_positions(image, template, [1, 0, 2, 20]), [3, 12])
        image[3, 1, 0] += 1
        self.assertEqual(landmark_positions(image, template, [1, 0, 2, 20]), [12])

    def test_dropped_input_events_exclude_automatic_landmarks_but_keep_raw_bounds(self):
        capture = CaptureFixture()
        capture.frames = [dict(i=1, roi_offset=0, display_uptime_s=9.990, callback_uptime_s=9.995, status=0),
                          dict(i=2, roi_offset=48, display_uptime_s=10.030, callback_uptime_s=10.035, status=0)]
        capture.by_id = {frame['i']: frame for frame in capture.frames}
        capture.observations = capture.frames
        capture.width, capture.height = 2, 8
        template = np.array([[[10, 20, 30], [40, 50, 60]], [[70, 80, 90], [100, 110, 120]]], dtype=np.uint8)
        images = {}
        for ident, row in [(1, 1), (2, 3)]:
            pixels = np.zeros((8, 2, 3), dtype=np.uint8)
            pixels[row:row + 2] = template
            images[ident] = Image.fromarray(pixels)
        capture.native_image = lambda frame: images[frame['i']]
        event = dict(id=1, stage='inputReceived', input_kind='scroll', event_uptime_s=10.000, uptime_s=10.002)
        spec = dict(name='verified unique row', reference_frame=1, template_rect=[0, 1, 2, 2],
                    search_rect=[0, 0, 2, 8], start_uptime_s=9.980, end_uptime_s=10.040,
                    confirmed_template=True)
        complete = track_landmark(spec, capture, [event], {1: event}, 0)
        dropped = track_landmark(spec, capture, [event], {1: event}, 0, dropped_events=1)
        self.assertEqual(complete['statistics']['all_qualifying']['n'], 1)
        self.assertEqual(dropped['statistics']['all_qualifying']['n'], 0)
        self.assertEqual(dropped['statistics']['excluded_input_ids'], [1])
        self.assertTrue(dropped['samples'][0]['input_log_exclusions'])
        self.assertEqual(dropped['samples'][0]['key_to_pixel_ms'], complete['samples'][0]['key_to_pixel_ms'])


if __name__ == '__main__':
    unittest.main()
