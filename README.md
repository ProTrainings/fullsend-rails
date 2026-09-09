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
  # removing SES suppressions). Default from FULLSEND_API_URL/FULLSEND_API_TOKEN.
  # See "HTTP API Client" below.
  config.api_base_url   = ENV.fetch("FULLSEND_API_URL", nil)
  config.api_token      = ENV.fetch("FULLSEND_API_TOKEN", nil)
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
`destinations` is an array of `{ to:, data:, locale: }` entries (mapped onto AWS
SES `SendBulkTemplatedEmail` downstream, which caps each call at 50
destinations).

```ruby
class CampaignMailer < ApplicationMailer
  def welcome_batch(users)
    destinations = users.map do |user|
      { to: user.email, data: { first_name: user.first_name }, locale: user.locale }
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
    { "to": "user@example.com", "data": { "first_name": "Ada" }, "locale": "es" }
  ],
  "emailTags": [ ... ]
}
```

`destinations` is authoritative: per-recipient `to` addresses, Mustache `data`,
and `locale` live there. Do not set `to`, `cc`, `bcc`, or a body on the `Mail`
object — those fields are not included in the payload.

### Locale

Locale is **per destination**, not per message — a batch of 100 users can hold
a mix of languages, and the downstream service renders each recipient against
their own locale.

Resolution order for each entry, first match wins:

1. The entry's own `locale:`
2. The batch-wide `locale:` passed to `set_template`
3. `I18n.locale`

```ruby
# Per recipient — the usual case for a mixed batch.
set_template("welcome-v1", destinations: [
  { to: "ada@example.com",   data: { first_name: "Ada" }, locale: :es },
  { to: "bob@example.com",   data: { first_name: "Bob" }, locale: "fr-CA" }
])

# One locale for the whole batch.
set_template("welcome-v1", destinations: destinations, locale: :es)

# Neither given — every destination gets I18n.locale.
set_template("welcome-v1", destinations: destinations)
```

Values are normalized to strings, so `:es`, `"es"`, and `:"fr-CA"` all
serialize the way the payload above shows. An empty or `nil` locale on an entry
counts as absent and falls through to the next step. If none of the three
yields a value (`I18n` isn't loaded), the key is omitted and the downstream
service applies its own default.

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
`Fullsend::Client` makes authenticated HTTP requests to the Fullsend API.

Configure the API base URL and bearer token:

```ruby
Fullsend.configure do |config|
  config.api_base_url = ENV.fetch("FULLSEND_API_URL")    # e.g. "https://api.fullsend.example"
  config.api_token    = ENV.fetch("FULLSEND_API_TOKEN")  # bearer token
end
```

Both default from their env var (`FULLSEND_API_URL` / `FULLSEND_API_TOKEN`) and
fall back to Rails encrypted credentials under `credentials.fullsend`
(`api_base_url`/`url` and `api_token`/`token`) when unset.

Requests are authenticated with a bearer token:

```
Authorization: Bearer <api_token>
```

### Tokens that expire

Obtaining and refreshing the token is your application's job — the gem only
forwards what it's given. If your token is short-lived (an OAuth2
client-credentials JWT, for example), set `api_token` to a callable instead of
a String:

```ruby
Fullsend.configure do |config|
  config.api_token = -> { MyTokenCache.access_token }
end
```

The callable is invoked on every request, so a token your app refreshes is
picked up automatically without reconfiguring the gem. Keep the caching and
expiry handling in your own token class — `Fullsend::Client` deliberately owns
no token lifecycle.

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
`Fullsend::ApiError`. A missing `api_base_url`/`api_token` — or a callable
`api_token` that resolves to nothing — raises `Fullsend::ConfigurationError`.

### Adding an SES suppression

SES records its own bounces and complaints. Use this when the signal arrived
somewhere else — another email provider reporting a hard bounce or a spam
complaint for the same person — and that address should stop receiving mail
here too:

```ruby
response = Fullsend::Client.new.create_ses_suppression(
  "user@example.com",
  reason: Fullsend::Client::SES_SUPPRESSION_REASON_COMPLAINT,
  source: Fullsend::Client::SES_SUPPRESSION_SOURCE_SPARKPOST
)
```

