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
  config.fullsend_app_id         = ENV.fetch("FULLSEND_APP_ID", "MyApp")
  config.message_group_id        = ENV.fetch("FULLSEND_MESSAGE_GROUP", "my-app-emailer")

  # Required only if you send attachments. Defaults from AWS_S3_BUCKET_NAME.
  config.s3_bucket      = ENV.fetch("AWS_S3_BUCKET_NAME", nil)
  config.s3_key_prefix  = "outgoing/" # optional, default ""
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

## Non-Templated Emails

Standard `ActionMailer` usage works as you'd expect — `to`, `cc`, `bcc`,
`subject`, and the body are passed through to the SQS payload as
`toAddresses`, `ccAddresses`, `bccAddresses`, `subject`, and `body`:

```ruby
class UserMailer < ApplicationMailer
  def welcome(user)
    mail(to: user.email, subject: "Welcome")
  end
end
```

## Templates and Bulk Destinations

Send one SQS message per campaign batch, with per-recipient Mustache data.
`destinations` is an array of `{ to:, data: }` entries (mapped onto AWS SES
`SendBulkTemplatedEmail` downstream, which caps each call at 50 destinations).

```ruby
class CampaignMailer < ApplicationMailer
  def welcome_batch(users)
    destinations = users.map do |user|
      { to: user.email, data: { first_name: user.first_name } }
    end

    set_template("welcome-v1", destinations: destinations)
    mail(from: "App <noreply@example.com>", subject: "Welcome!")
  end
end
```

The gem emits an SQS message of the form:

```json
{
  "templateName": "welcome-v1",
  "fromAddress": ["App <noreply@example.com>"],
  "subject": "Welcome!",
  "destinations": [
    { "to": "user@example.com", "data": { "first_name": "Ada" } }
  ],
  "emailTags": [ ... ]
}
```

`destinations` is authoritative: per-recipient `to` addresses and Mustache
`data` live there. Do not set `to`, `cc`, `bcc`, or a body on the `Mail`
object — those fields are not included in the payload.

## Attachments

Attachments use a claim-check pattern: the gem PUTs each attachment to S3,
then enqueues an SQS message containing the S3 keys (not the bytes). The
downstream service fetches each object at send time and attaches it to the
outgoing email.

Configure a bucket the downstream service can read from:

```ruby
Fullsend.configure do |config|
  config.s3_bucket     = "my-fullsend-bucket"
  config.s3_key_prefix = "outgoing/" # optional

  # Optional: override the region for the S3 client only. Useful when the
  # attachments bucket lives in a different region than the SQS queue.
  # Defaults from AWS_S3_REGION. SQS continues to use the
  # region resolved by aws_client_options.
  config.s3_region     = "us-west-2"
end
```

Then attach files via standard ActionMailer:

```ruby
class ReceiptMailer < ApplicationMailer
  def receipt(user, pdf_bytes)
    attachments["receipt.pdf"] = pdf_bytes
    mail(to: user.email, subject: "Your receipt")
  end
end
```

The SQS message gains an `attachments` array of S3 keys:

```json
{
  "toAddresses": ["user@example.com"],
  "fromAddress": ["noreply@example.com"],
  "subject": "Your receipt",
  "body": "...",
  "attachments": ["outgoing/9f3a-7c1b-receipt.pdf"]
}
```

Notes:

- Attachments work on both the standard and templated paths.
- Keys are `<prefix><uuid>-<filename>`. The recipient sees the original
  filename (the segment after the UUID).
- If `mail.attachments` is non-empty but `s3_bucket` is unset,
  `Fullsend::ConfigurationError` is raised before any SQS enqueue.
- An S3 PUT failure aborts before SQS is touched (no orphaned messages
  referencing missing keys); orphaned S3 objects from a later SQS failure
  should be GC'd via an S3 bucket lifecycle policy.
- The downstream service enforces a file-type allowlist and silently drops
  disallowed extensions. The gem does not pre-validate — pre-filter in
  your mailer if you need fail-fast behavior.
- SES caps the assembled message at ~40 MB; aim for total attachment size
  well under that.

## License

MIT
