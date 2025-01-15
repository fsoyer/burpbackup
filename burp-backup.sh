#!/bin/bash
# Burp-backup Script (BURP BACKUP CLIENT)
# v0.1
# Pre-requisite : burp-client installed, client delared on server, /etc/bur/burp.conf set with client name,password and server ip
# See README.md for details
# (c) 2021, Frank Soyer <frank.soyer@gmail.com>

# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# The GNU General Public License is available at:
# http://www.gnu.org/copyleft/gpl.html

ERROR_FLAG=0
ERROR=0
ERRORS="ERREURS: "
RETRY=10

# Initialize global variables (can be overwritten in .conf file)
# --------------------------------------
# Mail program (mail, mailx, nail...)
# --------------------------------------
MAILBIN="/usr/bin/mail -s"
# --------------------------------------
# default options 
# --------------------------------------
SERVERNAME=$(hostname)
SUFFIX=$(hostname |cut -d '.' -f 1)
JOUR=$(date +%w)
# --------------------------------------
# Databases default options 
# --------------------------------------
MYSQLDUMP_OPTS="--routines"
PGSQLDUMP_OPTS=""
STOPSEAFILE=0
SOGOBACKUP=0
# --------------------------------------
# Load variables from config file
# --------------------------------------
if [ $# -gt 0 ]
then
# let use the given full path config (.conf) file
   if [ -f $1 ]
   then
      . $1
   else
      echo "$1 introuvable !"
	  rm -f $SCRIPT_DIR/$PID_FILE
      exit 1
   fi
else
   if [ -f $(dirname $0)/burp-backup.conf ]
   then
      . $(dirname $0)/burp-backup.conf
   else
      echo "$(dirname $0)/burp-backup.conf introuvable !"
	  rm -f $SCRIPT_DIR/$PID_FILE
      exit 1
   fi
fi

# --------------------------------------
# Databases list 
# Can't be initialized before including .conf file because we need databases PASSWORDs
# --------------------------------------
if [ ! "$MYDB" -a "$MYSQLDUMP" -eq 1 ]
then
   # Find which databases to dump, each in an individual dump file
   MYDB="mysql --execute 'show databases\G' --password='$MYSQL_PASSWORD' | grep -v row | sed -e 's/Database: //g' | grep -v mysql | grep -v information_schema | grep -v performance_schema"
   if [ $? -ne 0 ]
   then
      (echo "MYSQL backup error on $HOSTNAME") | $MAILBIN "burp-backup : MYSQL BACKUP ERROR ON $SERVERNAME [on $(hostname)] $(date +%d/%m)" $MAIL_ADMIN
   fi
fi
if [ ! "$PGDB" -a "$PGSQLDUMP" -eq 1 ]
then
   # Find which databases to dump, each in an individual dump file
   PGDB="su - postgres -c 'psql -l --pset tuples_only' | awk '{print $1}' | grep -v ^$ | grep -v template | grep -v : | grep -v '|'"
   if [ $? -ne 0 ]
   then
      (echo "POSTGRESQL backup error on $HOSTNAME") | $MAILBIN "burp-backup : POSTGRESQL BACKUP ERROR ON $SERVERNAME [on $(hostname)] $(date +%d/%m)" $MAIL_ADMIN
   fi
fi

if [ ! -e $SCRIPT_DIR/$PID_FILE ]
then
   if [ -e  $SCRIPT_DIR/$LOG_FILE ]
   then
        mv $SCRIPT_DIR/$LOG_FILE $SCRIPT_DIR/$LOG_FILE.0
   fi
   date > $SCRIPT_DIR/$LOG_FILE
   echo >> $SCRIPT_DIR/$LOG_FILE

## Script pre-backup
   if [ ! -z $PRESCRIPT ]
   then
      . $PRESCRIPT
      if [ $? -ne 0 ]
      then
         rm -f $SCRIPT_DIR/$PID_FILE
         (echo "$PRESCRIPT ERROR ON $HOSTNAME") | $MAILBIN "burp-backup : BACKUP ERROR ON $SERVERNAME [on $(hostname)] $(date +%d/%m)" $MAIL_ADMIN
		 exit 1
      fi
   fi

   echo $$ > $SCRIPT_DIR/$PID_FILE

   if [ $STOPAPACHE -eq 1 ]
   then
      echo "Stopping Apache" >> $SCRIPT_DIR/$LOG_FILE
      systemctl stop httpd
   fi

   if [ $STOPSEAFILE -eq 1 ]
   then
      echo "Stopping Seafile" >> $SCRIPT_DIR/$LOG_FILE
      systemctl stop seahub
      systemctl stop seafile
      echo "Running Seafile garbage collector" >> $SCRIPT_DIR/$LOG_FILE
      su - seafile -c 'seafile-server-latest/seaf-gc.sh; exit $?'  >> $SCRIPT_DIR/$LOG_FILE
      ERROR=$?
      if [ $ERROR -ne 0 ]
      then
         ERRORS="$ERRORS SEAFILE GC=error $ERROR:"
         ERROR_FLAG=1
      fi
   fi

## Mysql dump
   if [ $MYSQLDUMP -eq 1 -a ! "$MYDB" == "" ]
   then
      ls $DUMP_DIR >/dev/null 2>&1
      if [ $? -ne 0 ]
      then
         echo "Creating $DUMP_DIR" >> $SCRIPT_DIR/$LOG_FILE
         $mkdir -p $DUMP_DIR >> $SCRIPT_DIR/$LOG_FILE 2>&1
      fi
      echo "MySQL dump " $(date) >> $SCRIPT_DIR/$LOG_FILE
      MYDBLIST=$(eval $MYDB)
      if [[ $MYDBLIST =~ "ERROR" ]]
      then
         echo $MYDBLIST >> $SCRIPT_DIR/$LOG_FILE
         ERRORS="$ERRORS MYSQLDUMP=error $MYDBLIST"
         ERROR_FLAG=1
         MYDBLIST=
      fi
      # customize field separator to handle spaces in db names
      oIFS=$IFS
      IFS=$'\n'
      for DB in $MYDBLIST
      do
         IFS=$oIFS # List is OK, reset IFS
         echo "MYSQLCHECK " $DB $(date) >> $SCRIPT_DIR/$LOG_FILE 2>&1
         mysqlcheck "$DB" --silent --auto-repair --password=$MYSQL_PASSWORD >> $SCRIPT_DIR/$LOG_FILE 2>&1
         echo "MYSQLDUMP " $DB $(date) >> $SCRIPT_DIR/$LOG_FILE 2>&1
         mysqldump "$DB" $MYSQLDUMP_OPTS --password=$MYSQL_PASSWORD > $DUMP_DIR/my_${SUFFIX}_$(echo $DB|tr ' ' '_')_${JOUR}.sql
         ERROR=$?
         if [ $ERROR -ne 0 ]
         then
            ERRORS="$ERRORS MYSQLDUMP=error $ERROR:"
            ERROR_FLAG=1
         else
            if [ $MYENCRYPT -eq 1 ]
            then
            # Encrypt the sql file while compressing it.
            # Unencrypt command : dd if=file.sql.gz.enc | openssl des3 -d -k $MYENCPASS | gunzip - | dd of=file.sql
               rm -f $DUMP_DIR/my_${SUFFIX}_$(echo $DB|tr ' ' '_')_${JOUR}.sql.gz.enc 2>> $SCRIPT_DIR/$LOG_FILE
               dd if=$DUMP_DIR/my_${SUFFIX}_$(echo $DB|tr ' ' '_')_${JOUR}.sql | gzip - | openssl des3 -salt -k $MYENCPASS | dd of=$DUMP_DIR/my_${SUFFIX}_$(echo $DB|tr ' ' '_')_${JOUR}.sql.gz.enc 2>> $SCRIPT_DIR/$LOG_FILE
               rm -f $DUMP_DIR/my_${SUFFIX}_$(echo $DB|tr ' ' '_')_${JOUR}.sql 2>> $SCRIPT_DIR/$LOG_FILE
            else
               rm -f $DUMP_DIR/my_${SUFFIX}_$(echo $DB|tr ' ' '_')_${JOUR}.sql.gz 2>> $SCRIPT_DIR/$LOG_FILE
               gzip $DUMP_DIR/my_${SUFFIX}_$(echo $DB|tr ' ' '_')_${JOUR}.sql 2>> $SCRIPT_DIR/$LOG_FILE
            fi
         fi
      done
      IFS=$oIFS # force reset IFS
   fi

## PostgreSQL dump
   if [ $PGSQLDUMP -eq 1 -a ! "$PGDB" == "" ]
   then
      echo "PostgreSQL dump " $(date) >> $SCRIPT_DIR/$LOG_FILE
      PGDBLIST=$(eval $PGDB) >> $SCRIPT_DIR/$LOG_FILE 2>&1
      # customize field separator to handle spaces in db names
      oIFS=$IFS
      IFS=$'\n'
      for DB in $PGDBLIST
      do
         IFS=$oIFS
         echo "VACUUMDB " $DB $(date) >> $SCRIPT_DIR/$LOG_FILE 2>&1
         su - postgres -c "vacuumdb -U postgres -d $DB -f -q -z" >> $SCRIPT_DIR/$LOG_FILE 2>&1
         echo "PG_DUMP " $DB $(date) >> $SCRIPT_DIR/$LOG_FILE 2>&1
         su - postgres -c "pg_dump $PGSQLDUMP_OPTS $DB" > $DUMP_DIR/pg_${SUFFIX}_$(echo $DB|tr ' ' '_')_${JOUR}.sql
         ERROR=$?
         if [ $ERROR -ne 0 ]
         then
            ERRORS="$ERRORS PGDUMP=error $ERROR:"
            ERROR_FLAG=1
         else
            rm -f $DUMP_DIR/pg_${SUFFIX}_$(echo $DB|tr ' ' '_')_${JOUR}.sql.gz 2>> $SCRIPT_DIR/$LOG_FILE
            gzip $DUMP_DIR/pg_${SUFFIX}_$(echo $DB|tr ' ' '_')_${JOUR}.sql 2>> $SCRIPT_DIR/$LOG_FILE
         fi
      done
   fi

   if [ $STOPAPACHE -eq 1 ]
   then
      echo "Starting Apache" >> $SCRIPT_DIR/$LOG_FILE
      systemctl start httpd
   fi

## backup LDAP
   if [ $SLAPCAT -eq 1 ]
   then
      SLAPCATBIN=$(which slapcat)
      if [ $SLAPCATBIN ]
      then
         echo "LDAP dump " $(date) >> $SCRIPT_DIR/$LOG_FILE
         slapcat -c -l $DUMP_DIR/ldap_${SUFFIX}_${JOUR}.ldif >> $SCRIPT_DIR/$LOG_FILE 2>&1
         ERROR=$?
         if [ $ERROR -ne 0 ]
         then
            ERRORS="$ERRORS SLAPCAT=error $ERROR:"
            ERROR_FLAG=1
         else
            rm -f $DUMP_DIR/ldap_${SUFFIX}_${JOUR}.ldif.gz 2>> $SCRIPT_DIR/$LOG_FILE
            gzip $DUMP_DIR/ldap_${SUFFIX}_${JOUR}.ldif 2>> $SCRIPT_DIR/$LOG_FILE
         fi
      else
         echo "Programme SLAPCAT introuvable !" >> $SCRIPT_DIR/$LOG_FILE 2>&1
         ERRORS="Programme SLAPCAT introuvable !"
         ERROR_FLAG=1
      fi
   fi

## backup SOGo
   if [ $SOGOBACKUP -eq 1 ]
   then
      SOGOTOOLBIN=$(which sogo-tool)
      if [ ! -z "$SOGOTOOLBIN" ]
      then
         ls $DUMP_DIR/sogo_backups >/dev/null 2>&1
         if [ $? -ne 0 ]
         then
            echo "Creating $DUMP_DIR/sogo_backups" >> $SCRIPT_DIR/$LOG_FILE
            mkdir -p $DUMP_DIR/sogo_backups >> $SCRIPT_DIR/$LOG_FILE 2>&1
         fi

         echo "SOGO backup " $(date) >> $SCRIPT_DIR/$LOG_FILE
         $SOGOTOOLBIN backup $DUMP_DIR/sogo_backups ALL >> $SCRIPT_DIR/$LOG_FILE 2>&1
         ERROR=$?
         if [ $ERROR -ne 0 ]
         then
            ERRORS="$ERRORS SOGOBACKUP=error $ERROR:"
            ERROR_FLAG=1
         else
            rm -f $DUMP_DIR/sogobackup_${JOUR}.tgz 2>> $SCRIPT_DIR/$LOG_FILE
            tar -cvzf $DUMP_DIR/sogobackup_${JOUR}.tgz $DUMP_DIR/sogo_backups/* >> $SCRIPT_DIR/$LOG_FILE 2>&1
         fi
      else
         echo "Programme SOGO-TOOL introuvable !" >> $SCRIPT_DIR/$LOG_FILE 2>&1
         ERRORS="Programme SOGO-TOOL introuvable !"
         ERROR_FLAG=1
      fi
   fi

## Boucle de backup
   echo >> $SCRIPT_DIR/$LOG_FILE
   BURPBIN=$(which burp)
   if [ ! -z "$BURPBIN" ]
   then
      i=1
      echo "Backup try $i" >> $SCRIPT_DIR/$LOG_FILE
      $BURPBIN -a b >> $SCRIPT_DIR/$LOG_FILE 2>&1
      ERROR=$?
      if [ $ERROR -ne 0 ]
      then
      # in case of SSH connection error, retry it max 5 times, else exit
         SSL_ERROR=`grep -i "SSL connect error" $SCRIPT_DIR/$LOG_FILE > /dev/null && echo 0 || echo 1`  # 1 for grep means "not found"
         WAIT=0
         while [ $SSL_ERROR -eq 0 -a $i -le $RETRY ]
         do
            i=$((i+1))
            echo "Backup try $i" >> $SCRIPT_DIR/$LOG_FILE
            sed -i '/SSL connect error/d' $SCRIPT_DIR/$LOG_FILE
            # increase sleep delay between each try
            WAIT=$((WAIT+120))
            sleep $(($WAIT + RANDOM % 360));
            $BURPBIN -a b >> $SCRIPT_DIR/$LOG_FILE 2>&1
            SSL_ERROR=`grep -i "SSL connect error" $SCRIPT_DIR/$LOG_FILE > /dev/null && echo 0 || echo 1`
         done
         # Not successful after $RETRY retries ?
         if [ $SSL_ERROR -eq 0 ]
         then
            ERRORS="$ERRORS ${ERROR}:"
            ERROR_FLAG=1
         fi
      fi
   else
      echo "Programme BURP introuvable !" >> $SCRIPT_DIR/$LOG_FILE 2>&1
      ERRORS="Programme BURP introuvable !"
      ERROR_FLAG=1
   fi

   if [ $STOPSEAFILE -eq 1 ]
   then
      echo "Clearing Seahub cache" >> $SCRIPT_DIR/$LOG_FILE
      su - seafile -c 'rm -rf /tmp/seahub_cache.old; mv /tmp/seahub_cache /tmp/seahub_cache.old'  >> $SCRIPT_DIR/$LOG_FILE
      echo "Starting Seafile" >> $SCRIPT_DIR/$LOG_FILE
      systemctl start seafile
      systemctl start seahub
   fi

   if [ $ERROR_FLAG -eq 1 ]
   then
      (echo $ERRORS
       date
       echo Voir $SCRIPT_DIR/$LOG_FILE
       grep -i warning $SCRIPT_DIR/$LOG_FILE
       grep -i error $SCRIPT_DIR/$LOG_FILE
       grep -i corrupt $SCRIPT_DIR/$LOG_FILE
      )| $MAILBIN "burp-backup : ERROR ON $SERVERNAME [on $(hostname)] $(date +%d/%m)" $MAIL_ADMIN
   else
     # Script post-backup
      if [ -f $POSTSCRIPT ]
      then
         $POSTSCRIPT
         if [ $? -ne 0 ]
         then
            ERRORS="$ERRORS - Script POST-BACKUP error"
            ERROR_FLAG=1
         fi
      fi
      if [ $MAIL_IF_SUCCESS -eq 1 ]
      then
         if [ $ERROR_FLAG -eq 0 ]
         then
            ERRORS=""
         fi
         (date
          echo $ERRORS
          ls -l $SCRIPT_DIR/$LOG_FILE
         )| $MAILBIN "burp-backup : Backup $SERVERNAME [on $(hostname)] successfull $(date +%d/%m)" $MAIL_ADMIN
      fi
   fi
   date >> $SCRIPT_DIR/$LOG_FILE
   rm -f $SCRIPT_DIR/$PID_FILE
else
    (echo "$SERVERNAME:$SCRIPT_DIR/$PID_FILE existe : abandon de $0") | $MAILBIN "burp-backup : BACKUP ERROR ON $SERVERNAME [on $(hostname)] $(date +%d/%m)" $MAIL_ADMIN
fi
