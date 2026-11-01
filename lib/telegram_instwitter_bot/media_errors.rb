# frozen_string_literal: true

class MediaDownloadBlocked < StandardError; end
class MediaWithoutVideo < StandardError; end

# Extraction/network failures may benefit from an authenticated retry. Safety
# limits and local failures remain MediaDownloadBlocked and must not be retried.
class YtdlpExtractionFailed < MediaDownloadBlocked
  attr_reader :reason

  def initialize(message, reason: nil)
    @reason = reason
    super(message)
  end
end
