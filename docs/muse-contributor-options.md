# Muse Contributor Models And Launch Options

The native Muse picker offers Spark 1.3 Contributor, Wonder 1.0 Contributor and Wonder Full 1.0 Contributor.  Their wire IDs are `muse-spark-1.3-contributor`, `muse-wonder-1.0-contributor` and `muse-wonder-full-1.0-contributor`.  The native client retains those exact choices when an older host advertises only the base models; the updated sidecar preserves an exact contributor model's advertised wire spelling and alternate spelling.

Muse effort choices are `minimal`, `low`, `medium`, `high` and `xhigh`.  Contributor turns cannot use `max`.  A refused model or effort stops the turn before its prompt is sent.

The native effort menu excludes `none` and `ultra`.  Non-contributor engine menus place `max` after `xhigh`; engines without an effort setting keep the control hidden.

Hosts And Settings stores Allow Changes Without Asking and Contributor Mode preferences per host on this device.  Both initially default to on.  Contributor Mode controls Muse's launch flag independently of the contributor-only model picker.  Turning it off does not silently select a base model.  Queued messages retain the options selected when queued; later settings changes apply to later messages.

Native `muse acp` accepts `--contributor-mode on|off`.  YOLO uses the host's `--disable-sandbox --trust-workspace` options plus an advertised per-session `allowAll` approval mode.  With YOLO off, the bridge selects an advertised `onRequest` mode.  It does not pass the interactive CLI's `--yolo` flag to the ACP host.

The host process must restart to change these launch options.  The sidecar changes them only while its Muse work is idle, waits for the owned child to close and reloads durable thread IDs into the new host.  An unchanged policy can serve independent sessions concurrently.  A conflicting policy while another turn is active is refused without interrupting that turn.

The compatibility adapter does not implement the same host options.  Requests carrying these preferences require native ACP and cannot silently fall back to that adapter.  Older clients that omit the preferences restore the original launcher and environment, waiting for other work to finish before that change.  Native sessions with advertised approval modes return to on-request approval for those turns.

Validation uses synthetic ACP sessions for launch arguments, mode selection, idle replacement and busy refusal.  A separate metadata-only native echo probe established the installed host flags and approval-mode IDs without sending a prompt or making an account/model request.  Native application compilation and tests run through the hosted Apple workflows.
