#!/usr/bin/env bash

echo "IMAGE_NAME=${IMAGE_NAME:=anchore/engine-db-preload}"
echo "CIRCLE_PROJECT_REPONAME=${CIRCLE_PROJECT_REPONAME:=engine-db-preload}"
echo "CIRCLE_BRANCH=${CIRCLE_BRANCH:=dev}"
eval "${CIRCLECI_BUILD:=true}"

set -euxo pipefail

cleanup() {
    ret="$?"
    set +euxo pipefail
    popd 2> /dev/null
    if ! "$CIRCLECI_BUILD"; then
        deactivate
        rm -rf .venv
        cp -f "${HOME}/workspace/docker-compose.yaml" docker-compose.yaml
        rm -rf "${HOME}/workspace"
        docker-compose down --volumes
    fi
    exit "$ret"
}

trap 'cleanup' EXIT SIGINT SIGTERM ERR

install_dependencies() {
    if "$CIRCLECI_BUILD"; then
        sudo pip install --upgrade pip
        sudo pip install --upgrade docker-compose
        sudo pip install --upgrade anchorecli
    else
        virtualenv .venv
        source .venv/bin/activate
        pip install --upgrade pip
        pip install --upgrade docker-compose
        pip install --upgrade anchorecli
    fi
}

setup_anchore_engine() {
    # If a parameter isn't passed, use engine-db-preload:latest & anchore-engine-dev:latest
    if [[ "$#" -eq 0 ]]; then
        sed -i "s#postgres:9#anchore/engine-db-preload:latest#g" docker-compose.yaml
        sed -i "s/anchore-engine:ANCHORE_VERSION/anchore-engine-dev:latest/g" docker-compose.yaml
    else
        local anchore_version="$1"
        sed -i "s/ANCHORE_VERSION/${anchore_version}/g" docker-compose.yaml
    fi
    # If circleCI build, create files/dirs on remote-docker
    if "$CIRCLECI_BUILD"; then
        ssh remote-docker 'mkdir -p ${HOME}/workspace/aevolume/db ${HOME}/workspace/aevolume/config'
        scp config/config.yaml remote-docker:"\${HOME}/workspace/aevolume/config/config.yaml"
    else
        mkdir -p "${HOME}/workspace/aevolume/db" "${HOME}/workspace/aevolume/config"
        cp config/config.yaml "${HOME}/workspace/aevolume/config/config.yaml"
    fi
    docker-compose up -d

    # If job is running in circleci forward remote-docker:8228 to localhost:8228
    if "$CIRCLECI_BUILD"; then
        ssh -MS anchore -fN4 -L 8228:localhost:8228 remote-docker
    fi
}

stop_anchore_engine() {
    docker-compose down --volumes
    # If running on circleCI kill forwarded socket to remote-docker
    if "$CIRCLECI_BUILD"; then
        ssh -S anchore -O exit remote-docker
        ssh remote-docker 'sudo rm -rf ${HOME}/workspace/aevolume'
    else
        rm -rf "${HOME}/workspace/aevolume"
    fi
}

run_tests() {
    local anchore_version="$1"
    anchore-cli --u admin --p foobar --url http://localhost:8228/v1 system wait --feedsready "vulnerabilities,nvd"
    anchore-cli --u admin --p foobar --url http://localhost:8228/v1 system status
    anchore-cli --u admin --p foobar --url http://localhost:8228/v1 system feeds list
    if [[ ! -d "${HOME}/workspace/anchore-engine" ]]; then
        git clone git@github.com:anchore/anchore-engine.git "${HOME}/workspace/anchore-engine"
    fi
    pushd "${HOME}/workspace/anchore-engine"/scripts/tests
    python aetest.py docker.io/alpine:latest
    python aefailtest.py docker.io/alpine:latest
    popd
}

save_image() {
    local anchore_version="$1"
    mkdir -p "${HOME}/workspace/caches"
    docker save -o "${HOME}/workspace/caches/${CIRCLE_PROJECT_REPONAME}-${anchore_version}-ci.tar" "${IMAGE_NAME}:dev-${anchore_version}"
}

