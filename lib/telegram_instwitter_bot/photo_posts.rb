# frozen_string_literal: true

require 'json'
require 'tempfile'
require 'thread'

class PhotoPostError < StandardError; end

# Telegram file IDs are enough to resend photos; no image downloads are needed.
# Keep incoming photos separate from bot-sent videos and from other users/topics.
class PhotoPostStore
  def initialize(path, limit: 50)
    @path = path
    @limit = limit
    @mutex = Mutex.new
    @in_flight = {}
  end

  def record(scope, photo)
    @mutex.synchronize do
      history = load_history
      photos = entries(history, scope)
      return { added: false } if photos.any? { |entry| entry['message_id'] == photo['message_id'] }

      if photos.count { |entry| !entry['assembled'] } >= @limit
        raise PhotoPostError, 'Память новых фото заполнена. Сначала собери пост из последних 10 фото.'
      end

      group_id = photo['media_group_id']
      notify = group_id.to_s.empty? || photos.none? { |entry| entry['media_group_id'] == group_id }
      photos = (photos + [photo]).sort_by { |entry| entry.fetch('message_id') }
      # Discard old assembled entries first, never silently discard pending photos.
      while photos.size > @limit
        photos.delete_at(photos.index { |entry| entry['assembled'] })
      end
      history[scope] = photos
      save_history(history)
      { added: true, notify: notify, pending: photos.count { |entry| !entry['assembled'] } }
    end
  end

  def reserve(scope, count, period: nil, now: Time.now.to_i)
    @mutex.synchronize do
      raise PhotoPostError, 'Уже собираю твой пост из фото. Дождись отправки.' if @in_flight[scope]
      if count && !count.between?(1, 10)
        raise PhotoPostError, 'Можно собрать пост из 1–10 фото.'
      end

      photos = entries(load_history, scope)
      if period
        selected = select_period(photos, period, now)
      elsif count
        if photos.size < count
          raise PhotoPostError, "В этом чате сохранено только #{photos.size} твоих фото. Пришли фото ещё раз. В группе бот должен быть администратором или иметь отключённый Privacy Mode; можно также прислать фото в личку."
        end
        selected = photos.last(count)
      else
        selected = photos.reject { |photo| photo['assembled'] }
        if selected.empty?
          raise PhotoPostError, 'Новых фото пока нет. Пришли фото, затем напиши «собери пост». В группе бот должен видеть обычные сообщения; самый простой вариант — фото в личку боту.'
        end
        if selected.size > 10
          raise PhotoPostError, "Новых фото: #{selected.size}. В альбоме максимум 10. Напиши «собери пост из последних 10 фото»; остальные останутся для следующего поста."
        end
      end

      @in_flight[scope] = true
      selected
    end
  end

  def complete(scope, selected)
    @mutex.synchronize do
      history = load_history
      ids = selected.map { |photo| photo.fetch('message_id') }
      entries(history, scope).each { |photo| photo['assembled'] = true if ids.include?(photo['message_id']) }
      save_history(history)
    end
  end

  def release(scope)
    @mutex.synchronize { @in_flight.delete(scope) }
  end

  private

  def select_period(photos, period, now)
    unless period == :today || (period.is_a?(Integer) && period.positive?)
      raise PhotoPostError, 'Укажи положительное число часов: например «собери пост за 2 часа».'
    end

    if period == :today
      local = Time.at(now).getlocal('+03:00')
      since = Time.new(local.year, local.month, local.day, 0, 0, 0, '+03:00').to_i
    else
      since = now - period
    end
    selected = photos.select do |photo|
      timestamp = photo['sent_at']
      timestamp.is_a?(Integer) && timestamp >= since && timestamp <= now
    end
    if selected.empty?
      text = 'За этот период твоих фото не нашёл. Пришли фото и повтори команду.'
      if photos.any? { |photo| !photo['sent_at'].is_a?(Integer) }
        text += ' У фото, сохранённых до обновления, нет времени отправки; их можно собрать командой «собери пост из последних 3 фото».'
      end
      raise PhotoPostError, text
    end
    if selected.size > 10
      raise PhotoPostError, "За этот период найдено #{selected.size} фото. В одном альбоме максимум 10. Выбери меньший период или напиши «собери пост из последних 10 фото»."
    end

    selected
  end

  def entries(history, scope)
    value = history.fetch(scope, [])
    raise PhotoPostError, 'История фото повреждена. Нужна проверка файла истории.' unless value.is_a?(Array)

    value
  end

  def load_history
    return {} unless File.exist?(@path)

    history = JSON.parse(File.read(@path))
    raise JSON::ParserError unless history.is_a?(Hash)

    history
  rescue JSON::ParserError
    # Do not overwrite a corrupt history with an empty file.
    raise PhotoPostError, 'Не удалось прочитать историю фото. Нужна проверка файла истории.'
  end

  def save_history(history)
    Tempfile.create(['.photo_history-', '.tmp'], File.dirname(File.expand_path(@path))) do |file|
      file.chmod(0600)
      file.write(JSON.generate(history))
      file.flush
      file.fsync
      File.rename(file.path, @path)
    end
  end
end

PHOTO_POST_STORE = PhotoPostStore.new('photo_history.json')

