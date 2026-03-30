# fullsend-rails

SQS-based ActionMailer delivery method for the Fullsend email service. Sends emails as JSON messages to an SQS FIFO queue for processing and delivery via SES.

## Installation

Add to your Gemfile:

```ruby
gem "fullsend-rails"
```

Then run `bundle install`.

## Configuration

Create an initializer:

```ruby
# config/initializers/fullsend.rb
Fullsend.configure do |config|
  config.queue_name              = ENV.fetch("SQS_EMAIL_QUEUE_NAME")
  config.configuration_set_name  = ENV.fetch("FULLSEND_CONFIG_SET", "MyApp")
  config.message_group_id        = ENV.fetch("FULLSEND_MESSAGE_GROUP", "my-app-emailer")
end
```

Set the delivery method in your environment:

```ruby
# config/environments/production.rb
config.action_mailer.delivery_method = :fullsend
```

### AWS Credentials

The gem looks for credentials in this order:

1. Environment variables: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`
2. Rails encrypted credentials: `credentials.aws.access_key_id`, etc.

## Campaign Tracking

Include the helpers in your mailer:

```ruby
class ApplicationMailer < ActionMailer::Base
  include Fullsend::MailerHelpers
end
```

Then use `set_ses_headers` in your mailer methods:

```ruby
class UserMailer < ApplicationMailer
  def welcome(user)
    set_ses_headers(
      tags: ["onboarding"],
      metadata: { user_id: user.id }
    )
    mail(to: user.email, subject: "Welcome")
  end
end
```

`campaign_id` defaults to the mailer method name. Override it:

```ruby
set_ses_headers(campaign_id: "custom_campaign", tags: ["promo"])
```

## License

MIT
