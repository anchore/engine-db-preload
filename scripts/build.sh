#!/usr/bin/env bash

echo "IMAGE_NAME=${IMAGE_NAME:=anchore/engine-db-preload}"
echo "CIRCLE_PROJECT_REPONAME=${CIRCLE_PROJECT_REPONAME:=engine-db-preload}"
echo "CIRCLE_BRANCH=${CIRCLE_BRANCH:=dev}"
eval "${CIRCLECI_BUILD:=true}"

set -euxo pipefail

cleanup() {
    ret="$?"
    set +e
    popd
    if ! "$CIRCLECI_BUILD"; then
        if [[ -d .venv ]]; then
            deactivate
            rm -rf .venv
        fi
        cp -f ${HOME}/workspace/docker-compose.yaml docker-compose.yaml
        rm -rf ${HOME}/workspace
        docker-compose down --volumes
    fi
    exit "$ret"
}

trap 'cleanup' EXIT SIGINT SIGTERM ERR

install_dependencies() {
    virtualenv .venv
    source .venv/bin/activate
    pip install --upgrade pip
    pip install --upgrade docker-compose
    pip install --upgrade anchorecli
}

setup_anchore_engine() {
    local anchore_version=$1
    sed -i "s/ANCHORE_VERSION/${anchore_version}/g" docker-compose.yaml
    if "$CIRCLECI_BUILD";then
        ssh remote-docker 'mkdir -p ${HOME}/workspace/db ${HOME}/workspace/config'
        scp config/config.yaml remote-docker:"\${HOME}/workspace/config/config.yaml"
    else
        mkdir -p ${HOME}/workspace/db ${HOME}/workspace/config
        cp config/config.yaml ${HOME}/workspace/config/config.yaml
    fi
    docker-compose up -d

    # If job is running in circleci forward remote-docker:8228 to localhost:8228
    if "$CIRCLECI_BUILD";then
        ssh -MS anchore -fN4 -L 8228:localhost:8228 remote-docker
    fi
}

stop_anchore_engine() {
    docker-compose down --volumes
    if "$CIRCLECI_BUILD";then
        # Kill forwarded socket
        ssh -S anchore -O exit remote-docker
        ssh remote-docker 'sudo rm -rf ${HOME}/workspace'
    fi
}

run_tests() {
    local anchore_version=$1
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
    local anchore_version=$1
    mkdir -p ${HOME}/workspace/caches
    docker save -o "${HOME}/workspace/caches/${CIRCLE_PROJECT_REPONAME}-${anchore_version}-ci.tar" "${IMAGE_NAME}:dev-${anchore_version}"
}

load_image() {
    local anchore_version=$1
    docker load -i "${HOME}/workspace/caches/${CIRCLE_PROJECT_REPONAME}-${anchore_version}-ci.tar"
}

push_dockerhub() {
    local anchore_version=$1
    if [[ ! -z ${DOCKER_PASS+x} ]] && [[ ! -z ${DOCKER_USER+x} ]]; then
        echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
    fi
    echo ${IMAGE_NAME}:${anchore_version}
    if [ "$CIRCLE_BRANCH" == "master" ]; then
        docker tag "${IMAGE_NAME}:dev-${anchore_version}" "${IMAGE_NAME}:${anchore_version}"
        docker push "${IMAGE_NAME}:${anchore_version}"
        ANCHORE_LATEST_TAG=$(git ls-remote --tags --refs --sort="v:refname" git://github.com/anchore/anchore-engine.git | tail -n1 | sed 's/.*\///')
        if [ ${anchore_version} == $ANCHORE_LATEST_TAG ]; then
            docker tag "${IMAGE_NAME}:dev-${anchore_version}" "${IMAGE_NAME}:latest"
            docker push "${IMAGE_NAME}:latest"
        fi
    else
        docker tag "${IMAGE_NAME}:dev-${anchore_version}" "anchore/private_testing:engine-db-preload-${CIRCLE_BRANCH}-${anchore_version}"
        docker push "anchore/private_testing:engine-db-preload-${CIRCLE_BRANCH}-${anchore_version}"
    fi
}

setup_build_environment() {
    mkdir -p ${HOME}/workspace
    cp docker-compose.yaml ${HOME}/workspace/docker-compose.yaml
    install_dependencies
}

build_and_save_image() {
    for version in $(cat .circleci/build_versions.txt); do
        cp -f ${HOME}/workspace/docker-compose.yaml docker-compose.yaml
        if docker pull ${IMAGE_NAME}:${version} &> /dev/null; then
            sed -i "s|postgres:9|${IMAGE_NAME}:${version}|g" docker-compose.yaml
        fi
        setup_anchore_engine $version
        scripts/feed_sync_wait.py 240 10
        stop_anchore_engine
        docker tag ${IMAGE_NAME}:dev ${IMAGE_NAME}:dev-${version}
        save_image $version
    done
}

compose_up_and_test() {
    for version in $(cat .circleci/build_versions.txt); do
        load_image $version
        cp -f ${HOME}/workspace/docker-compose.yaml docker-compose.yaml
        sed -i "s|postgres:9|${IMAGE_NAME}:dev-${version}|g" docker-compose.yaml
        setup_anchore_engine $version
        run_tests $version
        stop_anchore_engine
    done
}

push_all_versions() {
    for version in $(cat .circleci/build_versions.txt); do
        load_image $version
        push_dockerhub $version
    done
}

main() {
    setup_build_environment
    build_and_save_image
    compose_up_and_test
    push_all_versions
}

if [[ $# -eq 0 ]]; then
    export CIRCLECI_BUILD=false
    main
else
    if declare -f "$1" > /dev/null; then
        "$@"
    else
        echo "$@ is not a valid function name"
        exit 1
    fi
fi