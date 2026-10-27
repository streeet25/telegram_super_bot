"""Download and merge locally generated tracks via the actual Ruby downloader.

Uses loopback HTTP only. Safe to run in a Docker container with --network none;
requires the application's gems, yt-dlp, ffmpeg and ffprobe, never a real token.
"""

import functools
import http.server
import json
import os
import subprocess
import tempfile
import threading
from pathlib import Path


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='ytdlp-merge-smoke-') as directory:
    fixture = Path(directory)
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                    'color=c=blue:s=320x240:r=12:d=1', '-an', '-c:v', 'libx264',
                    '-pix_fmt', 'yuv420p', str(fixture / 'video.mp4')], check=True, timeout=15)
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                    'sine=frequency=800:sample_rate=44100:duration=1', '-c:a', 'aac',
                    str(fixture / 'audio.m4a')], check=True, timeout=15)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=directory))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        base = f'http://127.0.0.1:{server.server_port}'
        info = {'id': 'merged-fixture', 'title': 'Offline fixture', 'extractor': 'fixture',
                'duration': 1, 'formats': [
                    {'format_id': 'a', 'url': base + '/audio.m4a', 'ext': 'm4a', 'vcodec': 'none', 'acodec': 'mp4a'},
                    {'format_id': 'v', 'url': base + '/video.mp4', 'ext': 'mp4', 'vcodec': 'avc1', 'acodec': 'none',
                     'width': 320, 'height': 240},
                ]}
        info_path = fixture / 'info.json'
        info_path.write_text(json.dumps(info))
        ruby = '''
require_relative 'lib/telegram_instwitter_bot/config'
require_relative 'lib/telegram_instwitter_bot/runtime_helpers'
require_relative 'lib/telegram_instwitter_bot/ytdlp'
require_relative 'lib/telegram_instwitter_bot/media_jobs'
path = nil
begin
  path = download_video_with_ytdlp('https://example.invalid/fixture', 'yt_shorts_merge_',
    require_success: true, use_cookies: false, extra_args: ['--ignore-config', '--load-info-json', ARGV.fetch(0)])
  raise 'Missing video output' unless path && File.file?(path)
  streams = probe_media_streams(path).fetch('streams')
  raise 'Missing H.264 video' unless streams.any? { |s| s['codec_type'] == 'video' && s['codec_name'] == 'h264' }
  raise 'Lost audio during merge' unless streams.any? { |s| s['codec_type'] == 'audio' && s['codec_name'] == 'aac' }
  raise 'Not Telegram-ready MP4' unless telegram_ready_mp4?(path)
  puts 'PASS: real yt-dlp downloaded separate local tracks; Ruby returned H.264/AAC MP4'
ensure
  cleanup_media_path(path)
end
raise 'Temporary download directory leaked' if path && Dir.exist?(File.dirname(path))
'''
        env = dict(os.environ, TELEGRAM_BOT_TOKEN='000:offline-merge-test', VIDEO_FEED_CHANNEL='', YTDLP_FORMAT='')
        subprocess.run(['bundle', '_2.6.7_', 'exec', 'ruby', '-e', ruby, str(info_path)],
                       cwd=root, env=env, check=True, timeout=60)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
