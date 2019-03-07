require_dependency 'email/message_builder'

class GroupSmtpMailer < ActionMailer::Base
  include Email::BuildEmailHelper

  def send_mail(from_group, to_address, topic, post)
    if !Rails.env.development?
      delivery_options = {
        user_name: from_group.email_username,
        password: from_group.email_password,
        address: from_group.email_smtp_server,
        port: from_group.email_smtp_port,
        openssl_verify_mode: from_group.email_smtp_ssl ? 'peer' : 'none'
      }
    else
      delivery_options = { address: "localhost", port: 1025 }
    end

    build_email(to_address,
      delivery_method_options: delivery_options,
      from: from_group.email_username,
      subject: topic.title,
      add_re_to_subject: true,
      body: post.raw,
      post_id: post.id,
      topic_id: post.topic_id
    )
  end
end
