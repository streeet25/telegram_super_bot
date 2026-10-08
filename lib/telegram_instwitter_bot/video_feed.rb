# frozen_string_literal: true

require 'json'
require 'tempfile'
require 'digest'
require 'securerandom'
require 'uri'
require 'thread'
require_relative 'video_fingerprint'

class VideoFeedError < StandardError; end

# File IDs and fingerprints only: no downloaded files, captions or chat titles.
# One process owns the store. A separate publisher uses its own HTTP connection.
class VideoFeed
  attr_reader :channel_id, :username

  def initialize(path:, api:, channel_id:, username:, clock: -> { Time.now.to_i })
    @path, @api, @channel_id, @username, @clock = File.expand_path(path), api, channel_id, username, clock
    @mutex, @publication_gate = Mutex.new, Mutex.new
    @confirmations = {}
    @data = if File.exist?(path)
              JSON.parse(File.read(path))
            else
              { 'version' => 1, 'channel_id' => channel_id, 'jobs' => [], 'banned' => [] }
            end
    unless @data['version'] == 1 && @data['channel_id'] == channel_id &&
           @data['jobs'].is_a?(Array) && @data['banned'].is_a?(Array)
      raise VideoFeedError, 'Invalid feed state or changed destination; refusing to reset history'
    end
    # Telegram has no idempotency key. An interrupted send may have succeeded:
    # keep it for manual review instead of risking an automatic duplicate.
    change do |data|
      data['preferences'] ||= {}
      data['privacy_versions'] ||= {}
      data['jobs'].each do |job|
        job['status'] = 'uncertain' if job['status'] == 'sending'
        job['status'] = 'delete_pending' if job['status'] == 'deleting'
      end
    end
  end

  # The token identifies only the submission that displayed the consent prompt.
  # It survives a restart but cannot revive submissions cancelled by an opt-out.
  def submission_context(submitter, private_chat:)
    change do |data|
      next nil if data['banned'].include?(submitter) || data['preferences'][submitter] == 'off'

      context = { submitter: submitter, private_chat: private_chat,
                  privacy_version: data['privacy_versions'].fetch(submitter, 0) }
      if private_chat && data['preferences'][submitter] != 'on'
        next nil if data['consent_requests'].size >= 1000

        token = SecureRandom.hex(12)
        data['consent_requests'][token] = {
          'submitter' => submitter, 'privacy_version' => context[:privacy_version],
          'expires_at' => @clock.call + 24 * 3600
        }
        context[:consent_request] = token
      end
      context
    end
  end

  def enqueue(file_id:, keys:, submitter:, private_chat: false, privacy_version: nil, consent_request: nil, visual: nil)
    return :ineligible if submitter.to_s.empty? || file_id.to_s.empty? || keys.empty?
    visual = nil unless VideoFingerprint.valid?(visual)

    change do |data|
      next :banned if data['banned'].include?(submitter)
      next :private if data['preferences'][submitter] == 'off'

      current_version = data['privacy_versions'].fetch(submitter, 0)
      waiting = false
      if consent_request
        request = data['consent_requests'][consent_request]
        next :private unless private_chat && request && request['submitter'] == submitter && request['privacy_version'] == privacy_version

        if request.key?('approved_version')
          next :private unless request['approved_version'] == current_version && data['preferences'][submitter] == 'on'
        else
          next :private unless request['privacy_version'] == current_version && data['preferences'][submitter].nil?

          waiting = true
        end
      else
        next :private if privacy_version && privacy_version != current_version
        next :private if private_chat && data['preferences'][submitter] != 'on'
      end
      next :duplicate if deduplicate!(data, keys, visual: visual, remember: !waiting)
      waiting_duplicate = data['jobs'].find do |job|
        job['status'] == 'awaiting_consent' && job['consent_request'] == consent_request &&
          (!(job['keys'] & keys).empty? || VideoFingerprint.match?(job['visual'], visual))
      end
      if waiting_duplicate
        waiting_duplicate['keys'] |= keys
        data['duplicates_skipped'] = data.fetch('duplicates_skipped', 0) + 1
        next :duplicate
      end
      next :full if data['jobs'].count { |job| %w[queued sending awaiting_consent].include?(job['status']) } >= 1000

      data['jobs'] << {
        'id' => SecureRandom.hex(12), 'file_id' => file_id, 'keys' => keys.uniq,
        'visual' => visual,
        'submitter' => submitter, 'status' => waiting ? 'awaiting_consent' : 'queued', 'attempts' => 0,
        'consent_request' => consent_request,
        'created_at' => @clock.call, 'next_at' => 0
      }
      waiting ? :awaiting_consent : :queued
    end
  end

  def preference(submitter)
    @mutex.synchronize { @data['preferences'][submitter] }
  end

  def privacy_version(submitter)
    @mutex.synchronize { @data['privacy_versions'].fetch(submitter, 0) }
  end

  def set_preference(submitter, enabled:, consent_request: nil)
    @publication_gate.synchronize do
      change do |data|
        request = data['consent_requests'][consent_request] if consent_request
        if consent_request && (!enabled || !request || request['submitter'] != submitter ||
           request.fetch('approved_version', request['privacy_version']) != data['privacy_versions'].fetch(submitter, 0))
          raise VideoFeedError, 'Этот запрос согласия уже не действует. Пришли ссылку ещё раз; настройка не изменена.'
        end
        choice = enabled ? 'on' : 'off'
        changed = data['preferences'][submitter] != choice
        if changed
          data['privacy_versions'][submitter] = data['privacy_versions'].fetch(submitter, 0) + 1
        end
        data['preferences'][submitter] = choice
        data['consent_requests'].delete_if do |token, item|
          item['submitter'] == submitter && token != consent_request && (changed || !enabled)
        end
        request['approved_version'] = data['privacy_versions'].fetch(submitter, 0) if request
        cancelled = 0
        data['jobs'].each do |job|
          next unless job['submitter'] == submitter && job['status'] == 'awaiting_consent'

          job['status'] = if data['banned'].include?(submitter)
                            'blocked'
                          elsif enabled && consent_request && job['consent_request'] == consent_request
                            deduplicate!(data, job['keys'], visual: job['visual']) ? 'duplicate' : 'queued'
                          else
                            cancelled += 1
                            'opted_out'
                          end
        end
        unless enabled
          data['jobs'].each do |job|
            next unless job['submitter'] == submitter && %w[queued failed].include?(job['status'])

            job['status'] = 'opted_out'
            cancelled += 1
          end
        end
        cancelled
      end
    end
  end

  def stats
    @mutex.synchronize do
      counts = @data['jobs'].group_by { |job| job['status'] }.transform_values(&:size)
      counts.merge('banned' => @data['banned'].size, 'duplicates_skipped' => @data.fetch('duplicates_skipped', 0))
    end
  end

  def moderate(action, message_id, actor_id:)
    @publication_gate.synchronize do
      change do |data|
        post = data['jobs'].find { |job| job['message_id'] == message_id }
        raise VideoFeedError, 'Не нашёл этот пост среди публикаций бота в ленте.' unless post

        submitter = post.fetch('submitter')
        case action
        when 'ban'
          data['banned'] |= [submitter]
          data['jobs'].each do |job|
            job['status'] = 'blocked' if job['submitter'] == submitter && %w[queued failed awaiting_consent].include?(job['status'])
          end
          data['consent_requests'].delete_if { |_, item| item['submitter'] == submitter }
          'Отправитель заблокирован в ленте. Новые и ожидающие видео публиковаться не будут. Старые посты пока сохранены.'
        when 'unban'
          data['banned'].delete(submitter)
          'Отправитель разблокирован. Будут приниматься новые ролики; прежняя заблокированная очередь не восстановлена.'
        when 'purge'
          unless data['banned'].include?(submitter)
            raise VideoFeedError, 'Сначала заблокируй отправителя командой /feed_ban со ссылкой на его пост.'
          end
          posts = data['jobs'].select do |job|
            job['submitter'] == submitter && %w[sent delete_failed].include?(job['status'])
          end
          recent, old = posts.partition { |job| @clock.call - job['sent_at'] < 48 * 3600 }
          raise VideoFeedError, "Нет доступных для удаления постов. Старше 48 часов: #{old.size}; их нужно удалить вручную." if recent.empty?

          token = SecureRandom.hex(6)
          @confirmations.delete_if { |_, value| value[:expires] < @clock.call }
          @confirmations[token] = { actor: actor_id, expires: @clock.call + 300, ids: recent.map { |job| job['id'] } }
          "Удалить #{recent.size} постов этого отправителя? Это нельзя отменить. Подтверди в течение 5 минут:\n/feed_confirm #{token}\nПостов старше 48 часов (удали вручную): #{old.size}."
        end
      end
    end
  end

  def confirm_purge(token, actor_id:)
    @publication_gate.synchronize do
      change do |data|
        confirmation = @confirmations[token]
        unless confirmation && confirmation[:actor] == actor_id && confirmation[:expires] >= @clock.call
          raise VideoFeedError, 'Подтверждение не найдено или истекло. Запроси удаление заново.'
        end
        count = 0
        data['jobs'].each do |job|
          next unless confirmation[:ids].include?(job['id']) && %w[sent delete_failed].include?(job['status'])

          job.merge!('status' => 'delete_pending', 'attempts' => 0, 'next_at' => 0)
          count += 1
        end
        @confirmations.delete(token)
        "В очередь удаления добавлено #{count} постов. Результат — /feed."
      end
    end
  end

  def retry_failed
    change do |data|
      count = 0
      data['jobs'].each do |job|
        next unless job['status'] == 'failed' && !data['banned'].include?(job['submitter']) && data['preferences'][job['submitter']] != 'off'

        job.merge!('status' => 'queued', 'attempts' => 0, 'next_at' => 0)
        count += 1
      end
      "Возвращено в очередь: #{count}. Неопределённые отправки не повторяются — сначала проверь канал вручную."
    end
  end

  # Serializes sends with bans: after a ban is acknowledged no queued item from
  # that submitter can reach Telegram. Enqueue never waits on network requests.
  def process_next
    @publication_gate.synchronize do
      job = change do |data|
        next nil if data.fetch('rate_limit_until', 0) > @clock.call

        selected = data['jobs'].find { |item| item['status'] == 'delete_pending' && item['next_at'] <= @clock.call }
        selected ||= data['jobs'].find do |item|
          item['status'] == 'queued' && item['next_at'] <= @clock.call && !data['banned'].include?(item['submitter']) && data['preferences'][item['submitter']] != 'off'
        end
        if selected
          if selected['status'] == 'queued' && deduplicate!(data, selected['keys'], visual: selected['visual'], candidate: selected)
            selected['status'] = 'duplicate'
            next selected.dup
          end
          selected['status'] = selected['status'] == 'delete_pending' ? 'deleting' : 'sending'
          selected['attempts'] += 1
          selected.dup
        end
      end
      return false unless job
      if job['status'] == 'duplicate'
        puts 'Video feed delivery: duplicate skipped'
        return true
      end

      deleting = job['status'] == 'deleting'
      begin
        if deleting
          @api.delete_message(chat_id: channel_id, message_id: job.fetch('message_id'))
          update_job(job['id'], 'status' => 'deleted')
        else
          # Never forward a source message or reuse its caption/attribution.
          response = @api.send_video(chat_id: channel_id, video: job.fetch('file_id'), supports_streaming: true)
          raise VideoFeedError, 'Missing Telegram message ID' unless response.respond_to?(:message_id) && response.message_id

          update_job(job['id'], 'status' => 'sent', 'message_id' => response.message_id, 'sent_at' => @clock.call)
        end
        puts "Video feed delivery: #{deleting ? 'deleted' : 'sent'}"
      rescue => e
        failure(job, e, deleting: deleting)
      end
      true
    end
  end

  private

  # Keep every known alias, not just the first URL/file ID. A later upload may
  # use a known alternative URL while receiving a new hash or Telegram ID.
  # Pending private submissions must not enrich a public record before consent.
  def deduplicate!(data, keys, visual: nil, remember: true, candidate: nil)
    candidate_index = data['jobs'].index(candidate) if candidate
    eligible = data['jobs'].each_with_index.map do |job, index|
      next if %w[blocked opted_out awaiting_consent duplicate].include?(job['status'])
      next if candidate && (job['id'] == candidate['id'] || (job['status'] == 'queued' && index > candidate_index))

      job
    end.compact
    matches = eligible.select { |job| !(job['keys'] & keys).empty? }
    if matches.empty? && visual
      match = eligible.find { |job| VideoFingerprint.match?(job['visual'], visual) }
      matches = [match] if match
    end
    return false if matches.empty?

    if remember
      aliases = (keys + matches.flat_map { |job| job['keys'] }).uniq
      matches.each do |job|
        job['keys'] = aliases.dup
        # Enrich old exact-only records when seen again, but never replace a
        # visual exemplar with each near-copy (that causes similarity drift).
        job['visual'] ||= visual
      end
    end
    data['duplicates_skipped'] = data.fetch('duplicates_skipped', 0) + 1
    true
  end

  def change
    @mutex.synchronize do
      draft = Marshal.load(Marshal.dump(@data))
      draft['consent_requests'] ||= {}
      draft['consent_requests'].delete_if { |_, request| request['expires_at'] <= @clock.call }
      # Unapproved, expired file IDs need not be retained or deduplicated.
      draft['jobs'].reject! { |job| job['status'] == 'awaiting_consent' && !draft['consent_requests'].key?(job['consent_request']) }
      result = yield draft
      if draft != @data || !File.exist?(@path)
        Tempfile.create(['.video-feed-', '.json'], File.dirname(File.expand_path(@path))) do |file|
          file.chmod(0600)
          file.write(JSON.generate(draft))
          file.flush
          file.fsync
          File.rename(file.path, @path)
        end
        @data = draft
      end
      result
    end
  end

  def update_job(id, attributes)
    change { |data| data['jobs'].find { |job| job['id'] == id }.merge!(attributes) }
  end

  def failure(job, error, deleting:)
    response = begin
      error.respond_to?(:data) ? error.data : nil
    rescue
      nil
    end
    response = {} unless response.is_a?(Hash)
    code = (response['error_code'] || response[:error_code]).to_i
    description = (response['description'] || response[:description]).to_s
    parameters = response['parameters'] || response[:parameters] || {}
    retry_after = (parameters['retry_after'] || parameters[:retry_after]).to_i
    if deleting && code == 400 && description.include?('message to delete not found')
      attributes = { 'status' => 'deleted' }
    elsif (deleting || code == 429 || code >= 500) && job['attempts'] < 8 && ![400, 403].include?(code)
      attributes = { 'status' => deleting ? 'delete_pending' : 'queued',
                     'next_at' => @clock.call + [retry_after, 2**job['attempts'] * 5].max }
    else
      attributes = { 'status' => deleting ? 'delete_failed' : (code.zero? ? 'uncertain' : 'failed') }
    end
    change do |data|
      data['jobs'].find { |item| item['id'] == job['id'] }.merge!(attributes.merge('error_class' => error.class.name, 'error_code' => code))
      data['rate_limit_until'] = @clock.call + [retry_after, 10].max if code == 429
    end
    puts "Video feed error: #{error.class} code=#{code} status=#{attributes['status']}"
  end
