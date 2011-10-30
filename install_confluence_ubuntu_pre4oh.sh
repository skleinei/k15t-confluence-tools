#!/bin/bash
# This script sets up a confluence standalone installation on an Ubuntu server
# It installs all dependencies, creates a system and postgres user and creates an init.d script
# In ~confluence, a symlink called confluece-std is created to the extracted standalone version. This symlink can be updated when later versions are installed.

print() {
	echo -e "\033[32m"
	echo "$@"
	echo -ne "\033[m"
}

echo_into() {
	file="$1"
	while read line; do
		! grep -qxF "$line" "$file" && echo "$line" >> "$file"
	done
}

check_pkg() {
	if ! which "$1" >/dev/null 2>&1; then
		echo "$3"
		apt-get install -y "$2"
	fi
}

if hostname -i | grep -q '^127\.'; then
	print "Warning: hostname -i returns $(hostname -i)."
	print "Please set up your actual IP address in /etc/hosts."
fi

if [ "$(apt-cache search ^sun-java6-jdk$ | wc -l)" -lt 1 ]; then
	print "Package sun-java6-jdk not found. This is suspicious."
	print "Perhaps you need to enable the partner repository in /etc/apt/sources.list and then run apt-get update?"
	exit 1
fi

print -n "Please enter the confluence version you would like to download (for example: 3.4.6, see http://www.atlassian.com/software/confluence/ConfluenceDownloadCenter.jspa; leave empty to skip): "
read CONFLUENCE_VERSION

if [ ! -z "$CONFLUENCE_VERSION" ]; then
	while true; do
		print -n "Please define a password for the confluence database user: "
		read -s CONFLUENCE_DB_PASSWD
		print -n "Retype: "
		read -s CONFLUENCE_DB_PASSWD2

		[[ "$CONFLUENCE_DB_PASSWD" != "$CONFLUENCE_DB_PASSWD2" ]] && print "Mismatch!" || break
	done
fi

print -n "Please go to http://sourceforge.net/projects/hyperic-hq/ and find out the current Hyperic version (for example: 4.5.1, leave empty to skip): "
read HYPERIC_VERSION

if [ ! -z "$HYPERIC_VERSION" ]; then
	print -n "Please enter the password of the Hyperic hqadmin user on http://pluto:7080/: "
	read -s HYPERIC_PASSWORD
fi

while true; do
	print -n "Please enter the FTP backup hostname (for example server10.storage.hosteurope.de, leave empty to skip): "
	read BACKUP_FTP_HOST

	[ -z "$BACKUP_FTP_HOST" ] && break

	print -n "Please enter the FTP backup username: "
	read BACKUP_FTP_USER

	print -n "Please enter the FTP backup password: "
	read -s BACKUP_FTP_PASSWORD

	check_pkg curl curl "Installing curl to test connection"

	print -n "Testing SSL connection... "
	if curl -sS -u "$BACKUP_FTP_USER:$BACKUP_FTP_PASSWORD" --ftp-ssl -k "ftp://$BACKUP_FTP_HOST/" >/dev/null; then
		print "Success"
		BACKUP_FTP_SSL="1"
		break
	else
		print -n "Failed. Testing without SSL... "
		if curl -sS -u "$BACKUP_FTP_USER:$BACKUP_FTP_PASSWORD" "ftp://$BACKUP_FTP_HOST/" >/dev/null; then
			print "Success"
			BACKUP_FTP_SSL="0"
			break
		else
			print "Failure"
		fi
	fi
done

if [ ! -z "$BACKUP_FTP_HOST" ]; then
	print -n "Please enter the maximum size of the backup FTP directory in Megabytes (for example: 5000): "
	read BACKUP_STORAGE
	BACKUP_STORAGE=$[$BACKUP_STORAGE*1000]

	print -n "Please enter a comma-separated list of e-mail addresses to be notified about backup errors: "
	read BACKUP_MAILS
fi

TMP_DIR=/tmp

CONFLUENCE_STD="confluence-std"
CONFLUENCE_HOME="confluence-home"
CONFLUENCE_DOWNLOAD="http://www.atlassian.com/software/confluence/downloads/binary/confluence-$CONFLUENCE_VERSION-std.tar.gz"
CONFLUENCE_FOLDER="confluence-$CONFLUENCE_VERSION-std"
CONFLUENCE_DOWNLOAD_TMP="$TMP_DIR/confluence-$CONFLUENCE_VERSION-std.tar.gz"
CONFLUENCE_DB_USER=confluence
CONFLUENCE_DB_NAME=confluence
CONFLUENCE_INIT_SCRIPT=confluence

