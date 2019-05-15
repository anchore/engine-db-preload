#!/usr/bin/python

import json
import requests
import time
import sys
import subprocess

def discover_anchore_ids():
    # first, get the container ID of the anchore-db postgres container
    db_id = engine_id = None
    try:
        cmd = "docker-compose ps -q anchore-db"
        db_id = subprocess.check_output(cmd.split()).strip()

        cmd = "docker-compose ps -q anchore-engine"
        engine_id = subprocess.check_output(cmd.split()).strip()
    except Exception as err:
        raise Exception("command failed getting container ID: {}".format(cmd))

    if not engine_id or not db_id:
        raise Exception("bailing out - anchore-engine (discovered id={}) and anchore-db (discovered_id={}) must be running before executing this script".format(engine_id, db_id))

    return(engine_id, db_id)

def verify_anchore_engine_available(user='admin', pw='foobar', timeout=300, health_url="http://localhost:8228/health", test_url="http://localhost:8228/v1/system/feeds"):
    done = False
    start_ts = time.time()
    while not done:
        try:
            r = requests.get(health_url, verify=False, timeout=10)
            if r.status_code == 200:
                done = True
            else:
                print ("engine not up yet - response httpcode={} data={}".format(r.status_code, r.text))
        except Exception as err:
            print ("engine not up yet - exception: {}".format(err))
        time.sleep(0.5)
        if time.time() - start_ts >= timeout:
            raise Exception("timed out after {} seconds".format(timeout))

    done=False
    while not done:
        try:
            r = requests.get(test_url, auth=(user, pw), verify=False, timeout=10)
            if r.status_code == 200:
                done = True
            else:
                print ("engine not up yet - response httpcode={} data={}".format(r.status_code, r.text))
        except Exception as err:
            print ("engine not up yet - exception: {}".format(err))
        time.sleep(0.5)
        if time.time() - start_ts >= timeout:
            raise Exception("timed out after {} seconds".format(timeout))

    return(True)

def wait_for_feed_sync(timeout=300, feeds_url="http://localhost:8228/v1/system/feeds", timer=1.0):
    start_ts = time.time()
    good_count_retries = 5
    done = False
    good_count = 0
    while not done:
        print ("\nattempt {} / {}".format(int(time.time() - start_ts), timeout))
        try:
            r = requests.get(feeds_url, auth=('admin', 'foobar'), verify=False, timeout=20)
            if r.status_code == 200:
                data = json.loads(r.text)
                all_synced = True
                for sync_record in data:
                    last_sync_time = sync_record.get('last_full_sync', None)
                    if not last_sync_time:
                        all_synced = False
                        break

                if all_synced:
                    print ("detected all synced - ensuring by retrying {} / {}".format(good_count, good_count_retries))
                    good_count = good_count + 1
                    if good_count > good_count_retries:
                        print ("got last full sync time, for all feeds - ready to go!: {}".format(last_sync_time))
                        done=True
                else:
                    synced = 0
                    total = 0
                    synced_names = []
                    unsynced_names = []
                    for sync_record in data:
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
                print ("got bad response, trying again httpcode={} data={}".format(r.status_code, r.text))

        except Exception as err:
            raise Exception("cannot contact engine yet for system feeds list status - exception: {}".format(err))

        time.sleep(timer)
        if time.time() - start_ts > timeout:
            raise Exception("timed out waiting for feeds to sync after {} seconds".format(timeout))

    return(True)

#### MAIN PROGRAM STARTS HERE ####

# prep input from CLI
if len(sys.argv) <= 1:
    print ("USAGE: {} <minutes to wait total> <intermediate check timer>".format(sys.argv[0]))
    sys.exit(1)

try:
    minutes = int(sys.argv[1])
    if minutes > 180:
        minutes = 180
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

# before we get started, verify that anchore-engine and anchore-db are up and running
try:
    engine_id, db_id = discover_anchore_ids()
except Exception as err:
    print ("could not discover anchore-engine and anchore-db IDs - exception: {}".format(err))
    sys.exit(1)
print ("got container IDs: engine={} db={}".format(engine_id, db_id))

# next, ensure that anchore-engine is fully up and responsive, ready to handle feed sync list API call
try:
    rc = verify_anchore_engine_available(timeout=300)
except Exception as err:
    print ("anchore-engine is not running or available - exception: {}".format(err))
    sys.exit(1)
print ("verified that anchore-engine is up and ready")


# enter loop that exits if too much time has passed, or initial feed sync has completed
try:
    rc = wait_for_feed_sync(timeout=minutes*60, timer=timer)
except Exception as err:
    print ("could not verify feed sync has completed - exception: {}".format(err))
    sys.exit(1)
print ("verified feed sync has completed")

# finally, run each of these commands in series to dump the database SQL, stop the containers, commit the DB container as a new image, and bring tear everything else down
exclude_opts = ' '.join(['--exclude-table-data={}'.format(x) for x in ['anchore', 'users', 'services', 'leases', 'tasks', 'queues', 'queuemeta', 'queues', 'accounts', 'account_users', 'user_access_credentials']])
final_prepop_container_image = "anchore/engine-db-preload:dev"
cmds = [
    'docker-compose stop anchore-engine'.split(),
    "docker-compose exec anchore-db /bin/bash -c".split() + ['pg_dump -U postgres -Z 9 {} > /docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz'.format(exclude_opts)],
    'docker-compose stop'.split(),
    "docker commit {} {}".format(db_id, final_prepop_container_image).split(),
    'docker-compose down --volumes'.split(),
]
for cmd in cmds:
    try:
        print ("CMD: {}".format(cmd))
        sout = subprocess.check_output(cmd)
        print ("\tOUTPUT: {}".format(sout))
    except Exception as err:
        print ("CMD failed: {}".format(cmd))
        print ("bailing out")
        sys.exit(1)

print ("SUCCESS: new prepopulated container image created: {}".format(final_prepop_container_image))
sys.exit(0)
