"""Offline Twitter regression fixtures through the real yt-dlp extractor."""
import copy
import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'ytdlp_plugins' / 'videomorph'))
from yt_dlp_plugins.extractor.videomorph_twitter import VideoMorphTwitterIE
from yt_dlp.extractor.twitter import TwitterIE
from yt_dlp.utils import ExtractorError
from yt_dlp import YoutubeDL


class Quiet:
    def debug(self, *_): pass
    def warning(self, *_): pass
    def error(self, *_): pass


class TwitterExtractorTest(unittest.TestCase):
    URL = 'https://twitter.com/example/status/1234567890123456789'
    ARTICLE = 'https://example.invalid/article'

    def extract(self, status, extractor=VideoMorphTwitterIE):
        with YoutubeDL({'quiet': True, 'logger': Quiet()}) as ydl:
            with patch.object(TwitterIE, '_extract_status', return_value=status):
                return extractor(ydl)._real_extract(self.URL)

    def video(self, name='own', kind='video'):
        return {'type': kind, 'id_str': name, 'video_info': {'duration_millis': 2000, 'variants': [
            {'url': f'https://video.twimg.com/fixture/{name}.mp4', 'content_type': 'video/mp4', 'bitrate': 832000}]}}

    def test_upstream_reproduces_article_redirect_but_guard_skips_it(self):
        status = {'full_text': 'Text with a link', 'entities': {'urls': [{'expanded_url': self.ARTICLE}]}}
        self.assertEqual(self.ARTICLE, self.extract(status, TwitterIE)['url'])
        with self.assertRaisesRegex(ExtractorError, 'No video could be found'):
            self.extract(status)

    def test_text_without_links_remains_a_no_video_result(self):
        with self.assertRaisesRegex(ExtractorError, 'No video could be found'):
            self.extract({'full_text': 'Plain text'})

    def test_summary_and_large_image_article_cards_are_skipped(self):
        for name in ('summary', 'summary_large_image', '123:summary'):
            status = {'full_text': 'Article', 'card': {'name': name, 'binding_values': {
                'card_url': {'type': 'STRING', 'string_value': self.ARTICLE}}}}
            if name == 'summary':
                self.assertEqual(self.ARTICLE, self.extract(status, TwitterIE)['url'])
            with self.assertRaisesRegex(ExtractorError, 'No video could be found'):
                self.extract(status)

    def test_photo_only_post_with_external_link_is_skipped(self):
        with self.assertRaisesRegex(ExtractorError, 'No video could be found'):
            self.extract({'full_text': 'Photo', 'extended_entities': {'media': [{'type': 'photo'}]},
                          'entities': {'urls': [{'expanded_url': self.ARTICLE}]}})

    def test_native_video_and_gif_are_preserved(self):
        for kind in ('video', 'animated_gif'):
            result = self.extract({'full_text': 'Video', 'extended_entities': {'media': [self.video(kind=kind)]},
                                   'entities': {'urls': [{'expanded_url': self.ARTICLE}]}})
            self.assertEqual('own', result['id'])
            self.assertTrue(result['formats'][0]['url'].endswith('/own.mp4'))

    def test_own_video_stays_before_quoted_video(self):
        result = self.extract({'full_text': 'Own video', 'extended_entities': {'media': [self.video()]},
                               'quoted_status': {'extended_entities': {'media': [self.video('quote')]}}})
        self.assertEqual(['own', 'quote'], [entry['id'] for entry in result['entries']])

    def test_native_video_survives_removing_an_article_preview(self):
        result = self.extract({'full_text': 'Video', 'extended_entities': {'media': [self.video()]},
                               'card': {'name': 'summary', 'binding_values': {}}})
        self.assertEqual('own', result['id'])

    def test_real_player_card_is_not_an_ordinary_link(self):
        player = 'https://www.youtube.com/watch?v=fixture'
        result = self.extract({'full_text': 'Player', 'card': {'name': 'player', 'binding_values': {
            'player_url': {'type': 'STRING', 'string_value': player}}}})
        self.assertEqual(player, result['url'])

    def test_input_metadata_is_not_mutated(self):
        original = {'full_text': 'Video', 'entities': {'urls': [{'expanded_url': self.ARTICLE}], 'hashtags': [{'text': 'tag'}]},
                    'extended_entities': {'media': [self.video()]}, 'card': {'name': 'summary', 'binding_values': {}}}
        before = copy.deepcopy(original)
        result = self.extract(original)
        self.assertEqual(before, original)
        self.assertEqual(['tag'], result['tags'])

    def test_empty_metadata_is_a_real_error_not_confirmed_no_video(self):
        for status in ({}, None, []):
            with self.assertRaisesRegex(ExtractorError, 'metadata unavailable'):
                self.extract(status)

    def test_api_failures_are_not_suppressed(self):
        failure = ExtractorError('HTTP Error 403: Forbidden', expected=True)
        with YoutubeDL({'quiet': True, 'logger': Quiet()}) as ydl:
            with patch.object(TwitterIE, '_extract_status', side_effect=failure):
                with self.assertRaises(ExtractorError) as caught:
                    VideoMorphTwitterIE(ydl)._real_extract(self.URL)
        self.assertIs(failure, caught.exception)

    def test_existing_twitter_extractor_arguments_are_preserved(self):
        with YoutubeDL({'quiet': True, 'logger': Quiet(), 'extractor_args': {
            'twitter': {'api': ['syndication']}, 'other': {'setting': ['MixedCase']}}}) as ydl:
            extractor = VideoMorphTwitterIE(ydl)
            self.assertEqual(['syndication'], extractor._configuration_arg('api', ['graphql']))
            self.assertEqual(['fallback'], extractor._configuration_arg('missing', ['fallback']))
            self.assertEqual(['MixedCase'], extractor._configuration_arg('setting', ie_key='other', casesense=True))

    def test_cli_plugin_is_scoped_and_has_priority(self):
        # --list-extractors exits before plugin loading in yt-dlp 2026.10.26,
        # and is alphabetically sorted. Exercise actual CLI URL selection.
        fixture = {'full_text': 'Video', 'extended_entities': {'media': [self.video()]}}
        script = f"""
import yt_dlp
from unittest.mock import patch
from yt_dlp.extractor.twitter import TwitterIE
with patch.object(TwitterIE, '_extract_status', return_value={fixture!r}), \\
     patch.object(TwitterIE, '_real_initialize'):
    yt_dlp.main()
"""
        command = [sys.executable, '-c', script, '--ignore-config', '--no-plugin-dirs',
                   '--skip-download', '--dump-single-json', '--no-playlist', '--playlist-items', '1', '--quiet']
        for extra, expected in ((['--plugin-dirs', str(ROOT / 'ytdlp_plugins')], 'videomorph:twitter'), ([], 'twitter')):
            result = subprocess.run(command + extra + [self.URL], text=True, capture_output=True)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(expected, json.loads(result.stdout)['extractor'])


if __name__ == '__main__':
    unittest.main()
