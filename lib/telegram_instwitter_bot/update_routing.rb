# frozen_string_literal: true

require 'json'
require 'telegram/bot'

# Client#listen normally unwraps all Update variants into their payloads. In
# particular, an edited_message becomes indistinguishable from a new Message.
# Route by the envelope before that happens: metadata/reaction edits must not
# re-run downloads, photo commands, reminders or publication consent prompts.
class TelegramUpdateClient < Telegram::Bot::Client
  ALLOWED_UPDATES = %w[message channel_post business_message callback_query].freeze

  def initialize(token, options = {})
    super(token, options.merge(allowed_updates: JSON.generate(ALLOWED_UPDATES)))
  end

  def handle_update(update)
    return super if ALLOWED_UPDATES.any? { |kind| update.public_send(kind) }

    # The server-side filter does not remove updates already pending when it
    # changes. Acknowledge those locally as well, even if edit_date is absent.
    options[:offset] = update.update_id.next
    nil
  end
end
