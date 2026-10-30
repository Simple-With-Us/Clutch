# Muse Login And Mac Layout

The Mac app now has one Workspace for coding threads and a separate Agent Chat for the relay conversation.  The old Chat tab contained a second workspace, making the two tabs appear interchangeable.

Workspace uses a single engine menu and a separate row for model and reasoning effort.  Its sidebar leaves room for the transcript, and failed thread loads no longer put a bot's entire initial prompt into the error banner.

Muse history can be listed without a usable account login, but opening or creating a session can require authentication.  The Sign In To Muse action now calls the agent's advertised ACP authenticate method and presents its HTTPS device-login instructions.  The user chooses to open the displayed host, approves in the browser, then explicitly opens the thread or submits the message again.  Credentials stay inside Muse; Clutch does not ask for an API key or keychain password.

Authentication attempts are bounded, bearer-protected, and scoped to the active Muse process.  A completed URL interaction is not treated as a completed account login until the authenticate request succeeds.  The native app explains when a host is too old to support the login route.

The screenshot denial reported during this work was investigated separately.  No capture protection was found in Clutch, the checked managed preferences had no screenshot restriction, and the Mac reported no MDM enrollment.  The owner later supplied a successful screenshot with the revised app open; the earlier restriction's cause remains unconfirmed.

References: [Muse ACP login](https://meta-models.github.io/muse-code-sdk/next/guides/editors-acp/#log-in), [ACP URL elicitation](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/docs/rfds/elicitation.mdx).
