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

# Raspberry 2 is 32-bit, Raspberry 3 is 64-bit.
export IS32BIT=true

# The root of the source tree; here some tools also get installed.
export SRCROOTPATH=~/go

# The root of the Elastic Stack source tree.
export SRCPATH=$SRCROOTPATH/src/github.com/elastic

# This machine's name, not actual IP, as otherwise it'll be inaccessible from the outside.
export ELKHOST=`cat /etc/hostname`

export BEATSPORT=5043

#
# Install tools
#

echo "Installing tools."

# Get more RAM by creating in-memory zipped swap disks
if [ ! -f /usr/bin/zram.sh ]; then
	wget -O /usr/bin/zram.sh https://raw.githubusercontent.com/novaspirit/rpi_zram/master/zram.sh -q --show-progress
	chmod +x /usr/bin/zram.sh
fi

cat >/lib/systemd/system/zram.service <<EOF
[Unit]
Description=ZRam swap
Documentation=https://github.com/novaspirit/rpi_zram
[Service]
Type=oneshot
ExecStart=-/usr/bin/zram.sh
ExecStop=-/sbin/swapoff -a
RemainAfterExit=true
[Install]
WantedBy=multi-user.target
EOF

if [ `service zram status | grep Active | awk '{ print $2 }'` != 'active' ]; then
	systemctl enable zram.service 2>/dev/nul
	service zram start
else
	service zram restart
fi

apt-get -qq install -y oracle-java8-jdk curl >/dev/nul
update-java-alternatives -s jdk-8-oracle-arm32-vfp-hflt >/dev/nul


#
# Elastic search
#

echo "Installing Elastic search $ELKVERSION."
pushd .

# Get and extract to ~/elasticsearch
cd ~
wget https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-oss-$ELKVERSION.tar.gz -q --show-progress
tar xzf elasticsearch-oss-$ELKVERSION.tar.gz
rm elasticsearch-oss-$ELKVERSION.tar.gz
mv elasticsearch-$ELKVERSION elasticsearch

# Fix JNA library
rm elasticsearch/lib/jna-4.5.1.jar
wget -O elasticsearch/lib/jna-4.5.2.jar https://repo1.maven.org/maven2/net/java/dev/jna/jna/4.5.2/jna-4.5.2.jar -q --show-progress

# Set up JVM
export JVM_OPT_PATH=elasticsearch/config/jvm.options
sed -i \
	-e "s/^-Xms.*$/-Xms384m/" \
	-e "s/^-Xmx.*$/-Xmx512m/" \
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
	-e "s/^.*path.data:.*$/path.data: \/media\/elasticsearch\//" \
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
mkdir -p /media/elasticsearch
adduser --system --group --home /media/elasticsearch --quiet logstash
chown -R elasticsearch:elasticsearch /var/log/elasticsearch /usr/bin/elasticsearch /media/elasticsearch

popd >/dev/nul

# Test
runuser -u elasticsearch /usr/bin/elasticsearch/bin/elasticsearch -V | awk '{ print "Elastic search installed,", $1, $2 }'

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
echo "Elastic search service:" `service elasticsearch status | grep Active | awk '{ print $2 }'`
sleep 1m
echo "Elastic search status: " `curl -s http://$ELKHOST:9200/_cat/health | awk '{ print $4 }'`


#
# Logstash
#

# Install JRuby via RVM for compiling JFFI library
echo "Installing tools for Logstash."
apt-get -qq install -y ant texinfo >/dev/nul
export PATH=$PATH:/usr/bin/ant/bin/

if [ -z `which ruby` ] || [ `ruby -v | awk '{ print $2 }'` != '9.1.10.0' ]; then
	gpg --keyserver hkp://keys.gnupg.net --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3
	curl -sSL https://get.rvm.io | bash -s stable --ruby=jruby-9.1.10.0
fi

# Install Logstash
echo "Installing Logstash $ELKVERSION."
pushd .

cd ~
wget https://artifacts.elastic.co/downloads/logstash/logstash-oss-$ELKVERSION.deb -q --show-progress
tar xzf logstash-oss-$ELKVERSION.tar.gz
rm logstash-oss-$ELKVERSION.tar.gz
mv logstash-$ELKVERSION logstash

# Rebuild JFFI library for ARM7
echo "Fixing JFFI library."
export JRUBYPATH=`pwd`/logstash/vendor/jruby/lib
pushd .
mkdir -p $SRCPATH/jnr
cd $SRCPATH/jnr
git clone --quiet https://github.com/jnr/jffi.git
cd jffi
git checkout 31547346513f6c7a35568903c47b0a3f6383035d
ant -q jar
mkdir -p $JRUBYPATH/jni/arm-Linux
cp build/jni/libjffi-1.2.so $JRUBYPATH/jni/arm-Linux
cd $JRUBYPATH
zip -q -g jruby.jar jni/arm-Linux/libjffi-1.2.so
zip -q -g logstash/logstash-core/lib/jars/jruby-complete-9.1.13.0.jar jni/arm-Linux/libjffi-1.2.so
popd >/dev/nul
rm -rf $SRCPATH/jnr

# Set up JVM
export JVM_OPT_PATH=logstash/config/jvm.options
sed -i \
	-e "s/^-Xms.*$/-Xms384m/" \
	-e "s/^-Xmx.*$/-Xmx384m/" \
	-e "s/^.*-Djava\.io\.tmpdir.*$/-Djava.io.tmpdir=\/media\/logstash\/tmp/" \
	$JVM_OPT_PATH
mkdir -p /media/logstash/tmp