load_image() {
    local anchore_version="$1"
    docker load -i "${HOME}/workspace/caches/${CIRCLE_PROJECT_REPONAME}-${anchore_version}-ci.tar"
}

push_dockerhub() {
    local anchore_version="$1"
    if "$CIRCLECI_BUILD"; then
        echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
    fi
    if [ "$CIRCLE_BRANCH" == 'master' ] && "$CIRCLECI_BUILD"; then
        docker tag "${IMAGE_NAME}:dev-${anchore_version}" "${IMAGE_NAME}:${anchore_version}"
        echo "Pushing to DockerHub - ${IMAGE_NAME}:${anchore_version}"
        docker push "${IMAGE_NAME}:${anchore_version}"
        local anchore_latest_tag=$(git ls-remote --tags --refs --sort="v:refname" git://github.com/anchore/anchore-engine.git | tail -n1 | sed 's/.*\///')
        if [ "$anchore_version" == "$anchore_latest_tag" ]; then
            docker tag "${IMAGE_NAME}:dev-${anchore_version}" "${IMAGE_NAME}:latest"
            echo "Pushing to DockerHub - ${IMAGE_NAME}:latest"
            docker push "${IMAGE_NAME}:latest"
        fi
    else
        docker tag "${IMAGE_NAME}:dev-${anchore_version}" "anchore/private_testing:engine-db-preload-${CIRCLE_BRANCH}-${anchore_version}"
        echo "Pushing to DockerHub - anchore/private_testing:engine-db-preload-${CIRCLE_BRANCH}-${anchore_version}"
        docker push "anchore/private_testing:engine-db-preload-${CIRCLE_BRANCH}-${anchore_version}"
    fi
}

########################################################
## FUNCTIONS CALLED BY CIRCLECI START HERE ##
########################################################

setup_build_environment() {
    mkdir -p "${HOME}/workspace/aevolume"
    cp docker-compose.yaml "${HOME}/workspace/docker-compose.yaml"
    install_dependencies
}

build_and_save_image() {
    for version in $(cat versions.txt); do
        cp -f ${HOME}/workspace/docker-compose.yaml docker-compose.yaml
        if docker pull "${IMAGE_NAME}:${version}" &> /dev/null; then
            sed -i "s|postgres:9|${IMAGE_NAME}:${version}|g" docker-compose.yaml
        fi
        setup_anchore_engine "$version"
        scripts/feed_sync_wait.py 240 10
        stop_anchore_engine
        docker tag "${IMAGE_NAME}:dev" "${IMAGE_NAME}:dev-${version}"
        save_image "$version"
    done
}

compose_up_and_test() {
    for version in $(cat versions.txt); do
        load_image "$version"
        cp -f "${HOME}/workspace/docker-compose.yaml" docker-compose.yaml
        sed -i "s|postgres:9|${IMAGE_NAME}:dev-${version}|g" docker-compose.yaml
        setup_anchore_engine "$version"
        run_tests "$version"
        stop_anchore_engine
    done
}

push_all_versions() {
    for version in $(cat versions.txt); do
        load_image "$version"
        push_dockerhub "$version"
    done
}

################################
### MAIN PROGRAM BEGINS HERE ###
################################

# Function for testing a full CircleCI pipeline
run_full_ci_test() {
    setup_build_environment
    build_and_save_image
    compose_up_and_test
    push_all_versions
}

# if no params are pass to script, build image using latest DB & Engine.
if [[ "$#" -eq 0 ]]; then
    export CIRCLECI_BUILD=false
    setup_build_environment
    setup_anchore_engine
    scripts/feed_sync_wait.py 240 10
# Run full test suite if 'test' param is passed
elif [[ "$1" == 'test' ]]; then
    export CIRCLECI_BUILD=false
    run_full_ci_test
# If params are a valid function name, execute the functions sequentially
else
    for i in "$@"; do
        if declare -f "$i" > /dev/null; then
            "$i"
        else
            set +x
            echo "$1 is not a valid function name"
            exit 1
        fi
    done
fi