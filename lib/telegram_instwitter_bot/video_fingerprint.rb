# frozen_string_literal: true

require 'json'

# A conservative, versioned visual signature, not a general video classifier.
# Only tiny hashes/colour summaries survive; frames and source paths do not.
module VideoFingerprint
  VERSION = 1
  FRAMES = 24
  SIZE = 48
  FRAME_BYTES = SIZE * SIZE * 3
  CROPS = [0, 3, 6].freeze
  MIN_CONTRAST = 18
  MAX_DISTANCE = 12
  BIT_COUNTS = Array.new(256) { |value| value.to_s(2).count('1') }.freeze

  def self.monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.executable(name)
    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }
       .find { |path| File.file?(path) && File.executable?(path) }
  end

  def self.extract(path, runner:, timeout: 8)
    deadline = monotonic + timeout
    ffmpeg, ffprobe = executable('ffmpeg'), executable('ffprobe')
    return nil unless ffmpeg && ffprobe && timeout > 0.25 && File.file?(path)

    probe = runner.call(ffprobe, '-v', 'error', '-select_streams', 'v:0',
                        '-show_entries', 'stream=width,height:format=duration', '-of', 'json', path,
                        timeout_seconds: [2, timeout].min)
    return nil unless successful?(probe)

    info = JSON.parse(probe.stdout)
    stream = info.fetch('streams').first || {}
    duration = Float(info.fetch('format').fetch('duration'))
    width, height = stream.values_at('width', 'height')
    return nil unless duration.finite? && duration.between?(1, 600) && width.to_i > 0 && height.to_i > 0

    remaining = deadline - monotonic
    return nil if remaining <= 0.25

    # Normalized timeline: all sections must agree, not only the opening shot.
    # -frames:v and fixed raw frame size also bound the stdout buffer (~162 KiB).
    result = runner.call(ffmpeg, '-nostdin', '-v', 'error', '-threads', '1',
                         '-noautorotate', '-i', path, '-map', '0:v:0', '-an', '-sn', '-dn',
                         '-filter_threads', '1', '-vf',
                         "fps=#{FRAMES / duration}:start_time=0,scale=#{SIZE}:#{SIZE}:flags=area",
                         '-frames:v', FRAMES.to_s, '-threads', '1', '-pix_fmt', 'rgb24',
                         '-f', 'rawvideo', 'pipe:1', timeout_seconds: remaining)
    return nil unless successful?(result) && result.stdout.bytesize == FRAME_BYTES * FRAMES

    frames = FRAMES.times.map { |i| result.stdout.byteslice(i * FRAME_BYTES, FRAME_BYTES).bytes }
    variants = CROPS.map { |crop| frames.map { |frame| summarize(frame, crop) } }
    fingerprint = { 'v' => VERSION, 'duration_ms' => (duration * 1000).round,
                    'aspect' => (1000.0 * width / height).round, 'frames' => variants }
    # Still images, black screens and low-motion templates are too ambiguous.
    informative?(decode(variants.first)) ? fingerprint : nil
  rescue StandardError => error
    puts "Video feed visual fingerprint skipped: #{error.class}"
    nil
  end

  def self.successful?(result)
    result && !result.timed_out && !result.limit_exceeded && result.status && result.status.success?
  end

  def self.summarize(pixels, crop)
    side = SIZE - crop * 2
    grid = []
    colours = [0, 0, 0]
    9.times do |gy|
      9.times do |gx|
        total, count = 0, 0
        (crop + gy * side / 9...crop + (gy + 1) * side / 9).each do |y|
          (crop + gx * side / 9...crop + (gx + 1) * side / 9).each do |x|
            r, g, b = pixels.slice((y * SIZE + x) * 3, 3)
            total += (77 * r + 150 * g + 29 * b) / 256.0
            colours[0] += r
            colours[1] += g
            colours[2] += b
            count += 1
          end
        end
        grid << total / count
      end
    end
    hash = 0
    8.times do |y|
      8.times do |x|
        hash = (hash << 1) | (grid[y * 9 + x] > grid[y * 9 + x + 1] ? 1 : 0)
        hash = (hash << 1) | (grid[y * 9 + x] > grid[(y + 1) * 9 + x] ? 1 : 0)
      end
    end
    average = grid.sum / grid.size
    contrast = Math.sqrt(grid.sum { |value| (value - average)**2 } / grid.size).round
    format('%032x', hash) + (colours.map { |value| (value.to_f / side**2).round } + [contrast])
      .map { |value| format('%02x', value) }.join
  end

  def self.valid?(value)
    value.is_a?(Hash) && value['v'] == VERSION &&
      value['duration_ms'].is_a?(Integer) && value['duration_ms'].between?(1000, 600_000) &&
      value['aspect'].is_a?(Integer) && value['aspect'].between?(10, 100_000) &&
      value['frames'].is_a?(Array) && value['frames'].size == CROPS.size &&
      value['frames'].all? do |variant|
        variant.is_a?(Array) && variant.size == FRAMES &&
          variant.all? { |frame| frame.is_a?(String) && frame.match?(/\A[0-9a-f]{40}\z/) }
      end
  end

  def self.decode(frames)
    frames.map { |frame| [frame[0, 32].to_i(16), *frame[32, 8].scan(/../).map { |byte| byte.to_i(16) }] }
  end

  def self.distance(left, right)
    value, count = left ^ right, 0
    while value > 0
      count += BIT_COUNTS[value & 255]
      value >>= 8
    end
    count
  end

  def self.informative?(frames)
    useful = frames.select { |frame| frame[4] >= MIN_CONTRAST }
    return false if useful.size < 22

    distinct = []
    useful.each do |frame|
      distinct << frame if distinct.all? { |other| distance(frame[0], other[0]) >= 10 }
      return true if distinct.size >= 6
    end
    false
  end

  def self.frame_match?(left, right)
    left[4] >= MIN_CONTRAST && right[4] >= MIN_CONTRAST &&
      (1..3).sum { |i| (left[i] - right[i]).abs } <= 45 &&
      distance(left[0], right[0]) <= MAX_DISTANCE
  end

  def self.match?(left, right)
    return false unless valid?(left) && valid?(right)

    shorter = [left['duration_ms'], right['duration_ms']].min
    return false if (left['duration_ms'] - right['duration_ms']).abs > [[shorter * 0.03, 150].max, 1000].min
    return false if (left['aspect'] - right['aspect']).abs > [left['aspect'], right['aspect']].min * 0.04

    a, b = [left, right].map { |value| value['frames'].map { |frames| decode(frames) } }
    return false unless informative?(a.first) && informative?(b.first)

    a.any? do |variant_a|
      b.any? do |variant_b|
        # One spatial transform for the entire video. Never mix crop variants
        # frame-by-frame, reorder shots, or match only a shared intro.
        matches = FRAMES.times.map { |i| frame_match?(variant_a[i], variant_b[i]) }
        matches.count(true) >= 22 && matches.first(3).any? && matches.last(3).any? &&
          informative?(variant_a) && informative?(variant_b)
      end
    end
  end
end
