# Make sure the following variables are set in "vars.sh".
# PINAME - the name of the device
# NASNAME - account name for accessing NAS
# NASPASSWORD - account password for accessing NAS
touch vars.sh
chmod u+x vars.sh
. vars.sh


if [ `hostname` == 'pi' ]; then
# Install some tools
apt-get -q install -y apt-utils nano raspi-config cifs-utils raspi-copies-and-fills sudo unzip iptables tmux openvpn qbittorrent-nox

# Set up locale
sed -i \
	-re "s/^#.*(en_US.UTF-8.*)$/\1/g" \
	/etc/locale.gen

locale-gen --purge "en_US.UTF-8"
update-locale LANG=en_US.UTF-8
dpkg-reconfigure --frontend noninteractive locales

# Set up timezone
echo "Europe/Copenhagen" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

# Set up colours
cat >>~/.bashrc << \EOF
export LS_OPTIONS='--color=auto'
eval "`dircolors`"
alias ls='ls $LS_OPTIONS'
alias ll='ls $LS_OPTIONS -l'
alias l='ls $LS_OPTIONS -lA'
alias grep='grep --color'
export LANG=en_US.UTF-8
EOF
wget https://raw.githubusercontent.com/scopatz/nanorc/master/install.sh -q --show-progress -O- | sh

# Set up boot options
raspi-config nonint do_hostname $PINAME
raspi-config nonint do_boot_behaviour B2

# Increase the free memory limit (by default 3843)
# Change value for this boot
#sysctl -w vm.min_free_kbytes=8192
# Change value for subsequent boots
echo "vm.min_free_kbytes=8192" >> /etc/sysctl.conf

echo "Enter the new password for 'root'."
passwd root

# Reboot
# As the hostname is changed, the previous "if" will skip this part on the second run.
echo "Rebooting..."
reboot now
fi


# Set up log rotation and fix “action 17” rsyslog error.
sed -i '/# The named pipe \/dev\/xconsole/,$d' /etc/rsyslog.conf
logrotate /etc/logrotate.conf
service rsyslog restart

# Set up NAS
if [ ! -d /mnt/mycloud ]; then
	mkdir /mnt/mycloud
	chmod 666 /mnt/mycloud
fi

if ! grep -q "/mnt/mycloud" /etc/fstab; then
cat >>/etc/fstab << EOF
//wdmycloud/Public /mnt/mycloud cifs username=$NASNAME,password=$NASPASSWORD,file_mode=0777,dir_mode=0777,uid=root,gid=root,forceuid,forcegid 0 0
EOF
mount -a
fi