end

def video_feed
  @video_feed
end

def start_video_feed(bot)
  target = ENV['VIDEO_FEED_CHANNEL'].to_s.strip
  return if target.empty?

  chat = bot.api.get_chat(chat_id: target)
  raise VideoFeedError, 'Feed destination must be a channel' unless chat.type == 'channel'

  member = bot.api.get_chat_member(chat_id: chat.id, user_id: bot.api.get_me.id)
  unless member.status == 'administrator' && member.can_post_messages && member.can_delete_messages
    raise VideoFeedError, 'Feed bot needs publish and delete administrator permissions'
  end
  # Separate connection from polling/download replies; bound publication time.
  api = Telegram::Bot::Api.new(TOKEN)
  api.connection.options.timeout = 20
  api.connection.options.open_timeout = 5
  @video_feed = VideoFeed.new(path: 'video_feed.json', api: api, channel_id: chat.id, username: chat.username)
  worker = Thread.new do
    loop do
      begin
        @video_feed.process_next
      rescue => e
        puts "Video feed worker error: #{e.class}"
      end
      sleep 2
    end
  end
  puts 'Video feed enabled: all groups, private chats with consent, anonymous publications'
  worker
rescue => e
  @video_feed = nil
  puts "Video feed disabled: #{e.class}"
