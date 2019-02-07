require "openssl"

class WebhooksController < ActionController::Base

  def mailgun
    return mailgun_failure if SiteSetting.mailgun_api_key.blank?

    params["event-data"] ? handle_mailgun_new(params) : handle_mailgun_legacy(params)
  end

  def sendgrid
    events = params["_json"] || [params]
    events.each do |event|
      message_id = (event["smtp-id"] || "").tr("<>", "")
      to_address = event["email"]
      if event["event"] == "bounce".freeze
        if event["status"]["4."]
          process_bounce(message_id, to_address, SiteSetting.soft_bounce_score)
        else
          process_bounce(message_id, to_address, SiteSetting.hard_bounce_score)
        end
      elsif event["event"] == "dropped".freeze
        process_bounce(message_id, to_address, SiteSetting.hard_bounce_score)
      end
    end

    render body: nil, status: 200
  end

  def mailjet
    events = params["_json"] || [params]
    events.each do |event|
      message_id = event["CustomID"]
      to_address = event["email"]
      if event["event"] == "bounce".freeze
        if event["hard_bounce"]
          process_bounce(message_id, to_address, SiteSetting.hard_bounce_score)
        else
          process_bounce(message_id, to_address, SiteSetting.soft_bounce_score)
        end
      end
    end

    render body: nil, status: 200
  end

  def mandrill
    events = params["mandrill_events"]
    events.each do |event|
      message_id = event.dig("msg", "metadata", "message_id")
      to_address = event.dig("msg", "email")

      case event["event"]
      when "hard_bounce"
        process_bounce(message_id, to_address, SiteSetting.hard_bounce_score)
      when "soft_bounce"
        process_bounce(message_id, to_address, SiteSetting.soft_bounce_score)
      end
    end

    render body: nil, status: 200
  end

  def sparkpost
    events = params["_json"] || [params]
    events.each do |event|
      message_event = event.dig("msys", "message_event")
      next unless message_event

      message_id   = message_event.dig("rcpt_meta", "message_id")
      to_address   = message_event["rcpt_to"]
      bounce_class = message_event["bounce_class"]
      next unless bounce_class

      bounce_class = bounce_class.to_i

      # bounce class definitions: https://support.sparkpost.com/customer/portal/articles/1929896
      if bounce_class < 80
        if bounce_class == 10 || bounce_class == 25 || bounce_class == 30
          process_bounce(message_id, to_address, SiteSetting.hard_bounce_score)
        else
          process_bounce(message_id, to_address, SiteSetting.soft_bounce_score)
        end
      end
    end

    render body: nil, status: 200
  end

  private

  def mailgun_failure
    render body: nil, status: 406
  end

  def mailgun_success
    render body: nil, status: 200
  end

  def valid_mailgun_signature?(token, timestamp, signature)
    # token is a random 50 characters string
    return false if token.blank? || token.size != 50

    # prevent replay attacks
    key = "mailgun_token_#{token}"
    return false unless $redis.setnx(key, 1)
    $redis.expire(key, 10.minutes)

    # ensure timestamp isn't too far from current time
    return false if (Time.at(timestamp.to_i) - Time.now).abs > 12.hours.to_i

    # check the signature
    signature == OpenSSL::HMAC.hexdigest("SHA256", SiteSetting.mailgun_api_key, "#{timestamp}#{token}")
  end

  def handle_mailgun_legacy(params)
    return mailgun_failure unless valid_mailgun_signature?(params["token"], params["timestamp"], params["signature"])

    event = params["event"]
    message_id = params["Message-Id"].tr("<>", "")
    to_address = params["recipient"]

    # only handle soft bounces, because hard bounces are also handled
    # by the "dropped" event and we don't want to increase bounce score twice
    # for the same message
    if event == "bounced".freeze && params["error"]["4."]
      process_bounce(message_id, to_address, SiteSetting.soft_bounce_score)
    elsif event == "dropped".freeze
      process_bounce(message_id, to_address, SiteSetting.hard_bounce_score)
    end

    mailgun_success
  end

  def handle_mailgun_new(params)
    signature = params["signature"]
    return mailgun_failure unless valid_mailgun_signature?(signature["token"], signature["timestamp"], signature["signature"])

    data = params["event-data"]
    message_id = data.dig("message", "headers", "message-id")
    to_address = data["recipient"]
    severity = data["severity"]

    if data["event"] == "failed".freeze
      if severity == "temporary".freeze
        process_bounce(message_id, to_address, SiteSetting.soft_bounce_score)
      elsif severity == "permanent".freeze
        process_bounce(message_id, to_address, SiteSetting.hard_bounce_score)
      end
    end

    mailgun_success
  end

  def process_bounce(message_id, to_address, bounce_score)
    return if message_id.blank? || to_address.blank?

    email_log = EmailLog.find_by(message_id: message_id, to_address: to_address)
    return if email_log.nil?

    email_log.update_columns(bounced: true)
    return if email_log.user.nil? || email_log.user.email.blank?

    Email::Receiver.update_bounce_score(email_log.user.email, bounce_score)
  end

end
