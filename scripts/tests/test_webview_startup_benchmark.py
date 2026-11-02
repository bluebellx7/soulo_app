import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('webview_startup_benchmark', Path(__file__).resolve().parents[1] / 'benchmark_webview_startup.py')
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


def event(name, timestamp):
    return {'event': name, 'time': timestamp, 'detail': ''}


class StartupSampleTests(unittest.TestCase):
    def test_restored_content_before_submit_is_excluded(self):
        values = benchmark.summarize([
            event('content_visible', 1), event('acquire_start', 0.5),
            event('search_submit', 2), event('acquire_start', 2.1),
            event('acquire_end', 2.2), event('content_visible', 3),
        ])
        self.assertEqual(values['submit_to_visible_ms'], 1000)
        self.assertEqual(values['acquire_ms'], 100)

    def test_old_content_does_not_make_a_missing_page_look_ready(self):
        values = benchmark.summarize([event('content_visible', 1), event('search_submit', 2)])
        self.assertNotIn('submit_to_visible_ms', values)

    def test_warmup_before_search_keeps_its_own_timing(self):
        values = benchmark.summarize([
            event('warmup_start', 1), event('warmup_ready', 1.5),
            event('search_submit', 2), event('pool_hit', 2.1), event('content_visible', 2.6),
        ])
        self.assertEqual(values['warmup_ms'], 500)
        self.assertEqual(values['submit_to_visible_ms'], 600)
        self.assertTrue(values['pool_hit'])
