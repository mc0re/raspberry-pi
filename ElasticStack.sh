# The file shall be executed as root.
# Use  sudo -s  or just  sudo <filename>
#-- Enter password
# The execution time is extrordinary long, so use tmux just in case.


#
# Define the variables
#

# This command gets the latest tagged version.
#   export ELKVERSION = `git ls-remote --tags https://github.com/elastic/logstash | tail -n 1 | sed -e "s/^[^ \t]\+[ \t]\+//"`
# This version was used when the script was developed.
export ELKVERSION=6.4.1
export LATEST_INSTALLABLE_VERSION=5.6.12

# Raspberry 2 is 32-bit, Raspberry 3 is 64-bit.
export IS32BIT=true

# The root of the source tree; here some tools also get installed.
export SRCROOTPATH=~/go

# The root of the Elastic Stack source tree.
export SRCPATH=$SRCROOTPATH/src/github.com/elastic

# This machine's name, not actual IP, as otherwise it'll be inaccessible from the outside.
export ELKHOST=`cat /etc/hostname`


#
# Install tools
#

# Get more RAM by creating in-memory zipped swap disks
if [ ! -f /usr/bin/zram.sh ]; then
	wget -q -O /usr/bin/zram.sh https://raw.githubusercontent.com/novaspirit/rpi_zram/master/zram.sh
	chmod +x /usr/bin/zram.sh
fi

/usr/bin/zram.sh


#
# Elastic stack: https://logz.io/blog/elk-stack-raspberry-pi/
#

# Install Java and tools
apt-get -qq install -y openjdk-8-jdk curl apt-transport-https ruby

# Install ant 1.9.8+
set ANT_VERSION=1.9.13
export ANT_HOME=/usr/bin/ant
pushd .
cd ~
wget -q http://mirrors.rackhosting.com/apache/ant/binaries/apache-ant-$ANT_VERSION-bin.tar.gz
tar -xzf apache-ant-$ANT_VERSION-bin.tar.gz
rm apache-ant-$ANT_VERSION-bin.tar.gz
mkdir $ANT_HOME
cp -r apache-ant-$ANT_VERSION/bin $ANT_HOME
cp -r apache-ant-$ANT_VERSION/lib $ANT_HOME
rm -rf apache-ant-$ANT_VERSION
popd >/dev/nul
export PATH=$PATH:$ANT_HOME/bin

# Install Elastic Search
wget -q https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-$LATEST_INSTALLABLE_VERSION.deb
dpkg -i elasticsearch-$LATEST_INSTALLABLE_VERSION.deb
rm elasticsearch-$LATEST_INSTALLABLE_VERSION.deb

# Set up Elastic Search
sed -i \
	-e "s/^.*cluster.name:.*$/cluster.name: \"elastic\"/" \
	-e "s/^.*node.name:.*$/node.name: \"$ELKHOST\"/" \
	-e "s/^.*network.host:.*$/network.host: $ELKHOST/" \
	-e "s/^.*path.logs:.*$/path.logs: \/var\/log\/elasticsearch\//" \
	/etc/elasticsearch/elasticsearch.yml
sed -i \
	-e "s/^-Xms.*$/-Xms200m/" \
	-e "s/^-Xmx.*$/-Xmx500m/" \
	-e "s/^[ #]*-Delasticsearch.json.allow_unquoted_field_names.*$/-Delasticsearch.json.allow_unquoted_field_names=true/" \
	/etc/elasticsearch/jvm.options
if [ $IS32BIT ]; then
	# For 32-bit architecture only
	sed -i \
		-e "s/^[ #]*-server.*$/#-server/" \
		-e "s/^[ #]*-Xss.*$/-Xss320k/" \
		/etc/elasticsearch/jvm.options
fi
cat >>/etc/elasticsearch/jvm.options <<EOF
-Djava.io.tmpdir=/var/lib/elasticsearch/tmp
-Djna.tmpdir=/var/lib/elasticsearch/tmp
-Djava.class.path=.:/usr/lib/arm-linux-gnueabihf/jni
-Djna.nosys=true
EOF
sysctl -q -w vm.max_map_count=262144

# This is a strange requirement only applicable to this (and some other?) version,
# because it lacks something.
ln -s /etc/elasticsearch/ /usr/share/elasticsearch/config

