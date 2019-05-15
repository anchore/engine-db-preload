#!/usr/bin/env bash

setup_anchore_engine() {
    local version=$1
    sed -i "s/ANCHORE_VERSION/${version}/" docker-compose.yaml
    mkdir db
    docker-compose up -d
    docker logs anchore-engine
}

run_tests() {
    local version=$1
    docker run -td --net=host --name anchore-cli docker.io/anchore/engine-cli:latest tail -f /dev/null
    anchore-cli --u admin --p foobar --url http://localhost:8228/v1 system wait --feedsready "vulnerabilities,nvd"
    anchore-cli --u admin --p foobar --url http://localhost:8228/v1 system status
    git clone git@github.com:anchore/anchore-engine.git
    pushd anchore-engine
    git checkout tags/${version}
    pushd scripts/tests
    python aetest.py docker.io/alpine:latest anchore-cli
    python aefailtest.py docker.io/alpine:latest anchore-cli
    popd
    popd
}

save_image() {
    local version=$1
    mkdir -p /home/circleci/workspace/caches
    docker save -o "/home/circleci/workspace/caches/${CIRCLE_PROJECT_REPONAME}-${version}-ci.tar" "${IMAGE_NAME}:dev"
}

load_image() {
    local version=$1
    docker load -i "/home/circleci/workspace/caches/${CIRCLE_PROJECT_REPONAME}-${version}-ci.tar"
}

push_dockerhub() {
    local version=$1
    echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
    echo ${IMAGE_NAME}:${version}
    if [ "$CIRCLE_BRANCH" == "master" ]; then
        docker tag "${IMAGE_NAME}:dev" "${IMAGE_NAME}:${version}"
        docker push "${IMAGE_NAME}:${version}"
        ANCHORE_LATEST_TAG=$(git ls-remote --tags --refs --sort="v:refname" git://github.com/anchore/anchore-engine.git | tail -n1 | sed 's/.*\///')
        if [ ${version} == $ANCHORE_LATEST_TAG ]; then
            docker tag "${IMAGE_NAME}:dev" "${IMAGE_NAME}:latest"
            docker push "${IMAGE_NAME}:latest"
        fi
    else
        docker tag "${IMAGE_NAME}:dev" "anchore/private_testing:engine-db-preload-${CIRCLE_BRANCH}-${version}"
        docker push "anchore/private_testing:engine-db-preload-${CIRCLE_BRANCH}-${version}"
    fi
}