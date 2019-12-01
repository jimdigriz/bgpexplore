#!/bin/sh

set -eu

FILE=asn.txt
curl -f -o $FILE.tmp ftp://ftp.ripe.net/ripe/asnames/$FILE || RC=$?
[ -f $FILE.tmp -a $RC -eq 0 ] && mv $FILE.tmp $FILE && gzip $FILE || rm -f $FILE.tmp $FILE

mkdir -p ris-data
cd ris-data

DATE=${DATE:-$(date -u +%Y%m%d)}
DATE2=$(date -d $DATE -u +%Y.%m)

for I in $(seq 0 24 | xargs -n1 printf "%02d\n"); do
	FILE=bview.$DATE.0000.$I.gz
	[ -f $FILE ] && TS=1 || TS=
	RC=0
	curl -f -o $FILE.tmp ${TS:+-z $FILE} http://data.ris.ripe.net/rrc$I/$DATE2/bview.$DATE.0000.gz || RC=$?
	[ -f $FILE.tmp -a $RC -eq 0 ] && mv $FILE.tmp $FILE || rm -f $FILE.tmp
done

cd -

exit 0
