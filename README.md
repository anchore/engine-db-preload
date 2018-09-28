# engine-db-preload
Some scripting to handling creation of preloaded anchore DB container

The purpose of this repo is to host scripts to coordinate the creation of pre-populated database containers for anchore-engine.

1) set up a regular docker-compose-style setup for anchore-engine
2) run the feed_sync_wait.py command from this repo.  The parameters are 'number of minutes to wait total for the check to complete' and 'interval between polling updates to see if feed sync is complete'.  In the following example, the values represent 'wait 30 minutes before bailing out, with 5 second intervals between polling attempts'.

```
cd ~/aevolume/
docker-compose up -d
...
/path/to/scripts/feed_sync_wait.py 30 5
```

3) if successful, the end of this run will look like:

```
got container IDs: engine=ee40c64242830f4bd75be25a0b9a2c0e044bb2ce4ca95f69e8c7ccc672391326 db=96f50d2b33f175783e0893ed4b1b7f11614036b0f564dd4e441ef320cff52138
engine not up yet - exception: ('Connection aborted.', error(104, 'Connection reset by peer'))
engine not up yet - exception: ('Connection aborted.', error(104, 'Connection reset by peer'))
engine not up yet - exception: ('Connection aborted.', error(104, 'Connection reset by peer'))
...
...
...
verified that anchore-engine is up and ready

attempt 0 / 600
got last full sync time - good to go!: 2018-09-28T22:59:47.912693Z
verified feed sync has completed
CMD: ['docker-compose', 'stop', 'anchore-engine']
Stopping testtest_anchore-engine_1 ... 
Stopping testtest_anchore-engine_1 ... done
	OUTPUT: 
CMD: ['docker-compose', 'exec', 'anchore-db', '/bin/bash', '-c', 'pg_dump -U postgres -Z 9 > /docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz']
	OUTPUT: 

CMD: ['docker-compose', 'stop']
Stopping testtest_anchore-db_1 ... done
	OUTPUT: 
CMD: ['docker', 'commit', '96f50d2b33f175783e0893ed4b1b7f11614036b0f564dd4e441ef320cff52138', 'anchore/engine-db-preload:latest']
	OUTPUT: sha256:3207abeeeb6cb25d6e06714c0d0ccca9eb1a4c18f5aed61486a8cbe6f3436faa

CMD: ['docker-compose', 'down', '--volumes']
Removing testtest_anchore-engine_1 ... done
Removing testtest_anchore-db_1 ... done
Removing network testtest_default
	OUTPUT: 
SUCCESS: new prepopulated container image created: anchore/engine-db-preload:latest
```

4) the script will have brought down the anchore-engine/db containers, and will have created a new image tagged locally as 'anchore/engine-db-preload:latest'.  That image should now be able to be pushed to 'docker.io/anchore/engine-db-preload:latest' and used instead of a stock postgres:9 container for an anchore-engine DB.

If the script fails for any reason, it will bail with exit code 1, otherwise it will exit 0 on success.