end

def video_feed_submitter(message)
  return nil if message.respond_to?(:has_protected_content) && message.has_protected_content
  return nil if message.respond_to?(:is_automatic_forward) && message.is_automatic_forward
  return nil if video_feed && message.chat.id == video_feed.channel_id

  sender_chat = message.respond_to?(:sender_chat) ? message.sender_chat : nil
  # Anonymous admins/channel senders cannot be matched to individual privacy
  # preferences or banned reliably; do not bypass a person's opt-out this way.
  return nil if sender_chat

  sender = message.from
  return nil unless sender && !sender.is_bot

  "user:#{sender.id}"
end

def video_feed_keys(link, path)
  uri = URI.parse(link.to_s)
  host = uri.host.to_s.downcase.sub(/\A(?:www|m)\./, '')
  canonical = if %w[x.com twitter.com].include?(host) && (match = uri.path.match(%r{/status/(\d+)}))
                "x:#{match[1]}"
              elsif host == 'instagram.com' && (match = uri.path.match(%r{\A/(?:reel|reels|p|tv)/([^/]+)}))
                "ig:#{match[1]}"
              elsif host == 'youtube.com' && (match = uri.path.match(%r{\A/shorts/([^/]+)}))
                "yt:#{match[1]}"
              else
                "#{host}#{uri.path}"
              end
  fingerprints = ["sha256:#{Digest::SHA256.file(path).hexdigest}"]
  fingerprints << "url:#{Digest::SHA256.hexdigest(canonical)}" unless host.empty?
  fingerprints