def photo_post_request(text)
  text = text.to_s.strip
  return { count: nil } if text.match?(%r{\A(?:собери\s+(?:пост|подборку)(?:\s+из\s+(?:фото|фотографий))?|(?:assemble|make)\s+(?:a\s+)?(?:photo\s+)?post(?:\s+from\s+photos)?|/post)\z}i)
  return { count: nil, period: :today } if text.match?(%r{\A(?:собери\s+(?:пост|подборку)(?:\s+из\s+фото)?\s+за\s+сегодня|(?:assemble|make)\s+(?:a\s+)?(?:photo\s+)?post\s+(?:for|from)\s+today)\z}i)

  hours = text.match(%r{
    \A(?:
      собери\s+(?:пост|подборку)(?:\s+из\s+фото)?\s+за\s+(?:последни[йех]\s+)?(?:(\d+)\s+)?час(?:а|ов)?
      |(?:assemble|make)\s+(?:a\s+)?(?:photo\s+)?post\s+from\s+(?:the\s+)?last\s+(?:(\d+)\s+)?hours?
    )\z
  }ix)
  return { count: nil, period: (hours[1] || hours[2] || '1').to_i * 3600 } if hours

  match = text.match(%r{
    \A(?:
      (?:собери\s+(?:пост|подборку)\s+из\s+последних|собери\s+последние)\s+(\d+)\s+(?:фото|фотографий|фотографии|фотографию|фоток)
      |(?:assemble|make)\s+(?:a\s+)?(?:post|collection)\s+from\s+(?:the\s+)?last\s+(\d+)\s+photos?
    )\z
  }ix)
  match ? { count: (match[1] || match[2]).to_i } : nil
end

def photo_post_scope(message)
  [message.chat.id, message.from.id, message.message_thread_id].map(&:to_s).join(':')
end

def photo_post_notice(bot, chat_id, text, thread_id = nil)
  params = { chat_id: chat_id, text: text }
  params[:message_thread_id] = thread_id if thread_id
  bot.api.send_message(**params)
rescue => e
  puts "photo post notice error: #{e.class}"
end

# Returns true when the message belongs to the photo workflow.
def handle_photo_post_message(bot, media_queue, message, command_text, addressed:, bot_username:, store: PHOTO_POST_STORE)
  return false unless message.from && !message.from.is_bot

  photos = Array(message.photo)
  request = photo_post_request(command_text) if addressed
  return false if photos.empty? && !request

  scope = photo_post_scope(message)
  chat_id = message.chat.id
  thread_id = message.message_thread_id
  notify_user = addressed || (bot_username && message.reply_to_message&.from&.username == bot_username)
  unless photos.empty?
    # Collect all photos Telegram delivers, including unmentioned group photos.
    # Acknowledge only directed messages so ordinary group traffic stays quiet.
    if message.has_protected_content
      photo_post_notice(bot, chat_id, 'Это фото защищено от пересылки. Пришли своё фото без защиты.', thread_id) if notify_user
      return true
    end

    best = photos.max_by { |photo| [photo.width.to_i * photo.height.to_i, photo.file_size.to_i] }
    entry = {
      'message_id' => message.message_id,
      'file_id' => best.file_id,
      'sent_at' => message.date.to_i,
      'media_group_id' => message.media_group_id,
      'caption' => message.caption,
      'caption_entities' => Array(message.caption_entities).map(&:to_h)
    }
    result = store.record(scope, entry)
    if result[:notify] && notify_user
      text = if message.media_group_id
               'Получаю фото альбома. Когда закончишь, напиши «собери пост» или «собери пост из последних 3 фото».'
             else
               "Фото сохранено. Новых фото: #{result[:pending]}. Напиши «собери пост» или «собери пост из последних 3 фото»."
             end
      photo_post_notice(bot, chat_id, text, thread_id)
    end
    return true
  end

  # The period ends when the command was sent, not when a queued job is run.
  selected = store.reserve(scope, request.fetch(:count), period: request[:period], now: message.date.to_i)
  job = { type: :photo_post, chat_id: chat_id, thread_id: thread_id, scope: scope, photos: selected, store: store }
  queued = false
  begin
    queued = enqueue_media_job(media_queue, bot, chat_id, job)
  ensure
    store.release(scope) unless queued
  end
  true
rescue PhotoPostError => e
  photo_post_notice(bot, chat_id, e.message, thread_id) if notify_user
  true
rescue => e
  puts "photo post handling error: #{e.class}"
  photo_post_notice(bot, chat_id, 'Не удалось сохранить фото или подготовить пост. Попробуй ещё раз.', thread_id) if notify_user
  true
end

def send_photo_post(bot, job)
  store = job.fetch(:store)
  scope = job.fetch(:scope)
  photos = job.fetch(:photos)
  params = { chat_id: job.fetch(:chat_id) }
  params[:message_thread_id] = job[:thread_id] if job[:thread_id]
  media = photos.map do |photo|
    payload = { 'type' => 'photo', 'media' => photo.fetch('file_id') }
    unless photo['caption'].to_s.empty?
      payload['caption'] = photo['caption']
      payload['caption_entities'] = photo['caption_entities'] unless Array(photo['caption_entities']).empty?
    end
    payload
  end
  if media.one?
    photo = media.first
    single_params = { photo: photo.fetch('media') }
    single_params[:caption] = photo['caption'] if photo['caption']
    single_params[:caption_entities] = JSON.generate(photo['caption_entities']) if photo['caption_entities']
    bot.api.send_photo(**params, **single_params)
  else
    bot.api.send_media_group(**params, media: JSON.generate(media))
  end
  sent = true
  store.complete(scope, photos)
rescue => e
  puts "photo post sending error: #{e.class}"
  text = if sent
           'Пост отправлен, но не удалось обновить историю фото. Не повторяй команду: пост уже выше.'
         else
           'Не удалось отправить пост из фото. Фото сохранены. Если пост не появился, повтори команду.'
         end
  photo_post_notice(bot, job[:chat_id], text, job[:thread_id])
ensure
  store.release(scope) if store && scope
end
