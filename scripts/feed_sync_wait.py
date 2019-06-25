#!/usr/bin/env python

from __future__ import print_function
import shlex
import json
import requests
import time
import sys
import subprocess
from datetime import datetime, timedelta

def execute(cmd):
    popen = subprocess.Popen(cmd, stdout=subprocess.PIPE, universal_newlines=True)
    for stdout_line in iter(popen.stdout.readline, ""):
        yield stdout_line 
    popen.stdout.close()
    return_code = popen.wait()
    if return_code:
        raise subprocess.CalledProcessError(return_code, cmd)

def discover_anchore_ids():
    # first, get the container ID of the anchore-db postgres container
    db_id = engine_id = None
    try:
        cmd = "docker-compose ps -q anchore-db"
        db_id = subprocess.check_output(cmd.split()).strip()

        cmd = "docker-compose ps -q anchore-engine"
        engine_id = subprocess.check_output(cmd.split()).strip()
    except Exception:
        raise Exception("command failed getting container ID: {}".format(cmd))

    if not engine_id or not db_id:
        raise Exception("bailing out - anchore-engine (discovered id={}) and anchore-db (discovered_id={}) must be running before executing this script".format(engine_id, db_id))

    return(engine_id, db_id)

def verify_anchore_engine_available(user='admin', pw='foobar', timeout=300, url="http://localhost:8228/v1"):
    cmd = 'anchore-cli --u {} --p {} --url {} system wait --timeout {} --feedsready ""'.format(user, pw, url, timeout)
    try:
        for line in execute(shlex.split(cmd)):
            print(line, end="")
    except Exception as err:
        print("failed to execute cmd: {}. Error - {}".format(cmd, err))

    return(True)

def sync_feeds(timeout=300, user='admin', pw='foobar', feed_sync_url="http://localhost:8228/v1/system/feeds"):
    cmd = 'curl -u {}:{} -X POST {}?sync=true'.format(user, pw, feed_sync_url).split()
    popen = subprocess.Popen(cmd)
    start_ts = time.time()
    while not popen.poll():
        try:
            r = requests.get(feed_sync_url, auth=('admin', 'foobar'), verify=False, timeout=20)
            if r.status_code == 200:
                data = json.loads(r.text)
                synced = 0
                total = 0
                synced_names = []
                unsynced_names = []
                for sync_record in data:
                    for group in sync_record.get('groups', []):
                        last_sync = group.get('last_sync', None)
                        if last_sync:
                            last_sync_datetime = datetime.strptime(last_sync.replace('T',''), '%Y-%m-%d%H:%M:%S.%f')
                            if (datetime.utcnow() - last_sync_datetime) < timedelta(hours=12):
                                synced = synced+1
                                synced_names.append(group.get('name', ""))
                            else:
                                unsynced_names.append(group.get('name', ""))
                        else:
                            unsynced_names.append(group.get('name', ""))
                        total = total+1
                timestamp=datetime.now().strftime('%x_%X')
                print ("{} - {} / {} groups completed".format(timestamp, synced, total))
                print ("\tsynced: {}\n\tunsynced: {}\n".format(synced_names, unsynced_names))
            else:
                print ("got bad response, trying again httpcode={} data={}".format(r.status_code, r.text))

        except Exception as err:
            raise Exception("cannot contact engine yet for system feeds list status - exception: {}".format(err))

        if not popen.returncode == None:
            if popen.returncode == 0:
                return True
            else:
                raise Exception("Feed sync initialization failed.")

        time.sleep(timer)
        if time.time() - start_ts > timeout:
            raise Exception("timed out waiting for feeds to sync after {} seconds".format(timeout))

def wait_for_feed_sync(user='admin', pw='foobar', timeout=300, url="http://localhost:8228/v1"):
    cmd = 'anchore-cli --u {} --p {} --url {} system wait --timeout {} --feedsready vulnerabilities,nvd'.format(user, pw, url, timeout)
    try:
        for line in execute(cmd.split()):
            print(line, end="")
    except Exception as err:
        print("failed to execute cmd: {}. Error - {}".format(cmd, err))
    return(True)

#### MAIN PROGRAM STARTS HERE ####

# prep input from CLI
if len(sys.argv) <= 1:
    print ("USAGE: {} <minutes to wait total> <intermediate check timer>".format(sys.argv[0]))
    sys.exit(1)

try:
    minutes = int(sys.argv[1])
    if minutes > 300:
        minutes = 300
    elif minutes < 5:
        minutes = 5
except:
    minutes = 30
try:
    timer = float(sys.argv[2])
    if timer < 1.0:
        timer = 1.0
    elif timer > 60.0:
        timer = 60.0
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
    rc = verify_anchore_engine_available(timeout=minutes*60)
except Exception as err:
    print ("anchore-engine is not running or available - exception: {}".format(err))
    sys.exit(1)
print ("verified that anchore-engine is up and ready")

try:
    rc = sync_feeds(timeout=minutes*60)
except Exception as err:
    print ("could not verify feed sync has completed - exception: {}".format(err))
    sys.exit(1)

# enter loop that exits if too much time has passed, or initial feed sync has completed
try:
    rc = wait_for_feed_sync(timeout=minutes*60)
except Exception as err:
    print ("could not verify feed sync has completed - exception: {}".format(err))
    sys.exit(1)
print ("verified feed sync has completed")

# finally, run each of these commands in series to dump the database SQL, stop the containers, commit the DB container as a new image, and bring tear everything else down
exclude_opts = ' '.join(['--exclude-table-data={}'.format(x) for x in ['anchore', 'users', 'services', 'leases', 'tasks', 'queues', 'queuemeta', 'queues', 'accounts', 'account_users', 'user_access_credentials']])
final_prepop_container_image = "anchore/engine-db-preload:dev"
cmds = [
    'docker-compose stop anchore-engine'.split(),
    "docker-compose exec -T anchore-db /bin/bash -c".split() + ['pg_dump -U postgres -Z 9 {} > /docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz'.format(exclude_opts)],
    'docker cp anchore-db:/docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz .'.split(),
    'docker-compose down --volumes'.split(),
]
for cmd in cmds:
    try:
        print ("CMD: {}".format(cmd))
        sout = subprocess.check_output(cmd)
        print ("OUTPUT: {}".format(sout))
    except Exception as err:
        print ("CMD failed: {} - with error: {}".format(cmd, err))
        print ("bailing out")
        sys.exit(1)

print ("SUCCESS: new prepopulated container image created: {}".format(final_prepop_container_image))
sys.exit(0)
