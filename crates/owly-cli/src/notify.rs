//! AirDrop consent through a desktop notification (`owly receive --notify`),
//! so the accept/deny prompt reaches a graphical session instead of a
//! terminal. The notification carries an Accept action: invoking it accepts,
//! dismissing it or letting it expire declines.

use std::collections::HashMap;
use std::time::Duration;

use futures_util::stream::StreamExt;
use zbus::zvariant::Value;

#[zbus::proxy(
    interface = "org.freedesktop.Notifications",
    default_service = "org.freedesktop.Notifications",
    default_path = "/org/freedesktop/Notifications"
)]
trait Notifications {
    #[allow(clippy::too_many_arguments)]
    fn notify(
        &self,
        app_name: &str,
        replaces_id: u32,
        app_icon: &str,
        summary: &str,
        body: &str,
        actions: &[&str],
        hints: HashMap<&str, &Value<'_>>,
        expire_timeout: i32,
    ) -> zbus::Result<u32>;

    #[zbus(signal)]
    fn action_invoked(&self, id: u32, action_key: String) -> zbus::Result<()>;

    #[zbus(signal)]
    fn notification_closed(&self, id: u32, reason: u32) -> zbus::Result<()>;
}

/// Asks the user through the session's notification server and returns whether
/// they accepted. Any dbus problem, or no answer within `timeout`, is a
/// decline, so a missing or broken server never auto-accepts.
pub async fn consent(summary: &str, body: &str, timeout: Duration) -> bool {
    match ask(summary, body, timeout).await {
        Ok(accepted) => accepted,
        Err(e) => {
            eprintln!("couldn't ask over notifications ({e}); declining");
            false
        }
    }
}

async fn ask(summary: &str, body: &str, timeout: Duration) -> zbus::Result<bool> {
    let conn = zbus::Connection::session().await?;
    let proxy = NotificationsProxy::new(&conn).await?;

    // Subscribe before notifying so a quick click can't race us.
    let mut invoked = proxy.receive_action_invoked().await?;
    let mut closed = proxy.receive_notification_closed().await?;

    let hints: HashMap<&str, &Value<'_>> = HashMap::new();
    let id = proxy
        .notify(
            "owly",
            0,
            "phone",
            summary,
            body,
            &["default", "Accept", "accept", "Accept"],
            hints,
            timeout.as_millis() as i32,
        )
        .await?;

    let decide = async {
        loop {
            tokio::select! {
                biased;
                Some(sig) = invoked.next() => {
                    let args = sig.args()?;
                    if args.id == id {
                        return Ok(args.action_key == "default" || args.action_key == "accept");
                    }
                }
                Some(sig) = closed.next() => {
                    let args = sig.args()?;
                    if args.id == id {
                        return Ok(false);
                    }
                }
                else => return Ok(false),
            }
        }
    };

    // The server should expire it on its own, but back that with our deadline.
    match tokio::time::timeout(timeout + Duration::from_secs(2), decide).await {
        Ok(result) => result,
        Err(_) => Ok(false),
    }
}
