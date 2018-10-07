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
export ELKVERSION=6.4.2

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

apt-get -qq install -y openjdk-8-jdk curl


#
# Elastic search
#

pushd .

# Get and extract to ~/elasticsearch
cd ~
wget https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-oss-$ELKVERSION.tar.gz
tar xzvf elasticsearch-oss-$ELKVERSION.tar.gz
rm elasticsearch-oss-$ELKVERSION.tar.gz
mv elasticsearch-$ELKVERSION elasticsearch

# Fix JNA library
rm elasticsearch/lib/jna-4.5.1.jar
wget -O elasticsearch/lib/jna-4.5.2.jar https://repo1.maven.org/maven2/net/java/dev/jna/jna/4.5.2/jna-4.5.2.jar

# Set up JVM
set JVM_OPT_PATH=elasticsearch/config/jvm.options
sed -i \
	-e "s/^-Xms.*$/-Xms200m/" \
	-e "s/^-Xmx.*$/-Xmx500m/" \
	-e "s/^[ #]*-Delasticsearch.json.allow_unquoted_field_names.*$/-Delasticsearch.json.allow_unquoted_field_names=true/" \
	$JVM_OPT_PATH
if [ $IS32BIT ]; then
	# For 32-bit architecture only
	sed -i \
		-e "s/^[ #]*-server.*$/#-server/" \
		-e "s/^[ #]*-Xss.*$/-Xss320k/" \
		$JVM_OPT_PATH
fi
sysctl -q -w vm.max_map_count=262144

# Set up Elastic Search
export ES_YML_PATH=elasticsearch/config/elasticsearch.yml
sed -i \
	-e "s/^.*cluster.name:.*$/cluster.name: \"elastic\"/" \
	-e "s/^.*node.name:.*$/node.name: \"$ELKHOST\"/" \
	-e "s/^.*network.host:.*$/network.host: 0.0.0.0/" \
	-e "s/^.*path.logs:.*$/path.logs: \/var\/log\/elasticsearch\//" \
	$ES_YML_PATH
cat >>$ES_YML_PATH <<EOF
# Cortesy Matthias Blaesing <mblaesing@doppel-helix.eu>
# Disable seccomp protection 
# (not sure if necessary, but is not supported on arm anyway)
bootstrap.system_call_filter: false
# Prevent bootstrap checks, which errs and stops the server
discovery.type: single-node
EOF

# Move to common place
mv elasticsearch /usr/bin/
mkdir -p /var/log/elasticsearch
chown -R elasticsearch:elasticsearch /var/log/elasticsearch /usr/bin/elasticsearch

popd >/dev/nul

# Test
runuser -u elasticsearch /usr/bin/elasticsearch/bin/elasticsearch -V | awk '{ print "Elastic search installed,", $1, $2 }'
# Takes around 10 minutes
#runuser -u elasticsearch /usr/bin/elasticsearch/bin/elasticsearch

# Deploy Elastic Search
cat >/lib/systemd/system/elasticsearch.service <<EOF
[Unit]
Description=Elastic Search
Documentation=https://www.elastic.co/guide/en/elasticsearch/current/index.html
Wants=network-online.target
After=network-online.target
[Service]
User=elasticsearch
ExecStart=/usr/bin/elasticsearch/bin/elasticsearch
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
echo "Elastic search:" `service elasticsearch status | grep Active | awk '{ print $2 }'`
sleep 10m
curl -s http://$ELKHOST:9200/?pretty



# Install JRuby via RVM
if [ -z `which ruby` ] || [ `ruby -v | awk '{ print $2 }'` != '9.1.10.0' ]; then
	gpg --keyserver hkp://keys.gnupg.net --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3
	curl -sSL https://get.rvm.io | bash -s stable --ruby=jruby-9.1.10.0
fi

# Install Logstash
pushd .
cd ~
wget https://artifacts.elastic.co/downloads/logstash/logstash-oss-$ELKVERSION.deb
#wget https://artifacts.elastic.co/downloads/logstash/logstash-$LATEST_INSTALLABLE_VERSION.deb
dpkg -i logstash-$ELKVERSION.deb
rm logstash-$ELKVERSION.deb
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



#
# Install Kibana from https://www.elastic.co/downloads/kibana-oss
#

https://www.elastic.co/downloads/kibana-oss
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