HYPERIC_DOWNLOAD="http://downloads.sourceforge.net/project/hyperic-hq/Hyperic%20$HYPERIC_VERSION/Hyperic%20$HYPERIC_VERSION-GA/hyperic-hq-agent-$HYPERIC_VERSION-x86-linux.tar.gz"
HYPERIC_DOWNLOAD_TMP="$TMP_DIR/hyperic-hq-agent-$HYPERIC_VERSION-x86-linux.tar.gz"
HYPERIC_FOLDER="hyperic-hq-agent-$HYPERIC_VERSION"
HYPERIC_INIT_SCRIPT=hyperic-agent
HYPERIC_SERVER=k15t.dynalias.com

PBZIP2_VERSION=1.1.1
PBZIP2_DOWNLOAD="http://compression.ca/pbzip2/pbzip2-$PBZIP2_VERSION.tar.gz"
PBZIP2_DOWNLOAD_TMP="$TMP_DIR/pbzip2-$PBZIP2_VERSION.tar.gz"
PBZIP2_FOLDER="pbzip2-$PBZIP2_VERSION"


##########
# Locale #
##########

print "Setting charset to UTF-8"
locale-gen en_US.UTF-8
update-locale LANG=en_US.utf8 LC_ALL=en_US.utf8


#########################
# Software dependencies #
#########################

print "Installing software dependencies: PostgreSQL, SUN JDK 1.6, X11 libs..."
apt-get install postgresql sun-java6-jdk libice-dev libsm-dev libx11-dev libxext-dev libxp-dev libxt-dev libxtst-dev curlftpfs g++ libbz2-dev libc6-dev openssl || exit
print "Setting system JVM to SUN JDK 1.6..."
update-alternatives --set java /usr/lib/jvm/java-6-sun/jre/bin/java

print "Compiling pbzip2 $PBZIP2_VERSION"
wget -c "$PBZIP2_DOWNLOAD" -O "$PBZIP2_DOWNLOAD_TMP"
cd /usr/local/src
tar --no-same-owner -xzf "$PBZIP2_DOWNLOAD_TMP" && rm -f "$PBZIP2_DOWNLOAD_TMP"
cd "$PBZIP2_FOLDER"
make
mv pbzip2 /usr/local/bin/


#####################
# Postgres database #
#####################

if [ -z "$CONFLUENCE_VERSION" ]; then
	print "Skipping Confluence configuration"
else
	print "Creating $CONFLUENCE_DB_USER postgres user..."
	su postgres -c "createuser -S -D -R '$CONFLUENCE_DB_USER'"
	echo "ALTER USER \"$CONFLUENCE_DB_USER\" PASSWORD '$CONFLUENCE_DB_PASSWD';" | su postgres -c psql

	print "Creating $CONFLUENCE_DB_NAME postgres database..."
	su postgres -c "createdb -E UNICODE -O '$CONFLUENCE_DB_USER' '$CONFLUENCE_DB_NAME'"


##############
# Confluence #
##############

	if grep -q confluence /etc/passwd; then
		print "User confluence already exists. Not creating."
	else
		print "Creating user confluence..."
		useradd -m -s/bin/bash confluence
	fi

	cd ~confluence

	if [ -e "$CONFLUENCE_FOLDER" ]; then
		print "$CONFLUENCE_FOLDER already exist, not extracting confluence."
	else
		print "Downloading Confluence $CONFLUENCE_VERSION Standalone..."
		wget -c "$CONFLUENCE_DOWNLOAD" -O "$CONFLUENCE_DOWNLOAD_TMP"

		print "Unpacking Confluence $CONFLUENCE_VERSION Standalone..."
		tar --no-same-owner -xzf "$CONFLUENCE_DOWNLOAD_TMP" && rm -f "$CONFLUENCE_DOWNLOAD_TMP"
	fi

	CONFLUENCE_HOME="$(pwd)/$CONFLUENCE_HOME"
	if grep -q "^confluence\\.home" "$CONFLUENCE_FOLDER/confluence/WEB-INF/classes/confluence-init.properties"; then
		print "confluence.home is already set, not setting to $CONFLUENCE_HOME"
	else
		print "Setting confluence home directory to $CONFLUENCE_HOME"
		( echo; echo "confluence.home=$CONFLUENCE_HOME" ) >> "$CONFLUENCE_FOLDER/confluence/WEB-INF/classes/confluence-init.properties"
	fi

	print "Setting logging properties to single-file logging"
	mv "$CONFLUENCE_FOLDER/conf/logging.properties" "$CONFLUENCE_FOLDER/conf/logging.properties.sav.$(date +%s)"
	cat > "$CONFLUENCE_FOLDER/conf/logging.properties" << EOF
