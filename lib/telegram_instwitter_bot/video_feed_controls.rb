# frozen_string_literal: true

class VideoFeed
  CONTROL_TTL = 24 * 3600
  CONTROL_DELAY = 30

  def control_context(submitter, chat_id:, choice:)
    @mutex.synchronize do
      next nil if @data['banned'].include?(submitter)

      { submitter: submitter, chat_id: chat_id, choice: choice }
    end
  end

  # Every delivered clip owns its own control record, including private/minus
  # clips. Unapproved records never participate in public deduplication.
  def register_control(file_id:, keys:, visual:, control:, context:, video_message_id:, caption:)
    change do |data|
      submitter = control.fetch(:submitter)
      next nil if data['banned'].include?(submitter)
      next nil if file_id.to_s.empty? || keys.empty?
      next nil if data['jobs'].count { |job| job.fetch('control_expires_at', 0) > @clock.call } >= 1000
      next nil if data['jobs'].count { |job| %w[queued sending awaiting_consent].include?(job['status']) } >= 1000

      status = :awaiting_choice
      if context && context[:submitter] == submitter && control[:choice] != :skip
        status = submission_status(data, **context)
        status = :awaiting_choice unless [:queued, :awaiting_consent].include?(status)
      end
      status = :duplicate if status == :queued && deduplicate!(data, keys, visual: visual)
      id = SecureRandom.hex(12)
      job = {
        'id' => id, 'file_id' => file_id, 'keys' => keys.uniq,
        'visual' => VideoFingerprint.valid?(visual) ? visual : nil,
        'submitter' => submitter, 'status' => status.to_s, 'attempts' => 0,
        'consent_request' => context && context[:consent_request],
        'one_off' => context && context[:one_off] == true,
        'privacy_version' => context && context[:privacy_version],
        'created_at' => @clock.call, 'next_at' => 0,
        'control_expires_at' => @clock.call + CONTROL_TTL,
        'control_chat_id' => control.fetch(:chat_id), 'control_video_id' => video_message_id,
        'control_message_id' => video_message_id, 'control_kind' => 'video',
        'control_caption' => caption, 'control_delay' => control[:choice] == :default ? CONTROL_DELAY : 0,
        # + retains immediate publication. Default waits until UI is attached.
        'control_ready' => control[:choice] == :publish
      }
      data['jobs'] << job
      Marshal.load(Marshal.dump(job))
    end
  end

  def activate_control(id, message_id:, kind:)
    change do |data|
      job = data['jobs'].find { |item| item['id'] == id }
      next nil unless job && job.fetch('control_expires_at', 0) > @clock.call

      job['control_message_id'], job['control_kind'] = message_id, kind
      unless job['control_ready']
        job['control_ready'] = true
        job['next_at'] = @clock.call + job['control_delay'] if %w[queued awaiting_consent].include?(job['status'])
      end
      Marshal.load(Marshal.dump(job))
    end
  end

  def control_snapshot(id)
    @mutex.synchronize do
      job = @data['jobs'].find { |item| item['id'] == id }
      job && Marshal.load(Marshal.dump(job))
    end
  end

  def controls_for_consent(token)
    @mutex.synchronize do
      @data['jobs'].select { |job| job['control_expires_at'] && job['consent_request'] == token }
           .first(10).map { |job| Marshal.load(Marshal.dump(job)) }
    end
  end

  def choose_control(id, action:, submitter:, chat_id:, message_id:)
    @publication_gate.synchronize do
      change do |data|
        job = data['jobs'].find { |item| item['id'] == id }
        unless job && job.fetch('control_expires_at', 0) > @clock.call
          raise VideoFeedError, 'Кнопки уже устарели. Пришли ссылку заново.'
        end
        unless job['submitter'] == submitter && job['control_chat_id'] == chat_id && job['control_message_id'] == message_id
          raise VideoFeedError, 'Эти кнопки доступны только отправителю ролика в исходном чате.'
        end
        raise VideoFeedError, 'Публикация в ленте для тебя недоступна.' if data['banned'].include?(submitter)
        raise VideoFeedError, 'Неизвестное действие.' unless %w[publish skip status].include?(action)

        # Sent/ambiguous/deletion states are never cancelled or re-sent here.
        unless %w[sent sending uncertain deleted deleting delete_pending delete_failed].include?(job['status']) || action == 'status'
          if action == 'skip'
            job['status'] = 'opted_out'
          elsif job['status'] != 'queued'
            job['status'] = deduplicate!(data, job['keys'], visual: job['visual'], candidate: job) ? 'duplicate' : 'queued'
          end
          if action == 'publish' && job['status'] == 'queued'
            job.merge!('one_off' => true, 'privacy_version' => data['privacy_versions'].fetch(submitter, 0),
                       'consent_request' => nil, 'control_ready' => true, 'control_delay' => 0,
                       'next_at' => @clock.call, 'attempts' => 0)
          end
        end
        Marshal.load(Marshal.dump(job))
      end
    end
  end
end

def prepare_video_feed_control(message, choice)
  return nil unless video_feed
  submitter = video_feed_submitter(message)
  return nil unless submitter

  video_feed.control_context(submitter, chat_id: message.chat.id, choice: choice)
rescue => e
  puts "Video feed control preparation error: #{e.class}"
  nil
