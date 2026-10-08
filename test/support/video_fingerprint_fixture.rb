# frozen_string_literal: true

module VideoFingerprintFixture
  def visual_fixture(seed = 42)
    random = Random.new(seed)
    frames = Array.new(24) { format('%032x', random.rand(1 << 128)) + '80908030' }
    { 'v' => 1, 'duration_ms' => 6000, 'aspect' => 1333, 'frames' => Array.new(3) { frames.dup } }
  end

  def altered_visual(original, mask)
    copy = Marshal.load(Marshal.dump(original))
    copy['frames'].each do |frames|
      frames.map! { |frame| format('%032x', frame[0, 32].to_i(16) ^ mask) + frame[32, 8] }
    end
    copy
  end
end
