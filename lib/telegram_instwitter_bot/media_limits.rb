# frozen_string_literal: true

module TelegramMediaLimits
  # Public Bot API accepts 50 MB uploads. Leave headroom for multipart framing.
  SAFE_UPLOAD_MB = 49
  SAFE_UPLOAD_BYTES = SAFE_UPLOAD_MB * 1024 * 1024

  def self.upload_megabytes(value)
    requested = value.to_i
    requested.positive? ? [requested, SAFE_UPLOAD_MB].min : SAFE_UPLOAD_MB
  end

  def self.upload_bytes(value)
    requested = value.to_i
    requested.positive? ? [requested, SAFE_UPLOAD_BYTES].min : SAFE_UPLOAD_BYTES
  end
end
