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

  # Required only if you use the HTTP API client (Fullsend::Client, e.g.
  # removing SES suppressions). Default from FULLSEND_API_URL/FULLSEND_API_KEY.
  # See "HTTP API Client" below.
  config.api_base_url   = ENV.fetch("FULLSEND_API_URL", nil)
  config.api_key        = ENV.fetch("FULLSEND_API_KEY", nil)
end
```

Set the delivery method in your environment:

```ruby
# config/environments/production.rb
config.action_mailer.delivery_method = :fullsend
```

### AWS Credentials

The gem looks for credentials in this order:

1. Explicit values on `Fullsend.configure` (`access_key_id`, `secret_access_key`, `region`)
2. Environment variables: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`
3. Rails encrypted credentials: `credentials.aws.access_key_id`, etc.
4. The AWS SDK's default credential chain (instance profile, shared config, etc.)

### Regions

Each AWS service this gem touches can live in its own region. Both
default from their own env var and fall back to the generic `region`
(`AWS_REGION`) when unset:

| Config | Env var | Used for |
| --- | --- | --- |
| `region` | `AWS_REGION` | Generic default + credential resolution |
| `sqs_region` | `AWS_SQS_REGION` | The SQS client (queue) |
| `s3_region` | `AWS_S3_REGION` | The S3 client (attachments bucket) |

```ruby
Fullsend.configure do |config|
  config.sqs_region = "us-east-1"  # queue lives here
  config.s3_region  = "us-west-2"  # attachments bucket lives here
end
```

The SQS and S3 clients are built independently — setting `s3_region` never
affects the region the SQS client uses, and vice versa.

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

### Transactional vs marketing

The downstream service treats every email as **marketing by default** (and now
classifies anything tagged `"transactional"` as marketing too, as a safety
measure). To opt an email into the transactional path — bypassing unsubscribe
suppression and marketing throttles — set a `category: "transactional"` entry
via `metadata`:

```ruby
set_ses_headers(metadata: { category: "transactional" })
```

That produces an `emailTags` entry the downstream service recognizes:

```json
{
  "emailTags": [
    { "Name": "category", "Value": "transactional" }
  ]
}
```

Only use this for true transactional mail (password resets, receipts, account
notifications). Anything promotional should stay on the default marketing path.

### Migrating from another provider's header

If you're moving an existing app off another email provider, its mailers may
already emit a provider-specific header carrying the same tag JSON (for
example SparkPost's `X-MSYS-API`). Rather than rewriting every mailer to call
`set_ses_headers`, list those headers in `legacy_tag_headers`. The gem reads
the first one present as a fallback when `X-SES-API` is absent:

```ruby
Fullsend.configure do |config|
  config.legacy_tag_headers = ["X-MSYS-API"]
end
```

`X-SES-API` always takes precedence when both are present, and the option is
empty by default — the gem knows nothing about any specific provider unless
you opt in. The header value must be the same JSON shape `set_ses_headers`
produces (`{ "campaign_id": ..., "tags": [...], "metadata": {...} }`).

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

  # Optional: region for the S3 client only. Useful when the attachments
  # bucket lives in a different region than the SQS queue. Defaults from
  # AWS_S3_REGION; falls back to the generic `region` when unset. See the
  # Regions table above.
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

## HTTP API Client

Most of this gem enqueues mail to SQS for asynchronous delivery. For the few
operations that need a synchronous round-trip to the Fullsend service,
`Fullsend::Client` makes signed HTTP requests to the Fullsend API.

Configure the API base URL and HMAC signing key:

```ruby
Fullsend.configure do |config|
  config.api_base_url = ENV.fetch("FULLSEND_API_URL")  # e.g. "https://api.fullsend.example"
  config.api_key      = ENV.fetch("FULLSEND_API_KEY")  # HMAC signing secret
end
```

Both default from their env var (`FULLSEND_API_URL` / `FULLSEND_API_KEY`) and
fall back to Rails encrypted credentials under `credentials.fullsend`
(`api_base_url`/`url` and `api_key`/`key`) when unset.

Requests are authenticated with an HMAC-SHA256 signature over the request body
(an empty string for bodyless verbs like `DELETE`):

```
Authorization: HMAC <hex(HMAC-SHA256(api_key, body))>
```

### Removing an SES suppression

When SES hard-bounces or complains about an address it adds it to the account
suppression list, blocking future delivery. Once the address is known good
again, remove it:

```ruby
response = Fullsend::Client.new.delete_ses_suppression("user@example.com")

if response.success?
  # 2xx — removed, SES can deliver to it again
elsif response.not_found?
  # 404 — the address wasn't on the suppression list
end
```

`delete_ses_suppression` issues `DELETE /v1/ses-suppressions/<url-encoded email>`.
It returns a `Fullsend::Client::Response` (`#success?`, `#not_found?`,
`#status_code`, `#body`, and `#data` for the parsed JSON body) rather than
raising on an HTTP error status, so an expected 404 is a normal outcome.
Transport-level failures (timeouts, refused connections) raise
`Fullsend::ApiError`. Missing `api_base_url`/`api_key` raises
`Fullsend::ConfigurationError`.

## License

MIT
