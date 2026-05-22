#!/bin/bash

# setup.sh
# Soracom Starter Kit
# Raspberry Pi + Huawei MS2131i and EG25-G connection setup
# Version 2025-09-25

setup_modem()
{
for n in {1..5}
do
    usb_modeswitch -v 12d1 -p 14fe -J &>> /var/log/soracom_setup.log
    sleep 2
    if lsusb | grep 12d1:1506 > /dev/null
    then
        return 0
    fi
done
return 1
}

test_modem()
{
for n in {1..30}
do
    if mmcli -L | grep 'MS2131\|QUECTEL' > /dev/null
    then
        return 0
    fi
    sleep 2
done
return 1
}

setup_route()
{
cat <<EOF > /etc/NetworkManager/dispatcher.d/90.soracom_route
#!/bin/bash

if [ "\$2" == "up" ]
then
    if [ "\$1" == "ppp0" ]
    then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Modem connected on ppp0" >> /var/log/soracom_status.log

        /sbin/route add -net 100.127.0.0/16 dev ppp0 metric 0
        /sbin/route add -net 54.250.252.67/32 dev ppp0 metric 0
        /sbin/route add -net 54.250.252.99/32 dev ppp0 metric 0
        logger -s "Added Soracom routes 100.127.0.0/16, 54.250.252.67/32, and 54.250.252.99/32 for ppp0 with metric 0"
    elif [ "\$1" == "wwan0" ]
    then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Modem connected on wwan0" >> /var/log/soracom_status.log

        gateway=\$( route -n | grep '^0.0.0.0 .* wwan0\$' | head -1 | awk '{print \$2}' )

        /sbin/route add -net 100.127.0.0/16 gw \$gateway dev wwan0 metric 0
        /sbin/route add -net 54.250.252.67/32 gw \$gateway dev wwan0 metric 0
        /sbin/route add -net 54.250.252.99/32 gw \$gateway dev wwan0 metric 0
        logger -s "Added Soracom routes 100.127.0.0/16, 54.250.252.67/32, and 54.250.252.99/32 for wwan0 with metric 0"
    # Specific to Ubuntu or other OS using predictable-interface-names
    elif [[ "\$1" == *"wwp1s0"* ]]
    then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Modem connected on \$1" >> /var/log/soracom_status.log
        /sbin/ip route add 100.127.0.0/16 dev \$1 metric 0
        /sbin/ip route add 54.250.252.67/32 dev \$1 metric 0
        /sbin/ip route add 54.250.252.99/32 dev \$1 metric 0
        logger -s "Added Soracom routes 100.127.0.0/16, 54.250.252.67/32, and 54.250.252.99/32 for \$1 with metric 0"
    fi
elif [ "\$2" == "down" ] && [ "\$1" == "ttyUSB2" ]
then
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Modem disconnected" >> /var/log/soracom_status.log

    /sbin/route del -net 100.127.0.0/16
    /sbin/route del -net 54.250.252.67/32
    /sbin/route del -net 54.250.252.99/32
    logger -s "Deleted Soracom routes 100.127.0.0/16, 54.250.252.67/32, and 54.250.252.99/32"
fi
EOF

chmod +x /etc/NetworkManager/dispatcher.d/90.soracom_route

touch /var/log/soracom_status.log
}

# Showing progress with a bash spinner
# https://github.com/marascio/bash-tips-and-tricks/tree/master/showing-progress-with-a-bash-spinner
spin()
{
    local pid=$1
    local spinner='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinner#?}
        printf " [%c]  " "$spinner"
        local spinner=$temp${spinner%"$temp"}
        sleep 0.25
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}



# Show usage
show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -H           Headless execution (setup without device)
  -h           Show this help message

Examples:
  $0                           # Setup with default settings
  $0 -H                       # Headless execution (setup without device)
EOF
}

# Parse command line options
HEADLESS=false
OPTIND=1

while getopts "d:NHh" opt; do
    case $opt in
        H)
            HEADLESS=true
            ;;
        h)
            show_usage
            exit 0
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            show_usage
            exit 1
            ;;
    esac
done

shift $((OPTIND-1))

# Begin setup
if [ $UID != 0 ]
then
    echo "You must run this script as root. Please try again using \"sudo ./setup.sh\""
    exit 1
fi

DEFAULT_APN="soracom.io"
DEFAULT_USERNAME="sora"
DEFAULT_PASSWORD="sora"

APN=${1:-$DEFAULT_APN}
USERNAME=${2:-$DEFAULT_USERNAME}
PASSWORD=${3:-$DEFAULT_PASSWORD}

# Install NetworkManager and usb_modeswitch, if NetworkManager and usb_modeswitch are not installed.
echo "---"
echo "Installing required packages (this may take a few minutes)..."
if [ ! -x /usr/bin/nmcli -o ! -x /usr/sbin/usb_modeswitch ]
then
    printf "Updating package list..."
    (apt-get update &>> /var/log/soracom_setup.log) &
    spin $!
    printf " Done!\n"
    printf "Installing network-manager..."
    (apt-get install -y network-manager &>> /var/log/soracom_setup.log) &
    spin $!
    printf " Done!\n"
    printf "Installing usb-modeswitch..."
    (apt-get install -y usb-modeswitch &>> /var/log/soracom_setup.log) &
    spin $!
    printf " Done!\n"
