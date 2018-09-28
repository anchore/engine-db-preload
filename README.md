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
...
...
...
attempt 100 / 150.0
got a good 200 response
got last full sync time - good to go!: 2018-09-28T19:21:28.346996Z
CMD: ['docker-compose', 'exec', 'anchore-db', '/bin/bash', '-c', 'pg_dump -U postgres -Z 9 > /docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz'] OUTPUT: 
Stopping aevolume_anchore-engine_1 ... done
Stopping aevolume_anchore-db_1 ... done
CMD: ['docker-compose', 'stop'] OUTPUT: 
CMD: ['docker', 'commit', 'aevolume_anchore-db_1', 'anchore/anchore-db-preload:latest'] OUTPUT: sha256:764cf0b7ef0d03fa8f42f98ee327a8ec1475bd53b9bc204b93a2b3045cb32443

Removing aevolume_anchore-engine_1 ... done
Removing aevolume_anchore-db_1 ... done
Removing network aevolume_default
CMD: ['docker-compose', 'down', '--volumes'] OUTPUT: 
SUCCESS!
```

4) the script will have brought down the anchore-engine/db containers, and will have created a new image tagged locally as 'anchore/anchore-db-preload:latest'.  That image should now be able to be pushed to 'docker.io/anchore/anchore-db-preload:latest' and used instead of a stock postgres:9 container for an anchore-engine DB.

