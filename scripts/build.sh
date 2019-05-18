#!/usr/bin/env bash

setup_anchore_engine() {
    local anchore_version=$1
    sed -i "s/ANCHORE_VERSION/${anchore_version}/g" docker-compose.yaml
    ssh remote-docker 'mkdir -p ${HOME}/anchore/db ${HOME}/anchore/config'
    scp config/config.yaml remote-docker:"\${HOME}/anchore/config/config.yaml"
    docker-compose up -d
    # Forward remote-docker:8228 to localhost:8228
    ssh -MS anchore -fN4 -L 8228:localhost:8228 remote-docker
}

stop_anchore_engine() {
    docker-compose down --volumes
    # Kill forwarded socket
    ssh -S anchore -O exit remote-docker
    ssh remote-docker 'sudo rm -rf ${HOME}/anchore'
}

run_tests() {
    local anchore_version=$1
    anchore-cli --u admin --p foobar --url http://localhost:8228/v1 system wait --feedsready "vulnerabilities,nvd"
    anchore-cli --u admin --p foobar --url http://localhost:8228/v1 system status
    anchore-cli --u admin --p foobar --url http://localhost:8228/v1 system feeds list
    git clone git@github.com:anchore/anchore-engine.git
    pushd anchore-engine/scripts/tests
    python aetest.py docker.io/alpine:latest anchore-cli
    python aefailtest.py docker.io/alpine:latest anchore-cli
    popd
}

save_image() {
    local anchore_version=$1
    mkdir -p /home/circleci/workspace/caches
    docker save -o "/home/circleci/workspace/caches/${CIRCLE_PROJECT_REPONAME}-${anchore_version}-ci.tar" "${IMAGE_NAME}:dev-${anchore_version}"
}

load_image() {
    local anchore_version=$1
    docker load -i "/home/circleci/workspace/caches/${CIRCLE_PROJECT_REPONAME}-${anchore_version}-ci.tar"
}

push_dockerhub() {
    local anchore_version=$1
    echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
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
        docker tag "${IMAGE_NAME}:dev" "anchore/private_testing:engine-db-preload-${CIRCLE_BRANCH}-${anchore_version}"
        docker push "anchore/private_testing:engine-db-preload-${CIRCLE_BRANCH}-${anchore_version}"
    fi
}