chown -R elasticsearch:elasticsearch /var/lib/elasticsearch /var/run/elasticsearch /var/log/elasticsearch /etc/elasticsearch

# Recompile JNA
apt-get -qq install -y autoconf automake libtool libx11-dev libxt-dev

pushd .
mkdir -p $SRCPATH/jna
cd $SRCPATH/jna
git clone https://github.com/java-native-access/jna.git
# Version 5.2.1
git checkout dc4c113ca49e98e597ce99ac0af44dcaa62f94c2
sed -i "s/^.*VERSION_NATIVE.*$/    String VERSION_NATIVE = \"5.1.0\";/" src/com/sun/jna/Version.java
# Runs for 70-75 minutes
ant -q dist
cp dist/*.jar /usr/share/elasticsearch/lib/
cd ~
rm -rf $SRCPATH/jna
mv /usr/share/elasticsearch/lib/jna-4.4.0-1.jar /usr/share/elasticsearch/lib/jna-4.4.0-1.jar.bak

# Recompile JNI library
cd ~
mkdir -p com/sun/jna/linux-arm
cp /usr/lib/arm-linux-gnueabihf/jni/libjnidispatch.so com/sun/jna/linux-arm/
zip -g /usr/share/elasticsearch/lib/libjnidispatch.jar -r com
rm -rf com
popd >/dev/nul

#ln -s /usr/lib/arm-linux-gnueabihf/jni/libjnidispatch.so /usr/lib/jvm/default-java/jre/lib/arm/libjnidispatch.so

# Establish a temporary directory with execution rights
mkdir -p /var/lib/elasticsearch/tmp
chown elasticsearch:elasticsearch /var/lib/elasticsearch/tmp

/usr/share/elasticsearch/bin/elasticsearch -V | awk '{ print "Elastic search installed,", $1, $2 }'
runuser -u elasticsearch /usr/share/elasticsearch/bin/elasticsearch

# Deploy Elastic Search
cat >/lib/systemd/system/elasticsearch.service <<EOF
[Unit]
Description=Elastic Search
Documentation=https://www.elastic.co/guide/en/elasticsearch/current/index.html
Wants=network-online.target
After=network-online.target
[Service]
ExecStart=/usr/share/elasticsearch/bin/elasticsearch
Restart=always
[Install]
WantedBy=multi-user.target
EOF

if [ `service elasticsearch status | grep Active | awk '{ print $2 }'` != 'active' ]; then
	systemctl enable elasticsearch.service 2>/dev/nul
	service elasticsearch start
else
	service elasticsearch restart
fi

# Wait for the server to start before testing
sleep 10m
echo "Elastic search:" `service elasticsearch status | grep Active | awk '{ print $2 }'`
curl -s http://$ELKHOST:9200/?pretty


# Install JRuby via RVM
if [ -z `which ruby` ] || [ `ruby -v | awk '{ print $2 }'` != '9.1.10.0' ]; then
	gpg --keyserver hkp://keys.gnupg.net --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3
	curl -sSL https://get.rvm.io | bash -s stable --ruby=jruby-9.1.10.0
fi

# Install Logstash
pushd .
cd ~
wget https://artifacts.elastic.co/downloads/logstash/logstash-$LATEST_INSTALLABLE_VERSION.deb
dpkg -i logstash-$LATEST_INSTALLABLE_VERSION.deb
rm logstash-$LATEST_INSTALLABLE_VERSION.deb
popd >/dev/nul

# Install Logstash via DEB - Complains about JRuby
#wget https://artifacts.elastic.co/downloads/logstash/logstash-$ELKVERSION.deb
#dpkg -i logstash-$ELKVERSION.deb
#-- Complains about JRuby
#rm logstash-$ELKVERSION.deb

# Install Logstash from APT - Cannot find armhf architecture
#wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
#echo "deb https://artifacts.elastic.co/packages/6.x/apt stable main" | tee -a /etc/apt/sources.list.d/elastic-6.x.list
#apt-get update
#-- Cannot find armhf architecture
#apt-get install -y logstash@$ELKVERSION

# Install Logstash from source code - Very many troubles compiling it, and to no avail.
#pushd .
#mkdir -p $SRCPATH
#cd $SRCPATH
#git clone https://github.com/elastic/logstash.git
#cd logstash
#git checkout $ELKVERSION
#export OSS=true
#apt-get -qq install -y rake bundler
#rake bootstrap
#popd >/dev/nul
#rm -rf $SRCPATH/logstash

# Rebuild JFFI library for ARM7
export JRUBYPATH=/usr/share/logstash/vendor/jruby/lib
pushd .
mkdir -p $SRCPATH/jnr
cd $SRCPATH/jnr
git clone --quiet https://github.com/jnr/jffi.git
cd jffi
ant -q jar
mkdir -p $JRUBYPATH/jni/arm-Linux
cp build/jni/libjffi-1.2.so $JRUBYPATH/jni/arm-Linux
#-- If the .so file is not generated, delete the complete jffi folder and reinstall again
cd $JRUBYPATH
zip -q -g jruby-complete-1.7.11.jar jni/arm-Linux/libjffi-1.2.so
popd >/dev/nul
rm -rf $SRCPATH/jnr

# Installation test; logstash takes around 30 minutes to start
echo "Logstash is installed and running" | \
	/usr/share/logstash/bin/logstash -e "input { stdin { } } output { elasticsearch { hosts => [\"$ELKHOST:9200\"] } }"
curl -s http://$ELKHOST:9200/logstash-*/_search?pretty | \
	grep "Logstash is installed and running" | \
	tail -n 1 | \
	awk -F ',' '{ print $4 ":" $5 }' | \
	awk -F ':' '{ gsub(/"/, "", $2); gsub(/"/, "", $4); gsub(/["}]/, "", $6); print $2 ":" $3 ":" $4 ":", $6 }'