rescue => e
  puts "Video feed fingerprint error: #{e.class}"
  []
end

def video_feed_visuals(paths, submitter:)
  return [] unless video_feed && video_feed.preference(submitter) != 'off'
  return [] if ENV['VIDEO_FEED_VISUAL_DEDUP'] == '0'

  deadline = VideoFingerprint.monotonic + 16
  paths.map do |path|
    VideoFingerprint.extract(path, runner: method(:run_command_with_limits),
                             timeout: [8, deadline - VideoFingerprint.monotonic].min)
  end
rescue => e
  puts "Video feed visual analysis skipped: #{e.class}"
  []
end

def enqueue_video_feed(messages, submitter:, keys:, private_chat: false, privacy_version: nil, consent_request: nil, visuals: [])
  return unless video_feed && submitter

  Array(messages).each_with_index do |message, index|
    video = message.respond_to?(:video) ? message.video : nil
    next unless video

    fingerprints = Array(keys[index]).dup
    fingerprints << "telegram:#{video.file_unique_id}" unless video.file_unique_id.to_s.empty?
    result = video_feed.enqueue(file_id: video.file_id, keys: fingerprints, submitter: submitter,
                               private_chat: private_chat, privacy_version: privacy_version, consent_request: consent_request,
                               visual: visuals[index])
    puts "Video feed enqueue: #{result}"
  end
