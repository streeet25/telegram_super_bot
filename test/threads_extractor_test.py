"""Offline tests using yt-dlp's installed extractor API; no HTTP requests."""
import base64
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'ytdlp_plugins' / 'videomorph'))
from yt_dlp_plugins.extractor.videomorph_threads import VideoMorphThreadsIE
from yt_dlp.utils import ExtractorError
from yt_dlp import YoutubeDL


class ThreadsExtractorTest(unittest.TestCase):
    URL = 'https://www.threads.com/@person/post/TARGET'

    def video(self, code='TARGET', name='own', **extra):
        return dict(code=code, media_type=2, video_versions=[{'url': f'https://video.cdninstagram.com/{name}.mp4'}], **extra)

    def extract(self, posts, url=None, canonical=None):
        ie = VideoMorphThreadsIE()
        html = '<script type="application/json">invalid unrelated JSON</script>'
        html += '<script data-sjs type="application/json">' + json.dumps(posts) + '</script>'
        if canonical:
            html += f'<meta content="{canonical}" property="og:url">'
        ie._download_webpage = lambda *args, **kwargs: html
        return ie._real_extract(url or self.URL)

    def test_both_domains_and_link_forms(self):
        for host in ('threads.net', 'threads.com', 'www.threads.net', 'www.threads.com'):
            for path in ('/@p/post/TARGET', '/t/TARGET', '/share/SHORT'):
                self.assertTrue(VideoMorphThreadsIE.suitable('https://' + host + path))
        for url in ('https://threads.com/@p', 'https://threads.com.evil/t/TARGET', 'https://threads.com/t/TARGET/extra'):
            self.assertFalse(VideoMorphThreadsIE.suitable(url))

    def test_exact_post_not_recommendations_or_quote(self):
        result = self.extract([self.video('OTHER', 'recommended'), self.video(quoted_post=self.video('QUOTE', 'quoted'))])
        self.assertEqual('TARGET', result['id'])
        self.assertTrue(result['formats'][0]['url'].endswith('/own.mp4'))

    def test_missing_post_fails_closed(self):
        with self.assertRaisesRegex(ExtractorError, 'unavailable'):
            self.extract([self.video('OTHER')])

    def test_text_post_does_not_download_quoted_video(self):
        with self.assertRaisesRegex(ExtractorError, 'contains no video'):
            self.extract([{'code': 'TARGET', 'media_type': 1, 'quoted_post': self.video('QUOTE')}])

    def test_first_video_in_own_carousel(self):
        result = self.extract([{'code': 'TARGET', 'carousel_media': [{'media_type': 1}, self.video(name='first'), self.video(name='second')]}])
        self.assertTrue(result['formats'][0]['url'].endswith('/first.mp4'))

    def test_share_resolves_exact_canonical_or_fails_closed(self):
        url = 'https://threads.com/share/SHORT/'
        self.assertEqual('TARGET', self.extract([self.video()], url, self.URL)['id'])
        for canonical in (None, 'https://evil.test/@p/post/TARGET', 'https://threads.com/share/SHORT'):
            with self.assertRaisesRegex(ExtractorError, 'Cannot identify'):
                self.extract([self.video()], url, canonical)

    def test_untrusted_media_urls_are_rejected(self):
        for url in ('file:///etc/passwd', 'http://127.0.0.1/video', 'https://cdninstagram.com.evil/video', 'https://user:pass@video.fbcdn.net/v'):
            post = self.video()
            post['video_versions'][0]['url'] = url
            with self.assertRaisesRegex(ExtractorError, 'contains no video'):
                self.extract([post])

    def test_dimensions_duration_and_silent_video(self):
        post = self.video(original_width=640, original_height=360, has_audio=False)
        metadata = base64.urlsafe_b64encode(json.dumps({'duration_s': 42}).encode()).decode().rstrip('=')
        post['video_versions'][0]['url'] += '?efg=' + metadata
        result = self.extract([post])
        self.assertEqual(42, result['duration'])
        self.assertEqual(640, result['formats'][0]['width'])
        self.assertEqual('none', result['formats'][0]['acodec'])

    def test_malformed_duration_is_ignored(self):
        post = self.video()
        post['video_versions'][0]['url'] += '?efg=bad'
        self.assertIsNone(self.extract([post])['duration'])

    def test_silent_and_portrait_formats_are_downloadable(self):
        with YoutubeDL({'quiet': True}) as ydl:
            choose = ydl.build_format_selector('best[ext=mp4]/bestvideo[ext=mp4]/best/bestvideo')
            for sound in (True, False):
                result = self.extract([self.video(original_width=720, original_height=1280, has_audio=sound)])
                selected = list(choose({'formats': result['formats'], 'has_merged_format': False, 'incomplete_formats': False}))
                self.assertEqual(1, len(selected))


if __name__ == '__main__':
    unittest.main()
