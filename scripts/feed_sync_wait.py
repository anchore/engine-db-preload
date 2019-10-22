#!/usr/bin/env python3

from __future__ import print_function
import argparse
import shlex
import json
import requests
import time
import sys
import subprocess
from datetime import datetime, timedelta

TIMEOUT=int(30)
INTERVAL=float(5.0)
SLIM_BUILD=False

def parse_args():
    parser = argparse.ArgumentParser(description="Creates a postgresql docker image, preloaded with Anchore Engine vulnerability data")
    parser.add_argument('timeout', type=int, help="Set sync timeout, defaults to 300 minutes")
    parser.add_argument('interval', type=float, help="Set sync check interval, defaults to 1 second")
    parser.add_argument('--slim', action='store_true', help="Do not include the nvdv2 vulnerability data")
    args = parser.parse_args()

    global TIMEOUT
    global INTERVAL
    global SLIM_BUILD

    try:
        TIMEOUT=int(args.timeout)
        if TIMEOUT > 300:
            TIMEOUT = int(300)
        elif TIMEOUT < 5:
            TIMEOUT = 5
    except:
        TIMEOUT=30
    try:
        INTERVAL=float(args.interval)
        if INTERVAL < 1.0:
            INTERVAL = 1.0
        elif INTERVAL > 60.0:
            INTERVAL = 60.0
    except:
        INTERVAL=5

    if args.slim:
        SLIM_BUILD=True

def main():
    print ("Starting Anchore feed sync\n\tTimeout: {} minutes\n\tSync Interval: {}\n\tSlim Build: {}".format(TIMEOUT, INTERVAL, SLIM_BUILD))

    # before we get started, verify that anchore-engine and anchore-db are up and running
    try:
        engine_id, db_id = discover_anchore_ids()
    except Exception as err:
        print ("could not discover anchore-engine and anchore-db IDs - exception: {}".format(err))
        sys.exit(1)
    print ("got container IDs: engine={} db={}".format(engine_id, db_id))

    # next, ensure that anchore-engine is fully up and responsive, ready to handle feed sync list API call
    try:
        verify_anchore_engine_available(timeout=TIMEOUT*60, interval=INTERVAL)
    except Exception as err:
        print ("anchore-engine is not running or available - exception: {}".format(err))
        sys.exit(1)
    print ("verified that anchore-engine is up and ready")

    try:
        sync_feeds(timeout=TIMEOUT*60)
    except Exception as err:
        print ("could not verify feed sync has completed - exception: {}".format(err))
        sys.exit(1)

    # enter loop that exits if too much time has passed, or initial feed sync has completed
    try:
        wait_for_feed_sync(timeout=TIMEOUT*60, interval=INTERVAL)
    except Exception as err:
        print ("could not verify feed sync has completed - exception: {}".format(err))
        sys.exit(1)
    print ("verified feed sync has completed")

    # finally, run each of these commands in series to dump the database SQL, stop the containers, commit the DB container as a new image, and bring tear everything else down
    if SLIM_BUILD:
        exclude_opts = ' '.join(['--exclude-table-data={}'.format(x) for x in ['anchore', 'users', 'services', 'leases', 'tasks', 'queues', 'queuemeta', 'queues', 'accounts', 'account_users', 'user_access_credentials', 'feed_data_nvdv2_vulnerabilities', 'feed_data_cpev2_vulnerabilities']])
    else:
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

def execute(cmd):
    popen = subprocess.Popen(cmd, stdout=subprocess.PIPE, universal_newlines=True)
    for stdout_line in iter(popen.stdout.readline, ""):
        yield stdout_line 
    popen.stdout.close()
    return_code = popen.wait()
    if return_code:
        raise subprocess.CalledProcessError(return_code, cmd)

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

        time.sleep(INTERVAL)
        if time.time() - start_ts > timeout:
            raise Exception("timed out waiting for feeds to sync after {} seconds".format(timeout))

def wait_for_feed_sync(user='admin', pw='foobar', timeout=300, interval=5.0, url="http://localhost:8228/v1"):
    cmd = 'anchore-cli --u {} --p {} --url {} system wait --timeout {} --interval {} --feedsready vulnerabilities'.format(user, pw, url, timeout, interval)
    try:
        for line in execute(cmd.split()):
            print(line, end="")
    except Exception as err:
        print("failed to execute cmd: {}. Error - {}".format(cmd, err))
    return(True)

def verify_anchore_engine_available(user='admin', pw='foobar', timeout=300, interval=5.0, url="http://localhost:8228/v1"):
    cmd = 'anchore-cli --u {} --p {} --url {} system wait --timeout {} --interval {} --feedsready ""'.format(user, pw, url, timeout, interval)
    try:
        for line in execute(shlex.split(cmd)):
            print(line, end="")
    except Exception as err:
        print("failed to execute cmd: {}. Error - {}".format(cmd, err))

    return(True)

if __name__ == '__main__':
    try:
        parse_args()
        main()
    except KeyboardInterrupt:
        print ("\n\nReceived interupt signal. Exiting...")
        sys.exit(130)
    except Exception as error:
        print ("\n\nERROR executing script - Exception: {}".format(error))
        sys.exit(1)