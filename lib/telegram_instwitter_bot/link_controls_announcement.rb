# frozen_string_literal: true

require 'json'
require 'tempfile'

# An operator-invoked, one-time private announcement. Never loaded by bot.rb.
class LinkControlsAnnouncement
  ID = 'link-controls-20261009'

  def self.text(language)
    return <<~TEXT if language == 'en'
      VideoMorph update: control each video's publication in ПОБОЧКА 🎬

      + LINK — download and publish just this video anonymously in https://t.me/pobo4ka_ink, even if your general publication setting is off.
      - LINK — download without publishing it to the channel.
      LINK without a sign — use your current setting; private-chat videos still require consent.

      Put the sign before each link on the same line (with or without a space). For several links, you can choose separately for each one.

      These signs do not change your setting for future videos. /privacy controls the general setting. Turning publication off again also cancels pending one-off publications. Duplicate protection still applies.
    TEXT

    <<~TEXT
      Апдейт VideoMorph: теперь ты решаешь, какой ролик попадёт в ПОБОЧКУ 🎬

      + ССЫЛКА — скачать и анонимно опубликовать только этот ролик в https://t.me/pobo4ka_ink, даже если общая публикация отключена.
      - ССЫЛКА — скачать без публикации в канале.
      ССЫЛКА без знака — по твоей текущей настройке; для видео из лички по-прежнему нужно согласие.

      Ставь знак перед каждой ссылкой на той же строке, с пробелом или без. Если ссылок несколько, можно выбрать отдельно для каждой.

      Общая настройка для следующих видео не меняется. Изменить её можно через /privacy. Повторное отключение отменяет и ожидающие разовые публикации. Защита от повторов продолжает работать.
    TEXT
  end

  def self.recipients(directory)
    read = lambda do |name|
      path = File.join(directory, name)
      File.exist?(path) ? JSON.parse(File.read(path)) : {}
    end
    languages = read.call('user_languages.json')
    feed = read.call('video_feed.json')
    ids = languages.keys + read.call('user_locations.json').keys + read.call('media_history.json').keys
    ids += read.call('photo_history.json').keys.map { |scope| scope.split(':').first }
    users = feed.fetch('preferences', {}).keys + feed.fetch('jobs', []).map { |job| job['submitter'] } +
      feed.fetch('consent_requests', {}).values.map { |request| request['submitter'] }
    ids += users.map { |user| user.to_s[/\Auser:(\d+)\z/, 1] }
    # Only individual IDs, never groups/channels. Telegram itself rejects DMs
    # when someone has never opened the bot or has blocked it.
    ids.compact.map(&:to_s).select { |id| id.match?(/\A[1-9]\d*\z/) }.uniq.sort.to_h do |id|
      [id, languages[id] == 'en' ? 'en' : 'ru']
    end
  end

  def initialize(path:, api:, clock: -> { Time.now.to_i }, pause: -> { sleep 0.4 })
    @path, @api, @clock, @pause = path, api, clock, pause
  end

  def run(recipients)
    File.open("#{@path}.lock", File::RDWR | File::CREAT, 0600) do |lock|
      raise 'Announcement is already running' unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      state = if File.exist?(@path)
                JSON.parse(File.read(@path))
              else
                { 'id' => ID, 'recipients' => recipients.map { |id, lang| { 'chat_id' => id, 'language' => lang, 'status' => 'pending' } } }
              end
      raise 'Wrong announcement state' unless state['id'] == ID && state['recipients'].is_a?(Array)
      unless state['recipients'].all? { |item| item.is_a?(Hash) && item['chat_id'].to_s.match?(/\A[1-9]\d*\z/) }
        raise 'Announcement recipients must be individual users, never groups or channels'
      end

      state['recipients'].each { |item| item['status'] = 'uncertain' if item['status'] == 'sending' }
      save(state)
      state['recipients'].each do |item|
        next unless %w[pending rate_limited].include?(item['status'])
        next if state.fetch('retry_at', 0) > @clock.call

        item['status'] = 'sending'
        save(state) # Crash/ambiguous response must never cause an automatic resend.
        begin
          response = @api.send_message(chat_id: Integer(item.fetch('chat_id')), text: self.class.text(item['language']),
                                       disable_web_page_preview: true)
          raise 'Missing message ID' unless response.respond_to?(:message_id) && response.message_id

          item.merge!('status' => 'sent', 'message_id' => response.message_id, 'sent_at' => @clock.call)
        rescue StandardError => error
          data = error.respond_to?(:data) && error.data.is_a?(Hash) ? error.data : {}
          code = (data['error_code'] || data[:error_code]).to_i
          item['status'] = if code == 429
                             parameters = data['parameters'] || data[:parameters] || {}
                             delay = (parameters['retry_after'] || parameters[:retry_after]).to_i
                             state['retry_at'] = @clock.call + [delay, 1].max
                             'rate_limited'
                           elsif [400, 403].include?(code)
                             'unavailable'
                           else
                             'uncertain'
                           end
          item['error_code'] = code
        end
        save(state)
        @pause.call
      end
      state['recipients'].group_by { |item| item['status'] }.transform_values(&:size)
    end
  end

  private

  def save(state)
    Tempfile.create(['.announcement-', '.json'], File.dirname(@path)) do |file|
      file.chmod(0600)
      file.write(JSON.generate(state))
      file.flush
      file.fsync
      File.rename(file.path, @path)
    end
  end
end
