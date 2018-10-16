if [ `hostname` == 'pi' ]; then
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
wget https://raw.githubusercontent.com/scopatz/nanorc/master/install.sh -O- | sh

# Set up boot options
raspi-config nonint do_hostname netserver-pi
raspi-config nonint do_boot_behaviour B2

# Reboot
# As the hostname is changed, the previous "if" will skip this part on the second run.
reboot now
fi
