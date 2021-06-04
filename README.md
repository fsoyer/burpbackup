# burpbackup backup automation script (BURP BACKUP CLIENT)
(c) Frank Soyer <frank.soyer@gmail.com> 2021

Changelog :
* 0.1 - script screation

# Dependencies :
burp-client

# Instructions
Configure BURP-CLIENT (server address, backup password, which directories to backup, what to exclude,...) :
* /etc/burp.burp.conf
Create a file for burp-backup.sh script configurations (add mysqldump, stop.start some services,...) :
* /opt/burp/burp-backup.conf

Add this to your crontab :

    # m h  dom mon dow   command
    30 12 * * * /opt/burp/burp-backup.sh /opt/burp/burp-backup.conf

# Ldap dump
You need to install ldap utils
 aptitude install ldap-utils