rescue => e
  # Channel errors must never turn a successfully delivered user video into an error.
  puts "Video feed enqueue error: #{e.class}"
end

def prepare_video_feed_submission(bot, message)
  return nil unless video_feed

  submitter = video_feed_submitter(message)
  return nil unless submitter

  context = video_feed.submission_context(submitter, private_chat: message.chat.type == 'private')
  if context && context[:consent_request]
    send_video_feed_privacy(bot, message.chat.id, message.from.id, consent_request: context[:consent_request])
  end
  context
rescue => e
  puts "Video feed submission preparation error: #{e.class}"
  nil
end

def send_video_feed_privacy(bot, chat_id, user_id, consent_request: nil)
  return unless video_feed

  preference = video_feed.preference("user:#{user_id}")
  status = case preference
           when 'on' then 'Сейчас публикация твоих новых роликов включена.'
           when 'off' then 'Сейчас публикация твоих роликов отключена и в личке, и в группах.'
           else 'Видео из лички не публикуются без твоего согласия. Видео из групп участвуют в ленте; можно отключить все свои публикации.'
           end
  scope = if consent_request
            'Нажав «Публиковать анонимно», ты разрешаешь публикацию видео из только что присланного сообщения и следующих роликов. Если скачивание ещё идёт, видео попадёт в канал после успешной загрузки. Этот запрос действует 24 часа.'
          else
            'Выбор действует на будущие видео. Для публикации уже присланного ролика нажми согласие в запросе под его ссылкой.'
          end
  text = "ПОБОЧКА — общая публичная видеолента: https://t.me/#{video_feed.username}\n\n" \
    "Успешно скачанные по ссылкам видео могут попадать туда без твоего имени, подписи и названия чата. Само содержимое ролика не скрывается.\n\n#{status}\n\n" \
    "#{scope}\n\nОтключение также отменяет ожидающие публикации, но не удаляет уже вышедшие посты. Скачивание работает при любом выборе. Настройку можно изменить: /privacy."
  keyboard = { inline_keyboard: [
    [{ text: 'Не публиковать в Побочке', callback_data: 'feed_privacy:off' }],
    [{ text: 'Публиковать анонимно', callback_data: ['feed_privacy:on', consent_request].compact.join(':') }]
  ] }
  bot.api.send_message(chat_id: chat_id, text: text, reply_markup: JSON.generate(keyboard))
