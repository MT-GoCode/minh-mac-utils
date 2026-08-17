# Run once on the Mac, WHILE YOU STILL HAVE SUDO

    brew install baresip

    sudo mkdir -p /etc/baresip /usr/local/libexec
    sudo cp config accounts /etc/baresip/          # edit accounts first: USERNAME/PASSWORD/YOURDOMAIN
    sudo cp watchdog.sh /usr/local/libexec/forcecalls-endpoint-watchdog.sh
    sudo cp com.minh.forcecalls.endpoint.plist /Library/LaunchAgents/
    sudo cp com.minh.forcecalls.endpoint-watchdog.plist /Library/LaunchDaemons/

    sudo chown -R root:wheel /etc/baresip /Library/LaunchAgents/com.minh.forcecalls.endpoint.plist \
        /Library/LaunchDaemons/com.minh.forcecalls.endpoint-watchdog.plist /usr/local/libexec/forcecalls-endpoint-watchdog.sh
    sudo chmod 644 /etc/baresip/config /Library/LaunchAgents/com.minh.forcecalls.endpoint.plist \
        /Library/LaunchDaemons/com.minh.forcecalls.endpoint-watchdog.plist
    sudo chmod 600 /etc/baresip/accounts
    sudo chmod 755 /usr/local/libexec/forcecalls-endpoint-watchdog.sh

    sudo launchctl bootstrap gui/$(id -u) /Library/LaunchAgents/com.minh.forcecalls.endpoint.plist
    sudo launchctl bootstrap system /Library/LaunchDaemons/com.minh.forcecalls.endpoint-watchdog.plist

## Verify before dropping sudo

    grep -i registered /var/log/baresip.log        # should show 200 OK / registered
    pkill baresip && sleep 3 && pgrep baresip      # should come back
    launchctl bootout gui/$(id -u)/com.minh.forcecalls.endpoint
    sleep 15 && pgrep baresip                      # watchdog should have re-bootstrapped it

If all three pass, revoke sudo.
