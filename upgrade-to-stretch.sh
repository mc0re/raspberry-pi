# Upgrade Debian jessie to stretch
# Source: https://www.raspberrypi.org/blog/raspbian-stretch/

sudo -s
sed -i 's/jessie/stretch/g' /etc/apt/sources.list
sed -i 's/jessie/stretch/g' /etc/apt/sources.list.d/raspberrypi.org.list
apt-get update

# Answer ‘yes’ to any prompts.
# There may also be a point at which the install pauses while a page of information
# is shown on the screen – hold the ‘space’ key
# to scroll through all of this and then hit ‘q’ to continue.
apt-get -y dist-upgrade
apt -y autoremove