rescue => e
  puts "Video feed privacy prompt error: #{e.class}"
end

def handle_video_feed_privacy_command(bot, message, text)
  return false unless text.to_s.strip.match?(%r{\A/privacy(?:@\w+)?\z}i)
  return true unless message.chat.type == 'private' && message.from && !message.from.is_bot

  if video_feed
    send_video_feed_privacy(bot, message.chat.id, message.from.id)
  else
    safe_send_message(bot, message.chat.id, 'Лента сейчас отключена. Видео не публикуются.')
  end
  true
end

def handle_video_feed_privacy_callback(bot, callback)
  match = callback.data.to_s.match(/\Afeed_privacy:(on|off)(?::([a-f0-9]{24}))?\z/)
  return false unless match

  message = callback.message
  unless video_feed && message && message.chat.type == 'private' && callback.from &&
         !callback.from.is_bot && callback.from.id == message.chat.id
    answer_video_feed_callback(bot, callback, 'Открой /privacy в личке с ботом.')
    return true
  end
  enabled = match[1] == 'on'
  consent_request = match[2]
  count = video_feed.set_preference("user:#{callback.from.id}", enabled: enabled, consent_request: consent_request)
  answer_video_feed_callback(bot, callback, enabled ? 'Публикация включена' : 'Публикация отключена')
  text = enabled ? (consent_request ? 'Согласие принято для этого сообщения и следующих роликов. Успешно загруженные видео из него попадут в Побочку без повторной отправки ссылки, если их ещё нет в ленте.' :
    'Новые видео будут публиковаться анонимно в Побочке. Старую историю не публикуем.') :
    "Твои видео больше не попадут в Побочку ни из лички, ни из групп. Отменено ожидающих публикаций: #{count}. Уже вышедшие посты не удалены."
  safe_send_message(bot, message.chat.id, "#{text}\nИзменить выбор: /privacy.")
  true