else
    echo "Required packages already installed!"
fi

# add below code to detect NetworkManager is enabled or not.
if ! systemctl is-enabled --quiet NetworkManager; 
then
    echo "NetworkManager is not enabled. Enabling it now..."
    systemctl enable NetworkManager
fi


# add below code to detect NetworkManager is running or not.
if systemctl is-active --quiet NetworkManager; then
    echo "NetworkManager is running."
else
    echo "NetworkManager is installed but not running. Starting it now..."
    printf "Starting NetworkManager..."
    (service NetworkManager start || exit 1) &
    spin $!
    printf " Done!\n"
#    systemctl start NetworkManager
fi

if ! mmcli --version > /dev/null
then
    printf "Starting ModemManager..."
    (service ModemManager start || exit 1) &
    spin $!
    printf " Done!\n"
fi
echo
sleep 1

# to support debian/raspbian 11 (bullseye) or later
if [ -f /etc/os-release ]
then
  bullseye_or_later="$(
    source /etc/os-release
    if { [ "$ID" = "raspbian" ] || [ "$ID" = "debian" ]; } && [ "$VERSION_ID" -ge 11 ]
    then
      echo "true"
    else
      echo "false"
    fi
  )"

  denyinterfaces_instruction="denyinterfaces wwan0"
  if [ "$bullseye_or_later" = "true" ] && ! grep -E "^$denyinterfaces_instruction" /etc/dhcpcd.conf > /dev/null 2>&1
  then
    echo "$denyinterfaces_instruction" >> /etc/dhcpcd.conf
  fi
fi

# Setup modem
if [ "$HEADLESS" = "false" ]
then
    echo "---"
    echo "Setting up modem..."
    printf "Please plug in your modem now: "
    until lsusb | grep '12d1\|2c7c' > /dev/null
    do
        sleep 1
    done
    printf "Modem detected!\n"
    if lsusb | grep '12d1:1506\|2c7c:0125' > /dev/null
    then
        :
    elif lsusb | grep 12d1:14fe > /dev/null
    then
        printf "Modem detected in mass storage mode. Switching modes..."
        (setup_modem) &
        spin $!
        if [ "$?" = "1" ]
        then
            echo "Modem was not setup properly. Please unplug the modem, then plug it in and try again."
            exit 1
        else
            printf " Done!\n"
        fi
    fi
    printf "Waiting until the modem is ready (this may take a minute)..."
    (test_modem) &
    spin $!
    if [ "$?" = "1" ]
    then
        echo "Modem was not initialized properly. Please wait or reboot, then try again."
        exit 1
    fi
    printf " Done!\n"
    echo
    sleep 1
else
    echo "---"
    echo "Skipping modem detection and setup (headless execution)"
fi

# Add Soracom route rule
echo "---"
echo "Adding Soracom route rule..."
if [ -f /etc/NetworkManager/dispatcher.d/90.soracom_route ]
then
    echo "Soracom route rule already exists!"
elif [[ "$APN" == *"soracom.io" ]]; then
    setup_route
    echo "Soracom route rule created: /etc/NetworkManager/dispatcher.d/90.soracom_route"
else
    echo "Skipped to add route"
fi
echo
sleep 1


# Add Soracom connection profile
echo "---"
echo "Adding Soracom connection profile..."
if nmcli con show soracom &> /dev/null
then
    echo "Soracom connection profile already exists!"
    status=``
    if [ "$(nmcli dev | grep soracom | awk '{print $3}')" == "disconnected" ]
    then
        printf "Bringing up connection..."
        (nmcli con up soracom &>> /var/log/soracom_setup.log) &
        spin $!
        printf " Done!\n"
    fi
else
    nmcli con add type gsm ifname "*" con-name soracom apn $APN user $USERNAME password $PASSWORD &>> /var/log/soracom_setup.log
    echo "Connection profile added: soracom"
fi
echo
sleep 1

# Ensure to run the modem at the initial timing.
# After rebooting, `denyinterfaces wwan0` in `dhcpcd.conf` does the same thing.
if [ "$HEADLESS" = "false" ]
then
    if [ "$bullseye_or_later" = "true" ]
    then
    ifconfig wwan0 down
    echo "Y" > /sys/class/net/wwan0/qmi/raw_ip
    ifconfig wwan0 up
    nmcli con down soracom
    nmcli con up soracom
    fi
fi

if [ "$HEADLESS" = "false" ]
then
    CLOSING_MESSAGE=$(printf "In a moment, your modem status light should change to solid blue or green,\nindicating that you are now successfully connected to Soracom!")

else
    CLOSING_MESSAGE=$(printf "Your raspberry pi is now set up to connect to Soracom!\nYou can now use the modem for Soracom services.")

fi

# Finish script
cat <<EOF
---
Setup complete!

${CLOSING_MESSAGE}

Tips:
- When you reboot or plug in your modem, it will automatically connect.
- When wifi is connected, the modem will be used only for Soracom services.
- You can manually disconnect and reconnect the modem using:
    sudo nmcli con down soracom
    sudo nmcli con up soracom

EOF