# Setup Logstash
sed -i.original \
	-e "s/^.*http.host:.*$/http.host: $ELKHOST/" \
	-e "s/^.*http.port:.*$/http.port: 9600/" \
	/etc/logstash/logstash.yml

# Deploy Elastic Search
if [ `service logstash status | grep Active | awk '{ print $2 }'` != 'active' ]; then
	systemctl enable logstash.service 2>/dev/nul
	service logstash start
else
	service logstash restart
fi
echo "Logstash: " `service logstash status | grep Active | awk '{ print $2 }'`
curl http://$ELKHOST:9600/?pretty


# Install Node.JS via apt-get, only gets the latest version
#curl -sL https://deb.nodesource.com/setup_8.x | sudo -E bash -
#apt-get install -y nodejs@8.11.4-1nodesource1

# Install Node.JS from https://deb.nodesource.com/node_8.x/pool/main/n/nodejs/
pushd .
cd ~
wget https://deb.nodesource.com/node_8.x/pool/main/n/nodejs/nodejs_8.11.4-1nodesource1_armhf.deb
dpkg -i nodejs_8.11.4-1nodesource1_armhf.deb
rm nodejs_8.11.4-1nodesource1_armhf.deb
node -v
popd >/dev/nul

# Update NPM and pre-install some packages
apt-get -qq install -y npm
npm install npm -g
npm install -g eslint-plugin-import@2.8.0

# Install Yarn
curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add -
echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list
apt-get -qq update && apt-get -qq install -y yarn

# Install Kibana
# From source get the needed version
pushd .
mkdir -p $SRCPATH
cd $SRCPATH
git clone https://github.com/elastic/kibana.git
cd kibana
git checkout $ELKVERSION
# This one runs for over 1 hour
yarn kbn bootstrap

package.json:
	dependencies:
	add "eslint-plugin-import": "2.8.0",
	add "react-router": "^4.2.0",
	change "ngreact": "0.5.0",
	delete "@elastic/eui": "3.0.6",
	delete "x-pack"
	devDependencies:
	delete "chromedriver": "2.41.0",

yarn start --oss

copy
popd >/dev/nul
rm -rf $SRCPATH/kibana

cat >/lib/systemd/system/kibana.service <<EOF
[Unit]
Description=Kibana
[Service]
ExecStart=/opt/kibana/bin/kibana
StandardOutput=null
[Install]
WantedBy=multi-user.target
EOF

nano /opt/kibana/config/kibana.yml
#server.host: "$ELKHOST"
#elasticsearch.url: http://$ELKHOST:9200
#Remove the # at the front of the server.port setting found at the top of the file

systemctl enable kibana.service
service kibana start
service kibana status


#
# Beats: https://www.elasticice.net/?p=92
# Common GIT repository for all beats.
#

