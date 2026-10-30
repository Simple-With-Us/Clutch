# Muse Desktop Session

Muse's saved login was usable from a desktop-launched process while the same executable failed to access Keychain from the server's background context.  A read-only comparison found unlocked keychains in the desktop context and locked keychains in the SSH context.  Running `muse usage` through a temporary desktop app succeeded with the existing login.  The credential item had already allowed all applications, so adding another application to that list did not explain the failure.

The Mac bundle now includes an on-demand `ClutchMuseACP.app` helper.  The native Muse launcher uses it to start Muse in the desktop security session.  The existing HTTP sidecar and remote client contract stay the same, and the helper runs independently of the frontend window.

The Python broker creates a private directory and Unix socket, starts the exact bundled helper through LaunchServices, and exchanges bounded launch metadata before relaying opaque ACP bytes.  Both ends check the socket peer's user identity.  The launch metadata contains the selected executable, working directory, arguments and executable search path; it contains no credential values.  Muse continues to own and read its saved login.

The helper supervises its Muse child and process group.  Connection loss and normal shutdown close input and terminate that group with a bounded grace period.  The helper does not add a LaunchAgent, pm2 job, public port or persistent listener.  Deliberately detached tool processes remain outside normal process-group cleanup.

Linux, explicit API-key configurations, forced adapter mode and hosts without the helper retain their existing direct launch behavior.  Once GUI launch has started, failures are reported instead of retrying the request through another runtime.

The Mac installer packages and signs the helper before replacing the installed application.  Native transport and process-cleanup smoke tests run against the packaged helper on the Mac without authenticating to Muse.  The existing Mac release workflow invokes the same builder; adding helper-only path filters and an explicit CI smoke step requires the authorized workflow publisher, because the CODEX publication route refused workflow-file changes.  Live acceptance additionally requires opening a fresh native Muse ACP session through the installed launcher, using the existing account.

The separate `codesign` password popup named a custom build keychain.  No active signing process remained to identify its target, and the installed Clutch app was confirmed ad-hoc signed.  The desktop check later found that build keychain unlocked; no keychain password or credential value was requested by this investigation.

References: [Unix socket peer credentials](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/getpeereid.3.html), [spawn process groups](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/posix_spawnattr_setpgroup.3.html).
