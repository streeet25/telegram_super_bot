"""Keep text-only tweets from becoming downloads of linked articles.

Use yt-dlp's normal Twitter authentication/API and video/card extraction. Only
ordinary URL fallback and article preview cards are removed from a copy of the
returned status; native videos, GIFs, player cards and quote ordering are intact.
"""

from yt_dlp.extractor.twitter import TwitterIE as _TwitterIE
from yt_dlp.utils import ExtractorError


class VideoMorphTwitterIE(_TwitterIE):
    IE_NAME = 'videomorph:twitter'

    def _real_extract(self, url):
        self._animation_ids = set()
        result = super()._real_extract(url)
        animation_ids = self._animation_ids.copy()

        def mark(entry):
            if str(entry.get('id')) in animation_ids:
                entry['videomorph_media_type'] = 'animation'
            return entry

        if 'entries' in result:
            result['entries'] = (mark(entry) for entry in result['entries'])
        else:
            mark(result)
        return result

    def _configuration_arg(self, *args, **kwargs):
        # Keep existing --extractor-args twitter:... settings despite the
        # separate plugin class name (notably the selected API).
        if kwargs.get('ie_key') is None:
            kwargs['ie_key'] = _TwitterIE
        return super()._configuration_arg(*args, **kwargs)

    def _extract_status(self, tweet_id):
        original = super()._extract_status(tweet_id)
        if not isinstance(original, dict) or not original:
            raise ExtractorError('Twitter post metadata unavailable', expected=True)

        # Twitter serves GIFs as silent MP4s. Only its explicit native media
        # type is authoritative: a short/silent ordinary video is not a GIF.
        for post in (original, original.get('quoted_status') or {}):
            for media in (post.get('extended_entities') or {}).get('media') or []:
                media_id = media.get('id_str') or media.get('id')
                if media.get('type') == 'animated_gif' and media_id is not None:
                    self._animation_ids.add(str(media_id))

        status = dict(original)
        entities = status.get('entities')
        if isinstance(entities, dict):
            status['entities'] = {key: value for key, value in entities.items() if key != 'urls'}

        card = status.get('card')
        if isinstance(card, dict) and str(card.get('name', '')).split(':')[-1] in ('summary', 'summary_large_image'):
            status.pop('card')
        return status
