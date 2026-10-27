"""Offline regression tests against yt-dlp's real format-selection pipeline.

Reads the actual Ruby selectors; does not make HTTP requests. Run with the same
Python environment as yt-dlp (production image: /opt/venv/bin/python).
"""

import copy
import json
import subprocess
import unittest
from pathlib import Path

from yt_dlp import YoutubeDL
from yt_dlp.utils import DownloadError, ExtractorError


class QuietLogger:
    def debug(self, message): pass
    def warning(self, message): pass
    def error(self, message): pass


class YtdlpFormatsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[1]
        script = "require 'json'; require_relative 'lib/telegram_instwitter_bot/ytdlp'; puts JSON.generate(default: default_ytdlp_formats, instagram: instagram_ytdlp_formats)"
        cls.selectors = json.loads(subprocess.check_output(['ruby', '-e', script], cwd=root, text=True))

    def video(self, name='video', height=720, ext='mp4', audio='none'):
        return {'format_id': name, 'url': f'https://example.invalid/{name}.{ext}',
                'ext': ext, 'vcodec': 'vp9' if ext == 'webm' else 'avc1',
                'acodec': audio, 'height': height, 'width': 1280}

    def audio(self, ext='m4a'):
        return {'format_id': 'audio', 'url': f'https://example.invalid/audio.{ext}',
                'ext': ext, 'vcodec': 'none', 'acodec': 'mp4a' if ext == 'm4a' else 'opus'}

    def select(self, formats, selectors):
        for selector in selectors:
            with YoutubeDL({'quiet': True, 'logger': QuietLogger(), 'no_warnings': True,
                            'check_formats': False, 'format': selector}) as ydl:
                try:
                    return ydl.process_ie_result({'id': 'fixture', 'title': 'Fixture',
                        'extractor': 'fixture', 'formats': copy.deepcopy(formats)}, download=False)
                except (DownloadError, ExtractorError):
                    pass
        return None

    def test_old_selectors_reproduce_failure_for_separate_tracks(self):
        formats = [self.audio(), self.video()]
        self.assertIsNone(self.select(formats, ['best[ext=mp4]/best']))
        for provider, selectors in self.selectors.items():
            with self.subTest(provider=provider):
                result = self.select(formats, selectors)
                self.assertEqual('video+audio', result['format_id'])
                self.assertNotEqual('none', result['acodec'])
                self.assertEqual(2, len(result['requested_formats']))

    def test_combined_mp4_remains_preferred(self):
        formats = [self.audio(), self.video('silent'), self.video('combined', audio='mp4a')]
        for selectors in self.selectors.values():
            self.assertEqual('combined', self.select(formats, selectors)['format_id'])

    def test_webm_separate_tracks_are_merged_not_sent_silent(self):
        formats = [self.audio('webm'), self.video(ext='webm')]
        for selectors in self.selectors.values():
            result = self.select(formats, selectors)
            self.assertEqual('video+audio', result['format_id'])
            self.assertEqual('opus', result['acodec'])

    def test_genuinely_silent_clips_remain_supported(self):
        for selectors in self.selectors.values():
            result = self.select([self.video()], selectors)
            self.assertEqual('video', result['format_id'])
            self.assertEqual('none', result['acodec'])

    def test_audio_only_is_never_a_video_download(self):
        for selectors in self.selectors.values():
            self.assertIsNone(self.select([self.audio()], selectors))

    def test_height_limit_and_smaller_retry_candidates(self):
        formats = [self.audio()] + [self.video(f'v{h}', height=h) for h in (360, 480, 720, 1080)]
        for index, height in enumerate((720, 480, 360)):
            result = self.select(formats, [self.selectors['default'][index]])
            self.assertEqual(height, result['height'])
            self.assertEqual(f'v{height}+audio', result['format_id'])

    def test_unknown_height_and_portrait_have_final_fallback(self):
        for height in (None, 1920):
            for selectors in self.selectors.values():
                result = self.select([self.audio(), self.video(height=height)], selectors)
                self.assertEqual('video+audio', result['format_id'])

    def test_instagram_keeps_original_quality_priority(self):
        formats = [self.audio(), self.video('v720'), self.video('v1080', height=1080)]
        result = self.select(formats, self.selectors['instagram'])
        self.assertEqual('v1080+audio', result['format_id'])
        self.assertEqual(4, len(self.selectors['instagram']))
        self.assertEqual(4, len(set(self.selectors['instagram'])))


if __name__ == '__main__':
    unittest.main()