end

def video_feed_control_text(job)
  case job['status']
  when 'queued'
    job['control_delay'].to_i > 0 ? 'ПОБОЧКА: автопубликация с паузой 30 секунд. До отправки можно отменить.' : 'ПОБОЧКА: ролик в очереди на публикацию.'
  when 'sent' then 'ПОБОЧКА: уже опубликовано. Отменить этой кнопкой нельзя.'
  when 'duplicate' then 'ПОБОЧКА: повтор — такой ролик уже есть в ленте или очереди.'
  when 'uncertain', 'sending' then 'ПОБОЧКА: результат отправки пока неизвестен. Повторно не отправляю.'
  when 'deleted', 'deleting', 'delete_pending', 'delete_failed' then 'ПОБОЧКА: публикация обработана модератором.'
  when 'blocked' then 'ПОБОЧКА: публикация недоступна.'
  when 'failed' then 'ПОБОЧКА: отправка не удалась. Можно повторить кнопкой.'
  else 'ПОБОЧКА: не публикуется. «В Побочку» разрешит только этот ролик; общая настройка не изменится.'
  end
end

def video_feed_control_markup(job)
  inactive = %w[sent sending uncertain deleted deleting delete_pending delete_failed blocked].include?(job['status'])
  buttons = if inactive
              [[{ text: job['status'] == 'sent' ? 'Уже в Побочке' : 'Статус публикации', callback_data: "feed_item:status:#{job['id']}" }]]
            else
              [[{ text: 'В Побочку', callback_data: "feed_item:publish:#{job['id']}" },
                { text: 'Не публиковать', callback_data: "feed_item:skip:#{job['id']}" }]]
            end
  JSON.generate(inline_keyboard: buttons)
end

def refresh_video_feed_control(api, job)
  params = { chat_id: job['control_chat_id'], message_id: job['control_message_id'],
             reply_markup: video_feed_control_markup(job) }
  body = "#{job['control_caption']}\n\n#{video_feed_control_text(job)}"
  if job['control_kind'] == 'text'
    api.edit_message_text(**params, text: body)
  else
    api.edit_message_caption(**params, caption: body)
  end
rescue => e
  # UI failure must never change a confirmed Telegram publication outcome.
  puts "Video feed control refresh error: #{e.class}"
end

def attach_video_feed_control(bot, message, control:, context:, keys:, visual:, caption:, album: false)
  return unless video_feed && control && message && message.respond_to?(:video) && message.video
  return unless message.chat.id == control[:chat_id]

  video = message.video
  keys = Array(keys).dup
  keys << "telegram:#{video.file_unique_id}" unless video.file_unique_id.to_s.empty?
  job = video_feed.register_control(file_id: video.file_id, keys: keys, visual: visual, control: control,
                                    context: context, video_message_id: message.message_id, caption: caption)
  return unless job

  if album
    # sendMediaGroup has no reply_markup. Keep the album and add a silent reply
    # to the exact constituent video, without attribution or a new DM.
    params = { chat_id: message.chat.id, text: "#{caption}\n\n#{video_feed_control_text(job)}",
               reply_markup: video_feed_control_markup(job), disable_notification: true,
               reply_parameters: JSON.generate(message_id: message.message_id) }
    params[:message_thread_id] = message.message_thread_id if message.respond_to?(:message_thread_id) && message.message_thread_id
    reply = bot.api.send_message(**params)
    return unless reply.respond_to?(:message_id) && reply.message_id

    latest = video_feed.activate_control(job['id'], message_id: reply.message_id, kind: 'text')
  else
    # Unlike refresh, attachment must propagate failure: don't start the timer
    # when Telegram did not confirm that the user can see the cancel button.
    bot.api.edit_message_caption(chat_id: message.chat.id, message_id: message.message_id,
                                 caption: "#{caption}\n\n#{video_feed_control_text(job)}", reply_markup: video_feed_control_markup(job))
    latest = video_feed.activate_control(job['id'], message_id: message.message_id, kind: 'video')
  end
  refresh_video_feed_control(bot.api, latest) if latest && latest['status'] != job['status']
rescue => e
  puts "Video feed control attachment error: #{e.class}"
end

def handle_video_feed_control_callback(bot, callback)
  match = callback.data.to_s.match(/\Afeed_item:(publish|skip|status):([a-f0-9]{24})\z/)
  return false unless match

  message, sender = callback.message, callback.from
  unless video_feed && message && message.respond_to?(:chat) && sender && !sender.is_bot
    answer_video_feed_callback(bot, callback, 'Эти кнопки сейчас недоступны.')
    return true
  end
  job = video_feed.choose_control(match[2], action: match[1], submitter: "user:#{sender.id}",
                                 chat_id: message.chat.id, message_id: message.message_id)
  answer_video_feed_callback(bot, callback, video_feed_control_text(job).sub('ПОБОЧКА: ', ''))
  refresh_video_feed_control(bot.api, job)
  true
rescue VideoFeedError => e
  answer_video_feed_callback(bot, callback, e.message)
  true
rescue => e
  puts "Video feed control callback error: #{e.class}"
  answer_video_feed_callback(bot, callback, 'Не удалось сохранить выбор. Попробуй ещё раз.')
  true
end
