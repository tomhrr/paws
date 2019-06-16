## paws

Send/receive Slack messages via email.  Supports sending messages to
Slack via a sendmail-like command, and receiving messages from Slack
into maildirs.

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
    # The relevant conversations from the workspace.  These have
    # the format {type}/{name}, where {type} is one of 'im',
    # 'mpim', 'group', or 'channel'.
    conversations:
      - "im/slackbot"
      - "channel/general"
    # The length of time (in seconds) prior to the timestamp of the
    # last-retrieved message in which to check for edits to messages
    # (defaults to 0).
    modification_window: 3600
# Receiver configuration.
receivers:
    # The type of the receiver.  ('maildir' is the only available
    # receiver type.
  - type: "maildir"
    # The workspace for the receiver.
    workspace: "apnicops"
    # Receiver-specific configuration.  For 'maildir', this is a
    # map from conversation name to maildir path.  A '*' can be
    # used to map all conversations to a single maildir path.
    conversation_to_maildir:
      "*": "/home/tomh/maildir/slack"
# Sender configuration.
sender:
  # The sendmail command to be used for mail that isn't to be sent
  # to Slack.
  fallback_sendmail: "/bin/true"
  # The maildir directory to which bounce messages should be
  # written.
  bounce_dir: "/home/tomh/maildir/slack-bounce"
```

Then, configure your MUA to use `paws-send` as its sendmail command
for sending mail (mail that is not for Slack will be passed off to the
`fallback_sendmail` command).  After that, run `paws-receive` to pull
new messages from Slack into the configured maildirs.

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

### Licence

See LICENCE.
