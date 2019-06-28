#!/bin/bash

: '
Usage: oitRecordingBackup.sh [-n "phonenumber"] [-s "startdate"] [-e "enddate"]
	-n "phonenumber" allows you to only download recordings to a specific number instead of the whole domain.
	-s, -e "startdate" and "enddate" should be provided as "YYYY-MM-DD 23:59:59".

Note: This script is likely to run on any system that has a bash shell, provided you can install
xmlstarlet and jq. However, line 143...
	CALL_TIMESTAMP=`date -d @"$CALL_TIMESTAMP" +%Y-%m-%d_%H.%M.%S`
...is specific to Linux. If this is being run on MacOS (or something else), youll need to change it to something like this:
	CALL_TIMESTAMP=`date -r $CALL_TIMESTAMP +%Y-%m-%d_%H.%M.%S`

Wishlist for this script:
-Perhaps store credentials in a separate file?
-Download recordings into numbered folders representing the month and day.
-Automatically prune current recordings from our storage to maintain however many months we want to keep.
-Debug mode, that shows all output from API calls.
-Remove calls that dont have call recordings, so that curl isnt just fed a blank for the url, which causes
	an error to be displayed. Not a big deal, but would remove concern from user running the script.
'

#EDIT THESE VARIABLES
#VVVVVVVVVVVVVVVVVVVV

DOMAIN="xxxx"
CLIENT_ID="xxxx"
CLIENT_SECRET="xxxx"
USERNAME="xxxx"
PASSWORD="xxxx"

#^^^^^^^^^^^^^^^^^^^^
#EDIT THESE VARIABLES


echo -e "\n`date`\n"

#Check for dependencies needed to run this script...
if ! command -v xmlstarlet >/dev/null 2>&1 ; then
	echo "xmlstarlet not found, please install xmlstarlet and try again."
	exit 0
fi
if ! command -v jq >/dev/null 2>&1 ; then
	echo "jq not found, please install jq and try again."
	exit 0
fi

#Set and get some options...
while getopts e:s:n: OPTIONS; do
	case $OPTIONS in
		s) START_DATE=$OPTARG;;
		e) END_DATE=$OPTARG;;
		n) PH_NUM_TO_DOWNLOAD=$OPTARG;;
	esac
done

#Make sure the user entered a start and end date, otherwise, abort.
if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
        echo "You must provide a start AND end date."
        echo "Try something like this: oit.sh -s \"2019-01-01 00:00:00\" -e \"2019-02-01 00:00:00\""
        exit 1
fi

if [ -z "$PH_NUM_TO_DOWNLOAD" ]; then
	echo "No phone number provided to filter on."
	sleep 1
	echo "This will download all recordings in the domain."
	sleep 1
	echo "If you wish to filter on a number, please add -n \"1234567890\" to the script options."
	sleep 1
	echo -e "Continuing...\n"
	sleep 2
fi


echo "Getting access token..."
ACCESS_TOKEN=`curl -s https://manage.oitvoip.com/ns-api/oauth2/token/ \
	--data-urlencode "grant_type=password" \
	--data-urlencode "client_id=$CLIENT_ID" \
	--data-urlencode "client_secret=$CLIENT_SECRET" \
	--data-urlencode "username=$USERNAME" \
	--data-urlencode "password=$PASSWORD" \
	| jq -r '.access_token'`
echo "Access token: $ACCESS_TOKEN"

echo "Getting call records..."
curl -s "https://manage.oitvoip.com/ns-api/?object=cdr2&action=read" \
	--header "Authorization: Bearer $ACCESS_TOKEN" \
	--data-urlencode "start_date=$START_DATE" \
	--data-urlencode "end_date=$END_DATE" \
	--data-urlencode "domain=$DOMAIN" \
	--data-urlencode "raw=yes" \
	--data-urlencode "limit=9999999999" \
	> /tmp/oitcdrs.xml

#Process that xml and extract only what we care about...
#Resulting file will have columns for these values... orig_callid, orig_to_user, term_callid, orig_from_user, time_start
echo "Formatting and filtering call records..."
xmlstarlet sel -t -m "//xml/cdr/CdrR" \
	-v "orig_callid" -o " " \
	-v "orig_to_user" -o " " \
	-v "term_callid" -o " " \
	-v "orig_from_user" -o " " \
	-v "time_start" -n \
	< /tmp/oitcdrs.xml \
	> /tmp/oitcdrs.txt

#Keep only the CDRs for calls to the filtered number. This could probably be done with something other than
#grep to ensure accuracy, but this works for our purposes. We can count number of lines to determine number
#of calls that we need to attempt to grab a recording for, for time estimation purposes.
grep "$PH_NUM_TO_DOWNLOAD" /tmp/oitcdrs.txt > /tmp/oitcdrsprocessed.txt
echo "There are `wc -l /tmp/oitcdrsprocessed.txt | awk '{print $1}'` calls to process..."

#Make a directory for the recordings, if it doesn't exist.
mkdir -p recordings
#and clear the file that we are about to populate.
rm /tmp/oitcurls.txt

#For each CDR, we need to attempt to get a recording URL, if it exists.
i=0
echo -n "Processing call #"
while IFS=" " read -r ORIG_CALLID ORIG_TO_USER TERM_CALLID CALLER_PHONENUMBER CALL_TIMESTAMP
do
	#Print out progress...
	echo -n "$((i+1)) "

	#Grab the call recording details for the CDR we are on...
        curl -s "https://manage.oitvoip.com/ns-api/?object=recording&action=read" \
                --header "Authorization: Bearer $ACCESS_TOKEN" \
                --data-urlencode "orig_callid=$ORIG_CALLID" \
                --data-urlencode "term_callid=$TERM_CALLID" \
                --data-urlencode "domain=$DOMAIN" \
		> /tmp/oitrecording.xml

	#...process that data into a URL to download...
	RECORDING_URL=`xmlstarlet sel -t -m "//xml/recording[1]" \
		-v "url" -n \
		< /tmp/oitrecording.xml \
		| sed 's/\&amp;/\&/g'`


	#...convert the epoch timestamp into a meaningful human readable timestamp...
	CALL_TIMESTAMP=`date -d @"$CALL_TIMESTAMP" +%Y-%m-%d_%H.%M.%S`

	#...and generate a filename for that recording...
	FILENAME="recordings/call_${CALL_TIMESTAMP}_${CALLER_PHONENUMBER}.wav"

	#...then throw it all into a file for curl to use.
	#curl's performance seemed best doing it this way as opposed to one at a time. For a sample
	#size of 90 call recordings, it took 60 seconds to download all of them one at a time,
	#versus this method which took about 20 seconds. In addition, if there were a lot of recordings,
	#the one by one approach would find itself surpassing the hour long expiration time of the access
	#token, which would start throwing errors.
	echo -e "url=\"$RECORDING_URL\"\noutput=\"$FILENAME\"" >> /tmp/oitcurls.txt

	((i++))
done < /tmp/oitcdrsprocessed.txt

#There will be some "malformed url" errors while curl runs, this is because some of the calls don't
#have corresponding recordings, most likely due to them hanging up before the call connected
#or some other reason involving the caller not talking to a person.
echo -e "\nDownloading recordings..."
time curl -K /tmp/oitcurls.txt