# Install GO 1.11
pushd .
cd ~
wget https://dl.google.com/go/go1.11.linux-armv6l.tar.gz
tar -C /usr/local -xzf go1.11.linux-armv6l.tar.gz
rm go1.11.linux-armv6l.tar.gz
export PATH=$PATH:/usr/local/go/bin:$SRCROOTPATH/bin
go version

# Install other tools
apt-get -qq install -y git gcc make python-pip
pip install virtualenv
go get github.com/magefile/mage

# Get the beats source code for the correct version
mkdir -p $SRCPATH
cd $SRCPATH
git clone https://github.com/elastic/beats.git
cd beats
git checkout $ELKVERSION

# Build Filebeat
cd $SRCPATH/beats/filebeat
make
make update
# This test requires manual intervention - Ctrl+C
#./filebeat -e -v

# Install Filebeat
mkdir /usr/share/filebeat /usr/share/filebeat/bin /etc/filebeat /var/log/filebeat /var/lib/filebeat
mv filebeat /usr/share/filebeat/bin
mv module /usr/share/filebeat/
mv modules.d/ /etc/filebeat/
cp filebeat.yml /etc/filebeat/
chmod 750 /var/log/filebeat
chmod 750 /etc/filebeat/
chown -R root:root /usr/share/filebeat/*
popd >/dev/nul

# Deploy Filebeat
cat >/lib/systemd/system/filebeat.service <<EOF
[Unit]
Description=Filebeat sends log files to Logstash or directly to Elasticsearch.
Documentation=https://www.elastic.co/products/beats/filebeat
Wants=network-online.target
After=network-online.target
[Service]
ExecStart=/usr/share/filebeat/bin/filebeat -c /etc/filebeat/filebeat.yml -path.home /usr/share/filebeat -path.config /etc/filebeat -path.data /var/lib/filebeat -path.logs /var/log/filebeat
Restart=always
[Install]
WantedBy=multi-user.target
EOF

sed -i.original \
	-e "s/^[ \t#]*host:.*:5601.*$/  host: \"$ELKHOST:5601\"/" \
	-e "s/^[ \t#]*hosts:.*:9200.*$/  #hosts: [\"$ELKHOST:9200\"]/" \
	-e "s/^[ \t#]*hosts:.*:5043.*$/  hosts: [\"$ELKHOST:5043\"]/" \
	/etc/filebeat/filebeat.yml

if [ `service filebeat status | grep Active | awk '{ print $2 }'` != 'active' ]; then
	systemctl enable filebeat.service 2>/dev/nul
	service filebeat start
else
	service filebeat restart
fi
echo "Filebeat: " `service filebeat status | grep Active | awk '{ print $2 }'`


# Build Metricbeat
pushd .
cd $SRCPATH/beats/metricbeat
make
make update

# Install Metricbeat
mkdir /usr/share/metricbeat /usr/share/metricbeat/bin /etc/metricbeat /var/log/metricbeat /var/lib/metricbeat
mv metricbeat /usr/share/metricbeat/bin
mv module /usr/share/metricbeat/
mv modules.d/ /etc/metricbeat/
cp metricbeat.yml /etc/metricbeat/
chmod 750 /var/log/metricbeat
chmod 750 /etc/metricbeat/
chown -R root:root /usr/share/metricbeat/*

# Deploy Metricbeat
cat >/lib/systemd/system/metricbeat.service <<EOF
[Unit]
Description=Metricbeat is a lightweight shipper for metrics.
Documentation=https://www.elastic.co/products/beats/metricbeat
Wants=network-online.target
After=network-online.target
[Service]
ExecStart=/usr/share/metricbeat/bin/metricbeat -c /etc/metricbeat/metricbeat.yml -path.home /usr/share/metricbeat -path.config /etc/metricbeat -path.data /var/lib/metricbeat -path.logs /var/log/metricbeat
Restart=always
[Install]
WantedBy=multi-user.target
EOF

nano /etc/metricbeat/metricbeat.yml
#-- Set up Logstash host to $ELKHOST and enabled metrics

/usr/share/metricbeat/bin/metricbeat setup -e -E output.elasticsearch.hosts=... -E setup.kibana.host=...

systemctl enable metricbeat.service
service metricbeat start
service metricbeat status

popd >/dev/nul
rm -rf $SRCPATH/beats
