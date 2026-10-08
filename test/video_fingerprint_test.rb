# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'digest'
require_relative '../lib/telegram_instwitter_bot/runtime_helpers'
require_relative '../lib/telegram_instwitter_bot/video_fingerprint'
require_relative 'support/video_fingerprint_fixture'

CommandResult = Struct.new(:stdout, :stderr, :status, :timed_out, :limit_exceeded, keyword_init: true) unless defined?(CommandResult)

class VideoFingerprintTest < Minitest::Test
  include VideoFingerprintFixture

  def test_tolerates_small_visual_changes
    original = visual_fixture
    assert VideoFingerprint.match?(original, altered_visual(original, (1 << 10) - 1))
    refute VideoFingerprint.match?(original, visual_fixture(43))
  end

  def test_requires_entire_timeline_in_order
    original = visual_fixture
    shared_intro = visual_fixture(43)
    shared_intro['frames'].each_with_index { |frames, i| frames[0, 12] = original['frames'][i].first(12) }
    refute VideoFingerprint.match?(original, shared_intro)
    reversed = Marshal.load(Marshal.dump(original))
    reversed['frames'].each(&:reverse!)
    refute VideoFingerprint.match?(original, reversed)
  end

  def test_rejects_static_low_contrast_and_different_duration
    original = visual_fixture
    still = Marshal.load(Marshal.dump(original))
    still['frames'].each { |frames| frames.fill(frames.first) }
    refute VideoFingerprint.match?(still, still)
    dark = Marshal.load(Marshal.dump(original))
    dark['frames'].each { |frames| frames.map! { |frame| frame[0, 38] + '08' } }
    refute VideoFingerprint.match?(dark, dark)
    longer = Marshal.load(Marshal.dump(original)).merge('duration_ms' => 10_000)
    refute VideoFingerprint.match?(original, longer)
  end

  def test_rejects_malformed_or_future_signatures
    original = visual_fixture
    [nil, {}, 'broken', original.merge('v' => 2), original.merge('frames' => ['bad'])].each do |invalid|
      refute VideoFingerprint.match?(original, invalid)
    end
  end

  def test_fails_open_on_timeout_missing_tools_or_invalid_video
    Dir.mktmpdir('visual-invalid-') do |dir|
      path = File.join(dir, 'bad.mp4')
      File.write(path, 'not a video')
      runner = ->(*_args, **_options) { raise 'runner should not be called' }
      assert_nil VideoFingerprint.extract(path, runner: runner, timeout: 0)
      VideoFingerprint.stub(:executable, nil) { assert_nil VideoFingerprint.extract(path, runner: runner) }
      timeout_runner = ->(*_args, **_options) { CommandResult.new(timed_out: true) }
      assert_nil VideoFingerprint.extract(path, runner: timeout_runner)
      assert_nil VideoFingerprint.extract(path, runner: method(:run_command_with_limits))
    end
  end

  def test_incomplete_or_timed_out_decoder_output_is_never_indexed
    Dir.mktmpdir('visual-decoder-') do |dir|
      path = File.join(dir, 'video.mp4')
      File.write(path, 'fixture')
      success = Struct.new(:success?).new(true)
      [CommandResult.new(timed_out: true),
       CommandResult.new(status: success, stdout: 'partial frame')].each do |decode_result|
        calls = []
        runner = lambda do |*args, **options|
          calls << [args, options]
          if calls.size == 1
            CommandResult.new(status: success, stdout: JSON.generate(
              streams: [{ width: 320, height: 240 }], format: { duration: '6' }))
          else
            decode_result
          end
        end
        assert_nil VideoFingerprint.extract(path, runner: runner)
        assert_equal 2, calls.size
        assert_operator calls.last[1][:timeout_seconds], :<=, 8
        assert_includes calls.last[0], '-frames:v'
      end
    end
  end

  def test_real_reencoding_resize_and_crop_without_matching_different_ending
    # This must run in the release container too; no external media/network.
    ffmpeg = VideoFingerprint.executable('ffmpeg')
    refute_nil ffmpeg, 'ffmpeg is required for the visual dedup release test'
    Dir.mktmpdir('visual-fixtures-') do |dir|
      base = File.join(dir, 'base.mp4')
      encode(ffmpeg, '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=12:duration=6',
             '-vf', 'rotate=0.65*t:fillcolor=gray', base)
      original = extract(base)
      refute_nil original, 'fixture must have enough visual variation'
      assert_operator JSON.generate(original).bytesize, :<, 3500

      { 'reencode' => 'scale=160:120', 'crop' => 'crop=280:210:20:15,scale=224:168' }.each do |name, filter|
        variant = File.join(dir, "#{name}.mp4")
        encode(ffmpeg, '-i', base, '-vf', filter, '-crf', '32', variant)
        signature = extract(variant)
        refute_nil signature
        refute_equal Digest::SHA256.file(base).hexdigest, Digest::SHA256.file(variant).hexdigest
        assert VideoFingerprint.match?(original, signature), "missed #{name}"
        assert VideoFingerprint.match?(signature, original), "asymmetric #{name}"
      end

      other = File.join(dir, 'other.mp4')
      encode(ffmpeg, '-i', base, '-vf', "hflip=enable='gte(t,2)'", other)
      refute VideoFingerprint.match?(original, extract(other)), 'shared intro is not a duplicate'
      still = File.join(dir, 'still.mp4')
      encode(ffmpeg, '-f', 'lavfi', '-i', 'smptebars=size=160x120:rate=12:duration=6', still)
      assert_nil extract(still), 'static templates should use exact identity only'
    end
  end

  def extract(path)
    VideoFingerprint.extract(path, runner: method(:run_command_with_limits))
  end

  def encode(ffmpeg, *args)
    output = args.pop
    _, errors, status = Open3.capture3(ffmpeg, '-nostdin', '-v', 'error', '-threads', '1',
                                      *args, '-an', '-c:v', 'libx264', '-threads', '1',
                                      '-pix_fmt', 'yuv420p', '-y', output)
    assert status.success?, errors
  end
end
