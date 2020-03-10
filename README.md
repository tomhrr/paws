## paws

Send/receive Slack messages via email.  Useful if you use a mail
client like [Mutt](http://mutt.org) or
[mu4e](https://www.djcbsoftware.nl/code/mu/mu4e.html) and would prefer
to communicate with Slack via that client.  Supports sending messages
to Slack via a sendmail-like command, and receiving messages from
Slack into maildirs, or for further processing by an MDA.

### Install

    perl Makefile.PL
    make
    make test
    sudo make install

Alternatively, run `cpanm .` from within the checkout directory. This
will fetch and install module dependencies, if required. See
https://cpanmin.us.

### Basic setup

A user token is needed for each workspace.  To generate these tokens:

 - run `paws-register`: this will print a URL to standard output;
 - load the URL into a browser: Slack's authorisation page should
   appear;
 - grant access to the workspace: a success page should appear,
   containing a command like `paws-register {code}`;
 - run this command: this will print the user token to standard
   output.

After the tokens have been generated, make a `.paws` directory in your
home directory.  Configuration is via a YAML file named `config`,
placed within that directory.  A minimal example is like so:

```yaml
# The addressee for email received from Slack.
user_email: "user@example.org"
# Per-workspace configuration.
workspaces:
  # The workspace name.
  myworkspace:
    # The API token for the workspace, generated using `paws-register`.
    token: "xoxp-..."
    # The conversations to fetch from the workspace.  These have
    # the format {type}/{name}, where {type} is one of 'im',
    # 'mpim', 'group', or 'channel'.  Defaults to '*' (i.e. all
    # conversations).
    conversations:
      - "im/slackbot"
      - "channel/general"
# Receiver configuration.
receivers:
    # The type of the receiver.
  - type: "maildir"
    # The workspace for the receiver.
    workspace: "myworkspace"
    # The name of the receiver.  This must be unique for each receiver
    # entry in the configuration file.
    name: "default"
    # Type-specific configuration.  For 'maildir', the only extra
    # configuration is the path to the maildir.
    path: "/home/user/mailbox/slack"
# Sender configuration.
sender:
  # The sendmail command to be used for mail that isn't to be sent
  # to Slack.
  fallback_sendmail: "/usr/sbin/sendmail"
  # The maildir directory to which bounce messages should be
  # written.
  bounce_dir: "/home/user/mailbox/slack-bounce"
```

If the configuration has been set up correctly, then running
`paws-receive` will fetch all messages from the Slack workspace and
write them to the maildir.  (If you don't want to fetch all messages,
use the `--since=YYYY-MM-DD` parameter to only fetch messages that
were posted on or after the specified date.)  Subsequent calls to
`paws-receive` will fetch any new messages that have been posted.

To send messages, configure your mail client to use `paws-send` as its
sendmail command (mail that is not for Slack will be passed off to the
`fallback_sendmail` command).  The recipient email addresses for Slack
conversations have the form `{conversation-name}@{workspace}.slack.alt`
(e.g.  `im/slackbot@myworkspace.slack.alt`).  Email addresses for
Slack users have the form `{user}@{workspace}.slack.alt` (e.g.
`slackbot@myworkspace.slack.alt`).  `paws-send-queued' must also be
run periodically, in order to resend messages that have been queued
due to temporary problems.

`paws-receive` takes an optional `--persist={n}` argument.  If
provided, then instead of exiting once messages have been received, it
will open a persistent connection to Slack and use that to listen for
new messages.  The argument to `--persist` is the number of minutes to
use as an interval for receiving new messages (messages are not
delivered immediately).  If the workspace is configured for many
channels that are only updated infrequently, using `--persist` will be
much more efficient than simply calling `paws-receive` periodically.
If using `--persist` in a scheduled job, `flock(1)` and its
`--nonblock` argument may be useful.

### Additional configuration options

 - `domain_name`: the base domain name to use for mail to/from Slack
   (defaults to 'slack.alt').

 - `workspaces`:
    - `modification_window`: the length of time (in seconds) prior to
      the timestamp of the last-retrieved message in which to check
      for edits to messages (defaults to 0).
    - `thread_expiry`: the length of time (in seconds) after which a
      thread should be considered 'expired', and will no longer be
      checked for new messages (defaults to 7 days).

 - `rate_limiting`:
    - `initial`: The initial query rate, as a multiple of the
      acceptable rate documented by Slack.  Defaults to 5, because
      Slack tolerates occasional bursts of traffic past the documented
      query rate.
    - `backoff`: The backoff rate.  When a `429 Too Many Requests`
      response is received, the relevant query rate will be divided by
      this number.  Defaults to 5, so that on receiving a 429 the
      query rate (if left as default) is set to the (non-bursty) value
      recommended by Slack.

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
 - If mail is sent to `paws-send` with multiple Slack users as
   recipients, a new group conversation containing those users will be
   created implicitly, the message will be sent to that conversation.
 - The `paws-aliases` command can be used to print a list of Slack
   user alias entries, for use with Mutt.  An alias username has the
   form:

    `slack-$workspace_name-$user_name`

### Bugs/problems/suggestions

See the [GitHub issue tracker](https://github.com/tomhrr/paws/issues).

### Licence

See LICENCE.
