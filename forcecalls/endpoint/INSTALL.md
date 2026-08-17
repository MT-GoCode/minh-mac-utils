# Run once on the Mac, WHILE YOU STILL HAVE SUDO

    brew install baresip

    sudo mkdir -p /etc/baresip /usr/local/libexec
    sudo cp config accounts /etc/baresip/          # edit accounts first: USERNAME/PASSWORD/YOURDOMAIN
    sudo cp watchdog.sh /usr/local/libexec/baresip-watchdog.sh
    sudo cp com.minh.baresip.plist /Library/LaunchAgents/
    sudo cp com.minh.baresip-watchdog.plist /Library/LaunchDaemons/

    sudo chown -R root:wheel /etc/baresip /Library/LaunchAgents/com.minh.baresip.plist \
        /Library/LaunchDaemons/com.minh.baresip-watchdog.plist /usr/local/libexec/baresip-watchdog.sh
    sudo chmod 644 /etc/baresip/config /Library/LaunchAgents/com.minh.baresip.plist \
        /Library/LaunchDaemons/com.minh.baresip-watchdog.plist
    sudo chmod 600 /etc/baresip/accounts
    sudo chmod 755 /usr/local/libexec/baresip-watchdog.sh

    sudo launchctl bootstrap gui/$(id -u) /Library/LaunchAgents/com.minh.baresip.plist
    sudo launchctl bootstrap system /Library/LaunchDaemons/com.minh.baresip-watchdog.plist

## Verify before dropping sudo

    grep -i registered /var/log/baresip.log        # should show 200 OK / registered
    pkill baresip && sleep 3 && pgrep baresip      # should come back
    launchctl bootout gui/$(id -u)/com.minh.baresip
    sleep 15 && pgrep baresip                      # watchdog should have re-bootstrapped it

If all three pass, revoke sudo.