# Setup Logstash
export LS_YML_PATH=logstash/config/logstash.yml
sed -i \
	-e "s/^.*node.name:.*$/node.name: \"$ELKHOST\"/" \
	-e "s/^.*http.host:.*$/http.host: \"0.0.0.0\"/" \
	-e "s/^.*http.port:.*$/http.port: 9600/" \
	-e "s/^.*path.logs:.*$/path.logs: \/var\/log\/logstash\//" \
	$LS_YML_PATH
mkdir -p /var/log/logstash

# Move to common place
mv logstash /usr/bin/
popd >/dev/nul

adduser --system --group --home /media/logstash --quiet logstash
chown -R logstash:logstash /var/log/logstash /usr/bin/logstash /media/logstash
#setfacl -Rm d:u:logstash:rwX,u:logstash:rwX /media/logstash

# Installation and communication test
echo "Installation test, wait for 1 hour - JVM start-up time."
echo "`date`: Logstash $ELKVERSION is installed and running" | \
	runuser -u logstash -- \
	/usr/bin/logstash/bin/logstash -e "input { stdin { } } output { elasticsearch { hosts => [\"$ELKHOST:9200\"] } }"
curl -s http://$ELKHOST:9200/logstash-*/_search?pretty | \
	grep "is installed and running" | \
	tail -n 1
export ENTRYID=`curl -s http://$ELKHOST:9200/logstash-*/_search?pretty | grep "_id" | awk '{ gsub(/[",]/, "", $3); print $3 }'`
curl -X DELETE "$ELKHOST:9200/logstash-`date +%Y.%m.%d`/_doc/$ENTRYID?pretty"
	
# Set up pipelines
mkdir -p /etc/logstash/conf.d
chown -R logstash:logstash /etc/logstash/conf.d

cat >/etc/logstash/conf.d/beat.conf <<EOF
input {
  beats { port => "$BEATSPORT" }
}
output {
  elasticsearch {
    hosts => ["$ELKHOST:9200"]
    index => "%{[@metadata][beat]}-%{+YYYY.MM.dd}"
  }
}
EOF

chmod o+r /var/log/syslog
cat >/etc/logstash/conf.d/syslog.conf <<EOF
input {
  file {
    path => "/var/log/syslog"
    type => "syslog"
  }
}
filter {
  if [type] == "syslog" {
    grok {
      match => { "message" => "%{SYSLOGTIMESTAMP:syslog_timestamp} %{SYSLOGHOST:syslog_hostname} %{DATA:syslog_program}(?:\[%{POSINT:syslog_pid}\])?: %{GREEDYDATA:syslog_message}" }
    }
    grok {
      match => { "syslog_message" => "\[%{TIMESTAMP_ISO8601:syslog_iso_timestamp}.*" }
    }
    date {
	  locale => "en"
      match => [ "syslog_timestamp", "MMM  d HH:mm:ss", "MMM dd HH:mm:ss" ]
      target => "entry_time"
    }
    date {
	  locale => "en"
      match => [ "syslog_iso_timestamp", "ISO8601" ]
      target => "entry_time"
    }
  }
}
output {
  if [message] =~ /elasticsearch.*\[INFO/ {
  } else {
    elasticsearch {
      hosts => ["$ELKHOST:9200"]
      index => "syslog-%{+YYYY.MM.dd}"
	}
  }
}
EOF

cat >>/usr/bin/logstash/config/pipelines.yml <<EOF
 - pipeline.id: beats
   pipeline.workers: 1
   path.config: "/etc/logstash/conf.d/beat.conf"
 - pipeline.id: syslog
   pipeline.workers: 1
   path.config: "/etc/logstash/conf.d/syslog.conf"
EOF

# Deploy Elastic Search
cat >/lib/systemd/system/logstash.service <<EOF
[Unit]
Description=Logstash
Documentation=https://www.elastic.co/guide/en/logstash/current/index.html
Wants=network-online.target
After=network-online.target
[Service]
User=logstash
ExecStart=/usr/bin/logstash/bin/logstash -r --config.reload.interval 1m
Restart=always
[Install]
WantedBy=multi-user.target
EOF

if [ `service logstash status | grep Active | awk '{ print $2 }'` != 'active' ]; then
	systemctl enable logstash.service 2>/dev/nul
	service logstash start
else
	service logstash restart
fi
echo "Logstash service: " `service logstash status | grep Active | awk '{ print $2 }'`
echo "Waiting for 1 hour for initialization, then a JSON text shall be printed."
sleep 60m
curl http://$ELKHOST:9600/?pretty


exit
#
# Kibana
#

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
apt-get -qq install -y npm >/dev/nul
npm install npm -g
npm install -g eslint-plugin-import@2.8.0

# Install Yarn
curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add -
echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list
apt-get -qq update && apt-get -qq install -y yarn >/dev/nul

# Install Kibana from https://www.elastic.co/downloads/kibana-oss
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
apt-get -qq install -y git gcc make python-pip >/dev/nul
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

sed -i \
	-e "s/^[ \t#]*- \/var\/log\/.*$/    - \/var\/log\/syslog/" \
	-e "s/^[ \t#]*output.elasticsearch:.*$/#output.elasticsearch:/" \
	-e "s/^[ \t#]*hosts:.*:9200.*$/  #hosts: [\"$ELKHOST:9200\"]/" \
	-e "s/^[ \t#]*output.logstash:*.$/output.logstash:/" \
	-e "s/^[ \t#]*hosts:.*:$BEATSPORT.*$/  hosts: [\"$ELKHOST:$BEATSPORT\"]/" \
	-e "s/^[ \t#]*host:.*:5601.*$/  host: \"$ELKHOST:5601\"/" \
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
