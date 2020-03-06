## paws

Send/receive Slack messages via email.  Supports sending messages to
Slack via a sendmail-like command, and receiving messages from Slack
into maildirs, or for further processing by an MDA.

### Install

    perl Makefile.PL
    make
    make test
    sudo make install

Alternatively, run `cpanm .` from within the checkout directory. This
will fetch and install module dependencies, if required. See
https://cpanmin.us.

### Usage

paws is configured via a YAML file located at `~/.paws/config`.  Its
structure is like so:

```yaml
# The base domain name to use for mail to/from Slack.
domain_name: "slack.alt"
# The addressee for email received from Slack.
user_email: "user@example.org"
# Per-workspace configuration.
workspaces:
  # The workspace name.
  myworkspace:
    # The API token for the workspace.
    token: "xoxp-..."
    # The conversations to fetch from the workspace.  These have
    # the format {type}/{name}, where {type} is one of 'im',
    # 'mpim', 'group', or 'channel'.
    conversations:
      - "im/slackbot"
      - "channel/general"
    # The length of time (in seconds) prior to the timestamp of the
    # last-retrieved message in which to check for edits to messages
    # (defaults to 0).
    modification_window: 3600
    # The length of time (in seconds) after which a thread should be
    # considered 'expired', and will no longer be checked for new
    # messages (defaults to 7 days).
    thread_expiry: 3600
# Receiver configuration.
receivers:
    # The type of the receiver.
  - type: "maildir"
    # The workspace for the receiver.
    workspace: "apnicops"
    # The name of the receiver.  This must be unique for each receiver
    # entry in the configuration file.
    name: "default"
    # Type-specific configuration.  For 'maildir', the only extra
    # configuration is the path to the maildir.
    path: "/home/mail/slack"
# Sender configuration.
sender:
  # The sendmail command to be used for mail that isn't to be sent
  # to Slack.
  fallback_sendmail: "/bin/true"
  # The maildir directory to which bounce messages should be
  # written.
  bounce_dir: "/home/tomh/maildir/slack-bounce"
# Rate-limiting configuration.
rate_limiting:
  # The initial query rate, as a multiple of the rate documented by
  # Slack.  Defaults to 5, because Slack tolerates occasional bursts
  # of traffic past the documented query rate.
  initial: 10
  # The backoff rate.  When a 429 Too Many Requests is received, the
  # relevant query rate will be divided by this number.  Defaults to
  # 5, so that on receiving a 429 the query rate (if left as default)
  # is set to the (non-bursty) value recommended by Slack.
  backoff: 10
```

Then, configure your MUA to use `paws-send` as its sendmail command
for sending mail (mail that is not for Slack will be passed off to the
`fallback_sendmail` command).  After that, run `paws-receive` to pull
messages from Slack into the configured maildirs.  `paws-send-queued'
should also be run periodically, in order to resend messages that have
been queued due to temporary problems.

If `paws-receive` is run without arguments, then it will fetch new
messages from Slack for each workspace, one-by-one (i.e. each
workspace will be processed in its entirety before moving on to the
next one).  If multiple workspaces are configured, this process can be
made more efficient by having separate `paws-receive` calls for each
workspace (see the `--name` parameter).  Since the Slack API's rate
limits are per-workspace, parallelising the process in this way does
not increase the chance of running into a rate-limiting problem.

On first running `paws-receive`, it will pull all available messages,
which may take a long time.  If you don't need all of the messages,
then you can use the `--since` flag to only pull messages that were
originally sent on the given date or later (e.g. `paws-receive
--since=2020-01-01`).

`paws-receive` takes an optional `--persist={n}` argument.  If
provided, then instead of exiting once messages have been received, it
will open an RTM API connection and use that to listen for new
messages.  The argument to `--persist` is the number of minutes to use
as an interval for receiving new messages.  If the workspace is
configured for many channels that are only updated infrequently, using
`--persist` will be much more efficient than simply calling
`paws-receive` periodically.  If using `--persist` in a scheduled job,
`flock(1)` and its `--nonblock` argument may be useful.

For each command, if the `PAWS\_DEBUG` environment variable is set to
a true value, then debug messages will be printed to standard error.

### Receivers

#### maildir

Type-specific configuration:

 - `path`: the path to the maildir where the messages should be
   written.

#### MDA

Type-specific configuration:

 - `path`: the path to the MDA executable.
 - `args`: a list of arguments to be passed to the MDA executable.

### Notes

 - Files from Slack conversations are downloaded and presented as
   attachments in emails.  Attachments are uploaded to Slack as files.
 - Messages from a given conversation are represented as being replies
   to the original message in that conversation, to ease working with
   multiple conversations in a single maildir.
 - If replying to a message that is part of a Slack thread, then the
   reply will also be part of that Slack thread, except when the
   message being replied to is the first message in the thread.
 - An edited message has the string '(edited)' appended to its subject
   line, and is represented as being a reply to the original message.
 - `modification_window` is necessary, because the Slack API does not
   support a call like "get any edits that have happened since
   {time}".
 - `paws-send` will only handle mail that is 'to' a single Slack
   address.  'cc' and other headers are ignored in this instance.  New
   Slack conversations are not created implicitly (this may change in
   the future).
 - The 'to' address for a Slack conversation has the form:
 
    `$conversation_name @ $workspace_name . $domain_name`

 - Tested with [Mutt](http://mutt.org) 1.12.0, but should work with
   any MUA that supports sendmail and maildirs.
 - The `paws-aliases` command can be used to print a list of Slack
   user alias entries, for use with Mutt.  An alias username has the
   form:

    `slack-$workspace_name-$user_name`

### Bugs/problems/suggestions

See the [GitHub issue tracker](https://github.com/tomhrr/paws/issues).

### Licence

See LICENCE.