rescue VideoFeedError => e
  answer_video_feed_callback(bot, callback, 'Запрос согласия уже не действует')
  safe_send_message(bot, message.chat.id, e.message)
  true
rescue => e
  puts "Video feed privacy error: #{e.class}"
  # Do not acknowledge a preference change that failed to persist.
  answer_video_feed_callback(bot, callback, 'Не удалось сохранить настройку. Попробуй ещё раз.')
  true
end

def answer_video_feed_callback(bot, callback, text)
  bot.api.answer_callback_query(callback_query_id: callback.id, text: text)
rescue => e
  puts "Video feed callback acknowledgement error: #{e.class}"
end

def handle_video_feed_command(bot, message, text)
  match = text.to_s.strip.match(%r{\A/feed(?:_(ban|unban|purge|confirm|retry_failed))?(?:@\w+)?(?:\s+(.*))?\z}i)
  return false unless match
  return true unless message.chat.type == 'private' && message.from && !message.from.is_bot

  feed = video_feed
  raise VideoFeedError, 'Лента сейчас отключена.' unless feed

  member = bot.api.get_chat_member(chat_id: feed.channel_id, user_id: message.from.id)
  unless member.status == 'creator' || (member.status == 'administrator' && member.can_delete_messages)
    raise VideoFeedError, 'Управление лентой доступно только владельцу канала и администраторам с правом удаления постов.'
  end
  action, argument = match[1]&.downcase, match[2].to_s.strip
  response = case action
             when nil
               counts = feed.stats
               "Лента @#{feed.username}\nВ очереди: #{counts.fetch('queued', 0)}; опубликовано: #{counts.fetch('sent', 0)}; заблокировано отправителей: #{counts['banned']}.\n" \
                 "Ожидают согласия: #{counts.fetch('awaiting_consent', 0)}.\n" \
                 "Повторов отсеяно: #{counts['duplicates_skipped']}.\n" \
                 "Ошибок публикации: #{counts.fetch('failed', 0)}; неопределённых отправок: #{counts.fetch('uncertain', 0)}.\n" \
                 "Удалено: #{counts.fetch('deleted', 0)}; ожидают удаления: #{counts.fetch('delete_pending', 0)}; ошибок удаления: #{counts.fetch('delete_failed', 0)}.\n\n" \
                 "/feed_ban ссылка_на_пост — заблокировать отправителя\n/feed_unban ссылка_на_пост — разблокировать\n/feed_purge ссылка_на_пост — удалить его посты после подтверждения (до 48 часов)\n/feed_retry_failed — повторить отклонённые Telegram публикации\nВсе команды — только здесь, в личке."
             when 'confirm' then feed.confirm_purge(argument, actor_id: message.from.id)
             when 'retry_failed' then feed.retry_failed
             else
               url = argument.match(%r{\Ahttps://t\.me/#{Regexp.escape(feed.username.to_s)}/(\d+)(?:\?[^\s]*)?\z}i)
               raise VideoFeedError, "Укажи ссылку на пост этой ленты: /feed_#{action} https://t.me/#{feed.username}/123" unless url

               feed.moderate(action, url[1].to_i, actor_id: message.from.id)
             end
  safe_send_message(bot, message.chat.id, response)
  true
rescue VideoFeedError => e
  safe_send_message(bot, message.chat.id, e.message)
  true
rescue => e
  puts "Video feed moderation error: #{e.class}"
  safe_send_message(bot, message.chat.id, 'Не удалось проверить права или выполнить команду ленты. Попробуй позже.')
  true
end
