"""Public Threads posts, scoped to the requested post and its own first video.

This project-local plugin is enabled only for Threads downloads. No login or
Instagram cookie jar is used. Public preview HTML can change independently of
yt-dlp; when its post identity cannot be verified we fail closed.
"""

import base64
import json
import math
import re
from html.parser import HTMLParser
from urllib.parse import parse_qs, urlsplit

from yt_dlp.extractor.common import InfoExtractor
from yt_dlp.utils import ExtractorError


class _PostPage(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.blocks = []
        self.canonical = None
        self.current = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'script' and attrs.get('type') == 'application/json':
            self.current = []
        if tag == 'meta' and attrs.get('property') == 'og:url':
            self.canonical = attrs.get('content')

    def handle_data(self, data):
        if self.current is not None:
            self.current.append(data)

    def handle_endtag(self, tag):
        if tag == 'script' and self.current is not None:
            try:
                self.blocks.append(json.loads(''.join(self.current)))
            except (ValueError, RecursionError):
                pass
            self.current = None


class VideoMorphThreadsIE(InfoExtractor):
    IE_NAME = 'videomorph:threads'
    _VALID_URL = r'https?://(?:www\.)?threads\.(?:com|net)/(?:(?:@[A-Za-z0-9._]+/post|t)/(?P<id>[A-Za-z0-9_-]+)|share/(?P<share>[A-Za-z0-9_-]+))/?(?:[?#][^\s]*)?$'
    _PREVIEW_AGENT = 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)'

    @staticmethod
    def _target_post(blocks, code):
        # Iterative traversal preserves page order without recursion on remote
        # JSON. Never select the first arbitrary video or descend into a quote
        # once the requested post has been identified.
        stack = list(reversed(blocks))
        while stack:
            node = stack.pop()
            if isinstance(node, dict):
                if node.get('code') == code and any(k in node for k in ('media_type', 'video_versions', 'carousel_media')):
                    return node
                stack.extend(reversed(list(node.values())))
            elif isinstance(node, list):
                stack.extend(reversed(node))
        return None

    @staticmethod
    def _number(value):
        try:
            value = float(value)
            return value if math.isfinite(value) and value > 0 else None
        except (TypeError, ValueError):
            return None

    def _formats(self, media):
        formats = []
        seen = set()
        for version in media.get('video_versions') or []:
            if not isinstance(version, dict) or not isinstance(version.get('url'), str):
                continue
            url = version['url']
            parsed = urlsplit(url)
            host = (parsed.hostname or '').lower()
            if parsed.scheme != 'https' or parsed.username or parsed.password or not any(
                host == domain or host.endswith('.' + domain) for domain in ('cdninstagram.com', 'fbcdn.net')
            ):
                continue
            if url in seen:
                continue
            seen.add(url)
            formats.append({
                'url': url, 'format_id': f'mp4-{len(formats)}', 'ext': 'mp4',
                'width': self._number(version.get('width') or media.get('original_width')),
                'height': self._number(version.get('height') or media.get('original_height')),
                'vcodec': 'unknown',
                'acodec': 'none' if media.get('has_audio') is False else 'unknown',
                'http_headers': {'Referer': 'https://www.threads.com/'},
            })
        return formats

    def _duration(self, media, formats):
        duration = self._number(media.get('video_duration'))
        if duration:
            return duration
        for fmt in formats:
            encoded = parse_qs(urlsplit(fmt['url']).query).get('efg', [''])[0]
            try:
                metadata = json.loads(base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4)))
                duration = self._number(metadata.get('duration_s')) if isinstance(metadata, dict) else None
                if duration:
                    return duration
            except (ValueError, TypeError, UnicodeError):
                pass
        return None

    def _real_extract(self, url):
        match = self._match_valid_url(url)
        code = match.group('id')
        page = _PostPage()
        page.feed(self._download_webpage(
            url, code or match.group('share'),
            headers={'User-Agent': self._PREVIEW_AGENT}))
        if not code:
            canonical = re.fullmatch(self._VALID_URL, page.canonical or '')
            code = canonical.group('id') if canonical else None
        if not code:
            raise ExtractorError('Cannot identify the shared Threads post; send its /@user/post/ URL', expected=True)
        post = self._target_post(page.blocks, code)
        if post is None:
            raise ExtractorError('Threads post unavailable: private, deleted, or public preview unavailable', expected=True)

        # A carousel may start with photos. Select the first video belonging to
        # THIS post; quoted/recommended posts are intentionally not traversed.
        media_items = post.get('carousel_media') or [post]
        for media in media_items:
            if not isinstance(media, dict):
                continue
            formats = self._formats(media)
            if formats:
                return {
                    'id': code, 'title': f'Threads {code}', 'formats': formats,
                    'duration': self._duration(media, formats), 'webpage_url': url,
                }
        raise ExtractorError('This Threads post contains no video', expected=True)
