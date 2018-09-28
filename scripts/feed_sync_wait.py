#!/usr/bin/python

import json
import requests
import time
import sys
import subprocess

if len(sys.argv) <= 1:
    print ("USAGE: {} <minutes to wait total> <intermediate check timer>".format(sys.argv[0]))
    sys.exit(1)

try:
    minutes = int(sys.argv[1])
    if minutes > 60:
        minutes = 60
    elif minutes < 5:
        minutes = 5
except:
    minutes = 30
try:
    timer = float(sys.argv[2])
    if timer < 1.0:
        timer = 1.0
    elif timer > 60.0:
        timer = 10.0
except:
    timer = 5.0

url = "http://localhost:8228/v1/system/feeds"
count = 0
retries = (minutes*60) / timer
done = False
while not done and count < retries:
    print ("\nattempt {} / {}".format(count, retries))
    try:

        r = requests.get(url, auth=('admin', 'foobar'), verify=False, timeout=15)
        if r.status_code == 200:
            print ("got a good 200 response")
            data = json.loads(r.text)
            sync_record = data[0]
            last_sync_time = sync_record.get('last_full_sync', None)
            if last_sync_time:
                print ("got last full sync time - good to go!: {}".format(last_sync_time))
                done=True
            else:
                synced = 0
                total = 0
                synced_names = []
                unsynced_names = []
                for group in sync_record.get('groups', []):
                    if group.get('last_sync', None):
                        synced = synced+1
                        synced_names.append(group.get('name', ""))
                    else:
                        unsynced_names.append(group.get('name', ""))
                    total = total+1
                print ("not done yet {} / {} groups completed".format(synced, total))
                print ("\tsynced: {}\n\tunsynced: {}".format(synced_names, unsynced_names))
        else:
            print ("got bad response, trying again  {}/{}".format(count, retries))

    except Exception as err:
        print ("exception while parsing result: {}".format(err))

    count = count + 1
    time.sleep(timer)

done=1
if done:
    cmds = [
        "docker-compose exec anchore-db /bin/bash -c".split() + ['pg_dump -U postgres -Z 9 > /docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz'],
        'docker-compose stop'.split(),
        'docker commit aevolumeprepop_anchore-db_1 anchore/anchore-engine:anchore-engine-db-prepop'.split(),
        'docker-compose down --volumes'.split(),
    ]
    for cmd in cmds:
        try:
            sout = subprocess.check_output(cmd)
            print ("CMD: {} OUTPUT: {}".format(cmd, sout))
        except Exception as err:
            print ("command failed: {}".format(cmd))
            print ("bailing out")
            sys.exit(1)
else:
    print ("timed out waiting for feed sync to complete")
    sys.exit(1)

print ("SUCCESS!")
sys.exit(0)
