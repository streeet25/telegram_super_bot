#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/telegram_instwitter_bot/config'
require_relative '../lib/telegram_instwitter_bot/link_controls_announcement'

STDOUT.sync = true
recipients = LinkControlsAnnouncement.recipients(Dir.pwd)
puts JSON.generate(eligible_private_recipients: recipients.size, send_requested: ARGV == ['--send'])
exit unless ARGV == ['--send']

api = Telegram::Bot::Api.new(TOKEN)
api.connection.options.timeout = 15
api.connection.options.open_timeout = 5
announcement = LinkControlsAnnouncement.new(path: File.join(Dir.pwd, 'link_controls_announcement.json'), api: api)
puts JSON.generate(announcement.run(recipients))
