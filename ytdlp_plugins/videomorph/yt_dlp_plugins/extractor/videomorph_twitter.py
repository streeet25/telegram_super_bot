"""Keep text-only tweets from becoming downloads of linked articles.

Use yt-dlp's normal Twitter authentication/API and video/card extraction. Only
ordinary URL fallback and article preview cards are removed from a copy of the
returned status; native videos, GIFs, player cards and quote ordering are intact.
"""

from yt_dlp.extractor.twitter import TwitterIE as _TwitterIE
from yt_dlp.utils import ExtractorError


class VideoMorphTwitterIE(_TwitterIE):
    IE_NAME = 'videomorph:twitter'

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

        status = dict(original)
        entities = status.get('entities')
        if isinstance(entities, dict):
            status['entities'] = {key: value for key, value in entities.items() if key != 'urls'}

        card = status.get('card')
        if isinstance(card, dict) and str(card.get('name', '')).split(':')[-1] in ('summary', 'summary_large_image'):
            status.pop('card')
        return status
