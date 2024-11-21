#!/bin/bash

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

echo "This will install shairport-sync, any required libraries, and configure the system to run it"
echo "This process will reboot the system as well. Press ctrl-c to cancel"

sleep 10

# General update and required package installation
NEEDRESTART_MODE=a apt update -y
NEEDRESTART_MODE=a apt upgrade -y
NEEDRESTART_MODE=a apt install -y --no-install-recommends build-essential git autoconf automake libtool libpulse-dev \
    libpopt-dev libconfig-dev libasound2-dev avahi-daemon libavahi-client-dev libssl-dev libsoxr-dev pulseaudio \
    libplist-dev libsodium-dev libavutil-dev libavcodec-dev libavformat-dev uuid-dev libgcrypt-dev xxd

# Installing / enabling NQPTP
cd /tmp
git clone https://github.com/mikebrady/nqptp.git
cd nqptp
autoreconf -fi
./configure --with-systemd-startup
make
make install
systemctl enable nqptp
systemctl start nqptp

# Installing ALAC
cd /tmp
git clone https://github.com/mikebrady/alac.git
cd alac
autoreconf -fi
./configure
make
make install
ldconfig

# Installing / enabling Shairport Sync
cd /tmp
git clone https://github.com/mikebrady/shairport-sync.git
cd shairport-sync
autoreconf -fi
./configure --sysconfdir=/etc --with-pa --with-apple-alac \
  --with-soxr --with-avahi --with-ssl=openssl --with-systemd --with-airplay-2
make
make install

# Adding pulseaudio service
echo "[Unit]
Description=PulseAudio system server

[Service]
Type=notify
ExecStart=pulseaudio --daemonize=no --system --realtime --log-target=journal

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/pulseaudio.service

# Updating Pulse Audio startup settings
sed -i 's|.*default-server .*|  default-server = /var/run/pulse/native|' /etc/pulse/client.conf
sed -i 's|.*autospawn .*|  autospawn = no|' /etc/pulse/client.conf

# Change default sample rate to standard 48000 suported by most USB DACs
sed -i 's/.*default-sample-r.*/  default-sample-rate = 48000/' /etc/pulse/daemon.conf

# Ensure every user is part of audio and pulse-access group so they can play sounds
for USR in $(users); do
  usermod -aG audio $USR
  usermod -aG pulse-access $USR
done

# Also add root and shairport-sync
usermod -aG audio root
usermod -aG pulse-access root
usermod -aG audio shairport-sync
usermod -aG pulse-access shairport-sync

# Create secure directory 
mkdir -p /home/shairport-sync
chown -R shairport-sync:shairport-sync /home/shairport-sync/

# Enable daemon and reboot to apply all changes
systemctl enable pulseaudio.service
systemctl enable shairport-sync
reboot -h now