`create_ses_suppression` issues `POST /v1/ses-suppressions`. `reason` is
required and must be `SES_SUPPRESSION_REASON_BOUNCE` or
`SES_SUPPRESSION_REASON_COMPLAINT` — an unknown one raises `ArgumentError` at
the call site instead of coming back as a 400. `source` is optional and records
where the row came from; the service sets `sns` and `reconcile` itself.

The service upserts on the address — the original `source` is kept and `reason`
moves to the newer signal — so replaying a webhook is safe. Like the delete, it
returns a `Fullsend::Client::Response` and does not raise on an HTTP error
status.

Suppression is not an unsubscribe. It blocks every send to the address, while
[an unsubscribe](#unsubscribing-someone) is the marketing opt-out list, checked
separately. Mirroring a provider's *unsubscribe* belongs in `create_unsubscribe`.

## Event Triggers

Automations in Fullsend are armed by *events* — domain facts your app reports
("a user started a course"). The app does not name a campaign or a recipient
list: it says what happened, and every automation whose triggers listen for that
key decides for itself what to do. The same key can open a run in one
automation, advance a run in a second, and end a run in a third.

From a request or a model callback, enqueue it:

```ruby
Fullsend.track_event_later(
  "course.started",
  email:      user.email,
  subject_id: "u_#{user.id}",
  properties: {
    course_id:   course.id,
    course_name: course.name,
    user:        { first_name: user.first_name, last_name: user.last_name }
  }
)
```

which posts to the intake:

```json
{
  "app_id": "3163870b-4658-4d36-8a0d-e5c9d361800f",
  "event_key": "course.started",
  "subject_id": "u_12345",
  "email": "joe@gmail.com",
  "properties": {
    "course_id": 2,
    "course_name": "Course Two",
    "user": { "first_name": "John", "last_name": "Doe" }
  }
}
```

Uses the same `api_base_url` / `api_token` as the HTTP API Client above.

| Field | Required | Notes |
| --- | --- | --- |
| `event_key` | yes | The registry key, e.g. `course.started` |
| `email` | yes | The delivery address; how a run is found or created |
| `app_id` | yes | Defaults to the configured `fullsend_app_id` |
| `subject_id` | no | Your app's id for the subject, for correlation |
| `properties` | no | Becomes the run's data context — see below |

### Properties

`properties` becomes the run's data context when an automation enrolls, so
condition nodes downstream read it by dot path (`user.first_name`,
`course_id`). Nest freely; keep values JSON-serializable.

An automation's *run grouping* names the property runs are keyed by — a
`course.started` event carrying `course_id: 2` opens a run per course rather
than one per person. An event missing that property is not an error; it simply
isn't a fact that automation was asked about, and it's skipped. So send the
properties your automations group and branch on, every time.

### Sync vs enqueued

`track_event_later` enqueues `Fullsend::EventJob` (ActiveJob) — the right
default, since the intake is an external service and does not belong in the
critical path of a user action. The job retries on `Fullsend::ApiError` (5
attempts, growing backoff) so a blip does not silently lose an event, and
discards immediately on a missing `event_key`/`email`/`app_id`, which would fail
identically on every attempt. Give it its own queue if your default queue is
busy:

```ruby
Fullsend.configure { |config| config.event_queue_name = "fullsend_events" }
```

Job arguments go through ActiveJob serialization, so `properties` must be
strings, numbers, booleans, arrays, and hashes of the same. Pass a record's
attributes, not the record.

Use `Fullsend.track_event` for the synchronous call — a rake task, a backfill,
or anywhere you want to inspect the outcome:

```ruby
result = Fullsend.track_event("course.started", email: user.email, properties: { course_id: 1 })

result.registered?       # false => the key is not in the registry (or archived)
result.matched_campaigns # automations whose triggers matched
result.enrolled          # runs opened
result.signalled         # runs advanced
result.stopped           # runs ended
```

### An unregistered key is accepted, not rejected

An event whose key is missing from the registry — or archived — comes back
**2xx** with `registered?` false. That is deliberate: rejecting would let a
registry edit break an emitting app mid-deploy. The flip side is that a typo in
an event key looks exactly like success. Nothing errors, no automation runs, and
you find out when someone notices the emails stopped. Check `registered?` on the
paths you care about, or watch for the warning the service logs.

`track_event` returns non-2xx as a `Fullsend::Client::EventResult` rather than
raising, the same as `delete_ses_suppression`. Transport-level failures raise
`Fullsend::ApiError`; a missing `event_key`/`email` raises `ArgumentError`, and
an unresolvable `app_id` raises `Fullsend::ConfigurationError`.

## Which Automations Is Someone In?

Events go one way — your app reports facts and never learns what came of them.
`drip_enrollments` reads the other direction: one call returns every campaign an
address is or was enrolled in, so a support screen, an admin page, or a
"don't enroll them twice" guard doesn't need a request per campaign.

```ruby
result = Fullsend.drip_enrollments(user.email)

result.active_campaign_names       # => ["Trial nurture"]
result.active_in?("trial-nurture") # => true  (still in it)
result.enrolled_in?("onboarding")  # => true  (history counts)
```

Uses the same `api_base_url` / `api_token` as the HTTP API Client above, and
issues `GET /v1/drip-campaigns/enrollments`.

### `active` is derived, not a status

An enrollment is live while its status is **`active` OR `waiting`**. A `waiting`
run is merely parked on a branch condition — waiting on an open, a click, a
signal — and is still very much enrolled. So ask `active?`, not
`status == "active"`, or you'll silently miss every parked run:

```ruby
result.active                                  # right
result.enrollments.select { |e| e.status == "active" }  # wrong — omits 'waiting'
```

The four statuses are `active`, `waiting`, `completed`, `stopped`.

### Rows

`result.enrollments` is newest-enrollment-first, and each row carries its
campaign's name and id so you can label it without a lookup:

```ruby
result.enrollments.each do |enrollment|
  enrollment.campaign_name     # "Trial nurture"
  enrollment.campaign_id       # "trial-nurture" — the campaign's own id
  enrollment.drip_campaign_id  # 4 — the numeric id, for /v1/drip-campaigns/:id
  enrollment.status            # "waiting"
  enrollment.active?           # true
  enrollment.stop_reason       # "conversion" | "manual" | "bounce" | ...
  enrollment.subject_id        # your app's id for the person, if sent
  enrollment.correlation_key   # scopes concurrent runs, e.g. "course:2"
  enrollment.context           # the event `properties` the run carries
  enrollment.enrolled_at       # Time
  enrollment.campaign_deleted? # campaign was since deleted — see below
end
```

`enrollment[:any_field]` and `enrollment.to_h` reach anything not given a reader.

An enrollment whose campaign has since been deleted is still returned, flagged
with `campaign_deleted?`. The row is real history — the person genuinely was
enrolled — so filter it out yourself if you're rendering current state.

### Filters

```ruby
Fullsend.drip_enrollments(email, active: true)          # live runs only
Fullsend.drip_enrollments(email, active: false)         # finished runs only
Fullsend.drip_enrollments(email, status: "stopped")     # one exact status
Fullsend.drip_enrollments(email, page_size: 25)         # default 100, max 500
```

Omitting `active` returns every state. `active:` and `status:` are independent —
`active` is the coarse live/finished split, `status` an exact match for drilling
into one state.

The lookup is scoped to the configured `fullsend_app_id`, which is what an app
asking about its own recipients wants. Pass another id, or
`Fullsend::Client::ALL_APPS` for every app your token can see:

```ruby
Fullsend.drip_enrollments(email, app_id: Fullsend::Client::ALL_APPS)
```

The address is matched exactly as stored, so pass the same address you enrolled.

Returns a `Fullsend::Client::DripEnrollmentsResult` (a `Response`, so
`#success?`/`#status_code`/`#data` are there too) and does not raise on a non-2xx
— where `#enrollments` reads as empty, so check `#success?` when an empty list
and a failed call need telling apart. A blank `email`, an unknown `status`, or a
`page_size` outside 1..500 raises `ArgumentError` before any request goes out.

## Unsubscribing Someone

`create_unsubscribe` records that an address opted out. This is the durable half
of an unsubscribe, and the distinction matters: stopping an enrollment ends the
runs already open, but only an opt-out row keeps the *next* matching event from
enrolling them all over again.

```ruby
result = Fullsend.create_unsubscribe(
  user.email,
  scope: Fullsend::Client::SCOPE_CAMPAIGN,
  campaign_id: enrollment.campaign_id,
  reason: Fullsend::Client::REASON_MANUAL
)

result.success?     # => true
result.scope        # => "campaign"
result.app_wide?    # => false
result.created_at   # => Time
```

Issues `POST /v1/unsubscribes`, using the same `api_base_url` / `api_token` as
the rest of the HTTP client.

### `scope` is required, deliberately

Two scopes: `SCOPE_CAMPAIGN` silences one automation and leaves the others,
`SCOPE_APP` is "stop emailing me from this app at all".

The service defaults a missing scope to app-wide. The gem refuses to send one
instead, because opting somebody out of *every* campaign because a keyword got
forgotten is not a failure mode worth inheriting. Name the scope:

```ruby
Fullsend.create_unsubscribe(email, scope: Fullsend::Client::SCOPE_APP)
Fullsend.create_unsubscribe(email, scope: Fullsend::Client::SCOPE_CAMPAIGN, campaign_id: "trial-nurture")
```

`campaign_id` is the campaign's *string* id — its tag — which is exactly what
`Enrollment#campaign_id` hands back, so pairing this with `drip_enrollments`
needs no id translation. Campaign scope without a `campaign_id` raises
`ArgumentError` rather than silently widening.

### `reason`

`REASON_ONE_CLICK` (an RFC 8058 List-Unsubscribe POST), `REASON_LINK_CLICK` (a
footer link), or `REASON_MANUAL` (a preferences page, or a support agent acting
on a request). It's what a compliance question asks about a year later, so pass
the one that's true. Omitted, the service records `manual`.

### An opt-out is not an unenrollment

Opting someone out does **not** end their enrollment. The run stays live and
`drip_enrollments` keeps returning it — the service re-checks the opt-out list at
send time instead, and drops the send. So the mail does stop immediately, without
the enrollment changing to say so.

Which matters for anything that renders state: after someone unsubscribes from
"Trial nurture", asking `drip_enrollments` still reports them enrolled in it. A
preferences page that only reads enrollments will show the box they just
unchecked as checked again. Read both — enrollments for what they're *in*,
`unsubscribes` (below) for what's *silenced*.

(Ending the enrollment outright is a separate operation, `POST
/v1/drip-campaigns/:id/stop`, and is not wrapped here. It is an admin action —
`stop_reason=manual` — not what an unsubscribe needs.)

`create_unsubscribe` returns an `UnsubscribeResult` (a `Response`) and does not
raise on a non-2xx — check `#success?`. A blank `email`, an unknown `scope` or
`reason`, or campaign scope without a `campaign_id` raises `ArgumentError`
before any request goes out; an unresolvable `app_id` raises
`Fullsend::ConfigurationError`.

## Reading And Undoing Opt-Outs

`unsubscribes` answers "what has this address opted out of" — the other half of
what a preferences page needs, per the note above.

```ruby
result = Fullsend.unsubscribes(user.email)

result.app_wide?                     # => false  (no "stop everything" row)
result.campaign_ids                  # => ["trial-nurture"]
result.suppressed?("trial-nurture")  # => true   (would the service skip the send?)
result.for_campaign("trial-nurture") # => the row, whose #id undoes it
```

`suppressed?` is the question worth asking: it applies the service's own rule, so
an app-wide opt-out reads as suppressing every campaign. `app_wide?` and
`campaign_ids` are kept separate because they are different states — a page
renders "you've turned off all email" differently from a list of individual
boxes, and `campaign_ids` deliberately does not fold an app-wide row in.

Issues `GET /v1/unsubscribes`, scoped to the configured `fullsend_app_id` unless
you pass `app_id:` (or `Fullsend::Client::ALL_APPS`). `scope:` and `page_size:`
narrow it further; usually you want both scopes, since an app-wide row suppresses
campaigns too.

### Re-subscribing

`delete_unsubscribe` removes an opt-out row, by id:

```ruby
row = Fullsend.unsubscribes(user.email).for_campaign("trial-nurture")
Fullsend.delete_unsubscribe(row.id) if row
```

This clears only the local marketing opt-out. An address SES suppressed itself
after a hard bounce or a complaint stays suppressed — that's
`delete_ses_suppression`, a different list. Re-subscribing someone who is on
both takes both calls.

`unsubscribes` returns an `UnsubscribesResult` and `delete_unsubscribe` a plain
`Response`; neither raises on a non-2xx, and a missing row comes back
`not_found?`. A blank id, an unknown `scope`, or a `page_size` outside 1..500
raises `ArgumentError`.

## License

MIT
