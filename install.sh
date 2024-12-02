#!/bin/bash

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

echo "This will install shairport-sync, any required libraries, and configure the system to run it"
echo "This process will reboot the system as well. Press ctrl-c to cancel"

# sleep 10

# General update and required package installation
NEEDRESTART_MODE=a apt update -y
NEEDRESTART_MODE=a apt upgrade -y
NEEDRESTART_MODE=a apt install -y --no-install-recommends build-essential git autoconf automake libtool \
    libpopt-dev libconfig-dev libasound2-dev avahi-daemon libavahi-client-dev libssl-dev libsoxr-dev \
    libplist-dev libsodium-dev libavutil-dev libavcodec-dev libavformat-dev uuid-dev libgcrypt-dev xxd \
    libsndfile1 libsndfile1-dev alsa-utils nano less cron

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
./configure --sysconfdir=/etc --with-alsa --with-apple-alac --with-convolution \
  --with-soxr --with-avahi --with-ssl=openssl --with-systemd --with-airplay-2
make
make install

echo '#!/bin/bash
trap : SIGTERM SIGINT

echo $$

/usr/bin/aplay -q -D keepawake -f U8 /dev/zero 2>&1 &
APLAY_PID=$!

wait $APLAY_PID

if [[ $? -gt 128 ]]
then
    kill $APLAY_PID
fi' > /usr/local/bin/alsa-keepawake

echo '#!/bin/bash

pkill alsa-keepawake' > /usr/local/bin/disable-keepawake

echo '#!/bin/bash

disable-keepawake
alsa-keepawake' > /usr/local/bin/enable-keepawake

chmod +x /usr/local/bin/*keep*

echo 'pcm.!default {
    type plug
    slave.pcm "dmixer"
}

ctl.!default {
    type hw
    card Generic
}

pcm.shairplay {
    type plug
    slave.pcm "dmixer"
}

pcm.dmixer {
    type dmix
    ipc_key 697           # Any unique num
    slave {
        pcm "hw:1,0"      # Card # of USB Audio from aplay -l
        period_time 0     # From shairport docs
        period_size 1920  # From shairport docs
        buffer_size 19200 # From shairport docs
        rate 96000        # Value from valid settings of a USB DAC, adjust as needed/desired
        format S24_3LE    # Value from valid settings of a USB DAC, adjust as needed/desired
     }
}

pcm.keepawake {
    type plug
    slave.pcm {
        type softvol
        slave.pcm "dmixer"
        min_dB -10.0         # Emperical value
        max_dB -9.0          # Has to be larger than min
        control {
            name "Keep Awake, feed with /dev/zero"
            card 1
        }
    }
}

' > /etc/asound.conf

# Ensure every user is part of audio group so they can play sounds
for USR in $(users); do
  usermod -aG audio $USR
done

# Also add root and shairport-sync
usermod -aG audio root
usermod -aG audio shairport-sync

read -p "Enter server name (leave blank to skip): " SERVER_NAME

if [ ! -z "$SERVER_NAME" ]; then
    perl -i -0pe "s|(general =[^\}]*)//(\s+name = )\"[^;]*;|\1\2\"$SERVER_NAME\";|gms" /etc/shairport-sync.conf
fi

perl -i -0pe 's|(general =[^\}]*)//(\s+interpolation = )"[^;]*;|\1\2"soxr";|gms' /etc/shairport-sync.conf
perl -i -0pe 's|(general =[^\}]*)//(\s+playback_mode = )"[^;]*;|\1\2"mono";|gms' /etc/shairport-sync.conf
perl -i -0pe 's|(general =[^\}]*)//(\s+volume_control_profile = )"[^;]*;|\1\2"dasl_tapered";|gms' /etc/shairport-sync.conf
perl -i -0pe 's|(sessioncontrol =[^\}]*)//(\s+run_this_before_entering_active_state = )"[^;]*;|\1\2"/usr/local/bin/enable-keepawake";|gms' /etc/shairport-sync.conf
perl -i -0pe 's|(sessioncontrol =[^\}]*)//(\s+run_this_after_exiting_active_state = )"[^;]*;|\1\2"/usr/local/bin/disable-keepawake";|gms' /etc/shairport-sync.conf
perl -i -0pe 's|(alsa =[^\}]*)//(\s+output_device = )"[^;]*;|\1\2"shairplay";|gms' /etc/shairport-sync.conf
perl -i -0pe 's|(alsa =[^\}]*)//(\s+output_format = )"[^;]*;|\1\2"S24_3LE";|gms' /etc/shairport-sync.conf

read -p "Enter restart minute for daily restart: " RESTART_MIN

if [ "$RESTART_MIN" -lt 0 ] || [ "$RESTART_MIN" -gt 60 ]; then
  RESTART_MIN=0
fi

(echo "$RESTART_MIN 3 * * * systemctl restart shairport-sync >/dev/null 2>&1") | crontab -

# Enable daemon and reboot to apply all changes
systemctl enable shairport-sync
reboot -h now