handlers = java.util.logging.ConsoleHandler
.level=INFO
java.util.logging.ConsoleHandler.level=FINE
java.util.logging.ConsoleHandler.formatter = java.util.logging.SimpleFormatter
EOF

	print "Adding JMX to Confluence Tomcat for Hyperic"
	cat << EOF | echo_into "$CONFLUENCE_FOLDER/bin/setenv.sh"
[[ "\$1" != "stop" ]] && export JAVA_OPTS="\$JAVA_OPTS -Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.port=6969 -Dcom.sun.management.jmxremote.ssl=false -Dcom.sun.management.jmxremote.authenticate=false"
EOF

	print "Setting required file permissions..."
	chown -R confluence:confluence "$CONFLUENCE_FOLDER"/{logs,temp,work}
	chmod a+x "$CONFLUENCE_FOLDER"/bin/*.sh

	print "Creating symbolic link $CONFLUENCE_STD..."
	ln -sf "$CONFLUENCE_FOLDER" "$CONFLUENCE_STD"

	print "Setting up Confluence to boot on system startup..."
	if [ -e "/etc/init.d/$CONFLUENCE_INIT_SCRIPT" ]; then
		echo "File /etc/init.d/$CONFLUENCE_INIT_SCRIPT already exists."
	else
		cat > "/etc/init.d/$CONFLUENCE_INIT_SCRIPT" << EOF
#!/bin/bash
su -c "$(echo ~confluence)/$CONFLUENCE_STD/bin/catalina.sh \$*" confluence
EOF
		chmod +x "/etc/init.d/$CONFLUENCE_INIT_SCRIPT"
		update-rc.d "$CONFLUENCE_INIT_SCRIPT" defaults
	fi

	print "Starting confluence..."
	"/etc/init.d/$CONFLUENCE_INIT_SCRIPT" start
fi

###########
# Hyperic #
###########

if [ -z "$HYPERIC_VERSION" ]; then
	print "Skipping Hyperic installation"
else
	if grep -q hyperic /etc/passwd; then
		print "hyperic user already exists."
	else
		print "Creating hyperic user."
		useradd -m -s/bin/bash hyperic
	fi

	cd ~hyperic

	if [ -e "$HYPERIC_FOLDER" ]; then
		print "$HYPERIC_FOLDER exists, not downloading."
	else
		print "Downloading Hyperic $HYPERIC_VERSION"
		wget -c "$HYPERIC_DOWNLOAD" -O "$HYPERIC_DOWNLOAD_TMP"
		
		print "Extracting Hyperic $HYPERIC_VERSION"
		tar --no-same-owner -xzf "$HYPERIC_DOWNLOAD_TMP"
		chown -R hyperic "$HYPERIC_FOLDER"
	fi

	print "Setting hyperic setup properties"
	cat << EOF | echo_into "$HYPERIC_FOLDER/conf/agent.properties"
agent.setup.camIP=$HYPERIC_SERVER
agent.setup.camPort=7080
agent.setup.camSSLPort=7443
agent.setup.camSecure=yes
agent.setup.camLogin=hqadmin
agent.setup.camPword=$HYPERIC_PASSWORD
agent.setup.agentIP=*default*
agent.setup.agentPort=*default*
agent.setup.resetupTokens=no
EOF

	print "Generating $(pwd)/agent symlink"
	ln -sf "hyperic-hq-agent-$HYPERIC_VERSION" hyperic-hq-agent

	print "Setting up Hyperic to boot on system startup..."
	if [ -e "/etc/init.d/$HYPERIC_INIT_SCRIPT" ]; then
		echo "File /etc/init.d/$HYPERIC_INIT_SCRIPT already exists."
	else
		cat > "/etc/init.d/$HYPERIC_INIT_SCRIPT" << EOF
#!/bin/bash
su -c "$(echo ~hyperic)/hyperic-hq-agent/bin/hq-agent.sh \$*" hyperic
EOF
		chmod +x "/etc/init.d/$HYPERIC_INIT_SCRIPT"
		update-rc.d "$HYPERIC_INIT_SCRIPT" defaults
	fi

	print "Starting Hyperic Agent"
	"/etc/init.d/$HYPERIC_INIT_SCRIPT" start

	print "Creating test scripts"
	print "Creating /home/hyperic/test_backup.sh..."
	cat > /home/hyperic/test_backup.sh << EOF
#!/bin/bash

BACKUP_DIR=/var/backups/ftp
MAX_AGE=26

if ! grep -q "\$BACKUP_DIR" /proc/mounts && ! mount "\$BACKUP_DIR"; then
	echo "Could not mount \$BACKUP_DIR"
	exit 1
fi

last="\$(ls -1t "\$BACKUP_DIR/" | head -1)"
mtime="\$(stat -c%Y "\$BACKUP_DIR/\$last")"
now="\$(date +%s)"

diff=\$[\$now-\$mtime]
diff_readable=\$[\$diff/3600]

if [ "\$diff" -gt \$[\$MAX_AGE*3600] ]; then
	echo "Backup is too old (\$diff_readable hours)"
	ret=2
else
	echo "OK, backup is \$diff_readable hours old"
	ret=0
fi

umount "\$BACKUP_DIR" 2>/dev/null
exit \$ret
EOF

	print "Creating /home/hyperic/test_confluence_login.sh..."
	cat > /home/hyperic/test_confluence_login.sh << EOF
#!/bin/bash

login_url="http://\$(hostname)/dologin.action"
logout_url="http://\$(hostname)/logout.action"
username="\$(perl -MURI::Escape -e 'print uri_escape(\$ARGV[0]);' "\$1")"
password="\$(perl -MURI::Escape -e 'print uri_escape(\$ARGV[0]);' "\$2")"
cookie_file="/tmp/test_confluence_login_cookies.txt"

output="\$(wget -o/dev/null -O- --save-cookies="\$cookie_file" --keep-session-cookies --post-data="os_username=\$username&os_password=\$password" "\$login_url")"

if echo "\$output" | grep -qi "log out"; then
	echo "Login OK"
	wget -o/dev/null -O/dev/null --load-cookies="\$cookie_file" "\$logout_url"
	ret=0
elif echo "\$output" | grep -qi "captcha"; then
	echo "CAPTCHA required (please reset number of failed login attempts in Confluence Admin)"
	ret=1
else
	echo "Login failed"
	ret=2
fi

rm -f "\$cookie_file"
exit \$ret
EOF

	chmod +x /home/hyperic/{test_backup.sh,test_confluence_login.sh}
	chown hyperic:hyperic /home/hyperic/{test_backup.sh,test_confluence_login.sh}
fi


############
# IPtables #
############

IPTABLES_SCRIPT="
iptables -A INPUT -j ACCEPT -s 127.0.0.1
iptables -A INPUT -j ACCEPT -p icmp
iptables -A INPUT -j ACCEPT -p tcp -m state --state ESTABLISHED,RELATED
iptables -A INPUT -j ACCEPT -p udp --sport 53 --dport 1024:65535 # DNS
iptables -A INPUT -j ACCEPT -p tcp --dport 22
iptables -A INPUT -j ACCEPT -p tcp --dport 80
iptables -A INPUT -j ACCEPT -p tcp --dport 2144 # Hyperic Agent
iptables -A INPUT -j ACCEPT -p tcp --dport 8080 # Else redirect does not work
iptables -A INPUT -j ACCEPT -p tcp -s \"\$(hostname -i)\" # JMX needs to connect to the local IP address
iptables -P INPUT DROP

iptables -t nat -A PREROUTING -j REDIRECT -p tcp --dport 80 --to-ports 8080
"

print "Closing everything but SSH and HTTP with IPtables and setting up port 80 redirect..."
sed -ie 's/^exit 0$//' /etc/rc.local
echo "$IPTABLES_SCRIPT" | echo_into /etc/rc.local
echo "$IPTABLES_SCRIPT" | bash


##########
# Backup #
##########

if [ ! -z "$BACKUP_FTP_HOST" ]; then
	print "Creating backup infrastructure."

	mkdir /var/backups/{backup,ftp}
	echo "$BACKUP_MAILS" > /var/backups/.forward

	print "Creating backup postgres superuser"
	su postgres -c 'createuser -s backup'

	print "make_backup.sh"
	cat > /var/backups/make_backup.sh << EOF
#!/bin/bash

export PATH="\$PATH:/usr/local/bin"

bkp_dir=/var/backups/backup

pg_dump confluence | pbzip2 > "\$bkp_dir/confluence.sql.bz2"

cd /home/confluence/confluence-home
tar -c attachments confluence.cfg.xml resources 2>/dev/null | pbzip2 > "\$bkp_dir/confluence-home.tar.bz2"
EOF
	chmod +x /var/backups/make_backup.sh

	print "upload_backup.sh"
	cat > /var/backups/upload_backup.sh << EOF
#!/bin/bash
backup_dir=/var/backups/backup
ftp_dir=/var/backups/ftp
storage=$BACKUP_STORAGE

if ! grep -q "\$ftp_dir" /proc/mounts; then
	mount "\$ftp_dir" || exit \$?
fi

size="\$(du -s "\$backup_dir" | cut -f1)"

cur_size="\$(du -s "\$ftp_dir" | cut -f1)"
while [ "\$[\$storage-\$cur_size]" -lt "\$size" ]; do
	rem="\$(ls -1 "\$ftp_dir" | head -1)"
	#echo "Removing old backup \$rem."
	rm -rf "\$ftp_dir/\$rem"
	cur_size="\$(du -s "\$ftp_dir" | cut -f1)"
done

cp -r "\$backup_dir" "\$ftp_dir/\$(date -u +%FT%TZ)"

umount -l "\$ftp_dir" 2>/dev/null
EOF
	chmod +x /var/backups/upload_backup.sh

	print "Setting file owners"
	chown backup:backup /var/backups/{backup,ftp,make_backup.sh,upload_backup.sh,.forward}
	chmod 775 /var/backups/ftp # Required for hyperic user to mount

	print "Adding cron job"
	( crontab -l -u backup 2>/dev/null; echo "0 3 * * * /var/backups/make_backup.sh && /var/backups/upload_backup.sh" ) | crontab -u backup -

	append=""
	if [ "$BACKUP_FTP_SSL" -eq 1 ]; then
		crt="/usr/share/ca-certificates/$BACKUP_FTP_HOST.crt"
		print "Saving FTP SSL certificate to $crt and adding to CA certificates"
		openssl s_client -starttls ftp -connect "$BACKUP_FTP_HOST:21" </dev/null | openssl x509 > "$crt" || print "Failed. Please fix this manually."
		echo "$BACKUP_FTP_HOST.crt" | echo_into /etc/ca-certificates.conf
		update-ca-certificates
		print "Warning: Adding no_verify_peer to fstab options as Ubuntu curl version is buggy."
		append=",ssl,no_verify_peer"
	fi

	print "Setting up ftpfs mount"
	cat << EOF | echo_into /etc/fstab
curlftpfs#$BACKUP_FTP_HOST /var/backups/ftp fuse user=$BACKUP_FTP_USER:$BACKUP_FTP_PASSWORD,uid=backup,gid=backup,user,fsname=curlftpfs#$BACKUP_FTP_HOST,noauto,allow_other$append 0 0
EOF

	perm_script='
chgrp fuse /dev/fuse
chmod g+rw /dev/fuse
'
	echo "$perm_script" | echo_into /etc/rc.local
	echo "$perm_script" | bash

	echo "user_allow_other" | echo_into /etc/fuse.conf

	usermod -aG fuse backup
	usermod -aG fuse hyperic
	usermod -aG backup hyperic

	print -n "Testing ftpfs mount... "
	if mount /var/backups/ftp; then
		print "OK"
		umount /var/backups/ftp
	else
		print "Failure! Please fix this manually!"
	fi
fi

if [ -z "$CONFLUENCE_VERSION" ]; then
	print "Everything done."
else
	print "You can access Confluence now on http://$HOSTNAME/. Set up the License key and the database connection, the user name is $CONFLUENCE_DB_USER and the database is called $CONFLUENCE_DB_NAME." 
fi
