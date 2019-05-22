#!/usr/bin/env bash

# Fail on any errors, including in pipelines
# Don't allow unset variables. Trace all functions with DEBUG trap
set -euo pipefail -o functrace

display_usage() {
    echo "${color_yellow}"
    cat << EOF
    Anchore Build Pipeline ---

    CI pipeline script for Anchore container images.
    Allows building container images & mocking CI pipelines.

    The following overide environment variables are available:
        
        SKIP_CLEANUP = [ true | false ] - skips cleanup job that runs on exit (kills containers & removes workspace)
        IMAGE_REPO = docker.io/example/test - specify a custom image repo to build/test
        WORKING_DIRECTORY = /home/test/workspace - used as a temporary workspace for build/test

    Usage: ${0##*/} <build> <test> <ci> <function_name>  [ function_args ] [ ... ] 
        
        build - Build a dev image tagged IMAGE_REPO:dev'
        test - Run test pipeline locally on your workstation
        ci - Run mocked CircleCI pipeline using Docker-in-Docker
        function_name - Invoke a function directly using build environment
EOF
    echo "${color_normal}"
}

##############################################
###   PROJECT SPECIFIC ENVIRONMENT SETUP   ###
##############################################

# Specify what versions to build & what version should get 'latest' tag
export BUILD_VERSIONS=('v0.4.0' 'v0.3.3' 'v0.3.4')
export LATEST_VERSION='v0.4.0'

set_environment_variables() {
    # PROJECT_VARS are custom vars that are modified between projects
    # Expand all required ENV vars or set to default values with := variable substitution
    # Use eval on $CIRCLE_WORKING_DIRECTORY to ensure ~ gets expanded to the absolute path
    export PROJECT_VARS=( \
        IMAGE_REPO=${IMAGE_REPO:=anchore/engine-db-preload} \
        CIRCLE_PROJECT_REPONAME=${CIRCLE_PROJECT_REPONAME:=engine-db-preload} \
        WORKING_DIRECTORY=${WORKING_DIRECTORY:=$(eval echo ${CIRCLE_WORKING_DIRECTORY:="${HOME}/ci_test_temp"})} \
    )
    setup_and_print_env_vars
}


#######################################################
###   MAIN PROGRAM FUNCTIONS - ALPHABETICAL ORDER   ###
###   functions are called by main bootsrap logic   ###
#######################################################

# The build() function is used to locally build the project image - ${IMAGE_REPO}:dev
build() {
    setup_build_environment
    compose_up_anchore_engine
    scripts/feed_sync_wait.py 240 10
}

# The cleanup() function that runs whenever the script exits
cleanup() {
    ret="$?"
    set +euo pipefail
    if [[ "$ret" -eq 0 ]]; then
        set +o functrace
    fi
    if [[ "$SKIP_FINAL_CLEANUP" == false ]]; then
        deactivate 2> /dev/null
        docker-compose down --volumes 2> /dev/null
        if [[ ! -z "$DOCKER_NAME" ]]; then
            docker kill "$DOCKER_NAME" 2> /dev/null
            docker rm "$DOCKER_NAME" 2> /dev/null
        fi
        popd &> /dev/null
        rm -rf "$WORKING_DIRECTORY"
    fi
    popd &> /dev/null
    exit "$ret"
}

# All ci_test_*() functions are used to mock a CircleCI environment pipeline utilizing Docker-in-Docker
ci_test_run_workflow() {
    setup_build_environment
    ci_test_job 'docker.io/anchore/test-infra:latest' 'build_and_save_images'
    ci_test_job 'docker.io/anchore/test-infra:latest' 'test_built_images'
    ci_test_job 'docker.io/anchore/test-infra:latest' 'push_all_versions'
}

# The main() function represents the full CI pipeline flow, can be used to run the test pipeline locally
main() {
    build_and_save_images
    test_built_images
    push_all_versions
}


#################################################################
###   FUNCTIONS CALLED DIRECTLY BY CIRCLECI - RUNTIME ORDER   ###
#################################################################

build_and_save_images() {
    setup_build_environment
    for version in "${BUILD_VERSIONS[@]}"; do
        # If the image/tag exists on DockerHub - build new image using DB from existing image
        if docker pull "${IMAGE_REPO}:${version}" &> /dev/null; then
            export COMPOSE_DB_IMAGE=$(eval echo "${IMAGE_REPO}:${version}")
        fi
        compose_up_anchore_engine "$version"
        scripts/feed_sync_wait.py 240 10
        compose_down_anchore_engine
        docker tag "${IMAGE_REPO}:dev" "${IMAGE_REPO}:dev-${version}"
        save_image "$version"
    done
}

test_built_images() {
    setup_build_environment
    for version in "${BUILD_VERSIONS[@]}"; do
        load_image "$version"
        export COMPOSE_DB_IMAGE=$(eval echo "${IMAGE_REPO}:dev-${version}")
        compose_up_anchore_engine "$version"
        run_tests "$version"
        compose_down_anchore_engine
    done
}

push_all_versions() {
    for version in "${BUILD_VERSIONS[@]}"; do
        load_image "$version"
        push_dockerhub "$version"
    done
}


###########################################################
###   PROJECT SPECIFIC FUNCTIONS - ALPHABETICAL ORDER   ###
###########################################################

compose_down_anchore_engine() {
    docker-compose down --volumes
    unset COMPOSE_DB_IMAGE COMPOSE_ENGINE_IMAGE
    # If running on circleCI kill forwarded socket to remote-docker
    if [[ "$CI" == true ]]; then
        ssh -S anchore -O exit remote-docker
        ssh remote-docker "sudo rm -rf ${WORKSPACE}/aevolume"
    else
        rm -rf "${WORKSPACE}/aevolume"
    fi
}

compose_up_anchore_engine() {
    local anchore_version="${1:-dev}"
    # set default values using := notation if COMPOSE vars aren't already set
    if [[ "$anchore_version" == 'dev' ]]; then
        export COMPOSE_DB_IMAGE=${COMPOSE_DB_IMAGE:="docker.io/anchore/engine-db-preload:latest"}
        export COMPOSE_ENGINE_IMAGE=${COMPOSE_ENGINE_IMAGE:="docker.io/anchore/anchore-engine-dev:latest"}
    else
        export COMPOSE_ENGINE_IMAGE=${COMPOSE_ENGINE_IMAGE:=$(eval echo "docker.io/anchore/anchore-engine:${anchore_version}")}
        export COMPOSE_DB_IMAGE=${COMPOSE_DB_IMAGE:="docker.io/postgres:9"}
    fi
    echo "COMPOSE_ENGINE_IMAGE=$COMPOSE_ENGINE_IMAGE"
    echo "COMPOSE_DB_IMAGE=$COMPOSE_DB_IMAGE"
    # If CircleCI build, create files/dirs on remote-docker
    if [[ "$CI" == true ]]; then
        ssh remote-docker "mkdir -p ${WORKSPACE}/aevolume/db ${WORKSPACE}/aevolume/config"
        scp config/config.yaml remote-docker:"${WORKSPACE}/aevolume/config/config.yaml"
    else
        mkdir -p "${WORKSPACE}/aevolume/db" "${WORKSPACE}/aevolume/config"
        cp -f config/config.yaml "${WORKSPACE}/aevolume/config/config.yaml"
    fi
    docker-compose up -d
    # If job is running in circleci forward remote-docker:8228 to localhost:8228
    if [[ "$CI" == true ]]; then
        ssh -MS anchore -fN4 -L 8228:localhost:8228 remote-docker
    fi
}

run_tests() {
    local anchore_version="$1"
    anchore-cli --u admin --p foobar --url http://localhost:8228/v1 system wait --feedsready "vulnerabilities,nvd"
    anchore-cli --u admin --p foobar --url http://localhost:8228/v1 system status
    anchore-cli --u admin --p foobar --url http://localhost:8228/v1 system feeds list
    # Don't clone anchore-engine if it already exists
    if [[ ! -d "${WORKSPACE}/anchore-engine" ]]; then
        git clone https://github.com/anchore/anchore-engine "${WORKSPACE}/anchore-engine"
    fi
    pushd "${WORKSPACE}/anchore-engine/scripts/tests"
    python aetest.py docker.io/alpine:latest
    python aefailtest.py docker.io/alpine:latest
    popd
}

setup_build_environment() {
    # Copy source code to $WORKING_DIRECTORY for mounting to docker volume as working dir
    if [[ ! -d "$WORKING_DIRECTORY" ]]; then
        mkdir -p "$WORKING_DIRECTORY"
        cp -a . "$WORKING_DIRECTORY"
    fi
    pushd "$WORKING_DIRECTORY"
    mkdir -p "${WORKSPACE}/caches" "${WORKSPACE}/aevolume/db" "${WORKSPACE}/aevolume/config"
    cp -f ${WORKING_DIRECTORY}/config/config.yaml "${WORKSPACE}/aevolume/config/config.yaml"
    # Install dependencies to system on CircleCI & virtualenv locally
    if [[ "$CI" == true ]]; then
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


########################################################
###   COMMON HELPER FUNCTIONS - ALPHABETICAL ORDER   ###
########################################################

ci_test_job() {
    local ci_image=$1
    local ci_function=$2
    export DOCKER_NAME="${RANDOM:-TEMP}-ci-test"
    docker run --net host -it --name "$DOCKER_NAME" -v "${WORKING_DIRECTORY}:${WORKING_DIRECTORY}" -v /var/run/docker.sock:/var/run/docker.sock "$ci_image" /bin/sh -c "\
        cd ${WORKING_DIRECTORY} && \
        export WORKING_DIRECTORY=${WORKING_DIRECTORY} && \
        sudo -E bash scripts/build.sh $ci_function \
    "
    docker stop "$DOCKER_NAME" && docker rm "$DOCKER_NAME"
}

load_image() {
    local anchore_version="$1"
    if [[ "$anchore_version" == 'dev' ]]; then
        docker load -i "${WORKSPACE}/caches/${CIRCLE_PROJECT_REPONAME}-dev.tar"
    else
        docker load -i "${WORKSPACE}/caches/${CIRCLE_PROJECT_REPONAME}-${anchore_version}-dev.tar"
    fi
}

push_dockerhub() {
    local anchore_version="$1"
    if [[ "$CI" == true ]]; then
        echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
    fi
    if [[ "$CIRCLE_BRANCH" == 'master' ]] && [[ "$CI" == true ]]; then
        docker tag "${IMAGE_REPO}:dev-${anchore_version}" "${IMAGE_REPO}:${anchore_version}"
        echo "Pushing to DockerHub - ${IMAGE_REPO}:${anchore_version}"
        docker push "${IMAGE_REPO}:${anchore_version}"
        if [ "$anchore_version" == "$LATEST_VERSION" ]; then
            docker tag "${IMAGE_REPO}:dev-${anchore_version}" "${IMAGE_REPO}:latest"
            echo "Pushing to DockerHub - ${IMAGE_REPO}:latest"
            docker push "${IMAGE_REPO}:latest"
        fi
    else
        if [[ "$anchore_version" == 'dev' ]]; then
            docker tag "${IMAGE_REPO}:dev" "anchore/private_testing:${CIRCLE_PROJECT_REPONAME}-${anchore_version}"
        else
            docker tag "${IMAGE_REPO}:dev-${anchore_version}" "anchore/private_testing:${CIRCLE_PROJECT_REPONAME}-${anchore_version}"
        fi
        echo "Pushing to DockerHub - anchore/private_testing:${CIRCLE_PROJECT_REPONAME}-${anchore_version}"
        if [[ "$CI" == false ]]; then
            sleep 10
        fi
        docker push "anchore/private_testing:${CIRCLE_PROJECT_REPONAME}-${anchore_version}"
    fi
}

save_image() {
    local anchore_version="$1"
    mkdir -p "${WORKSPACE}/caches"
    if [[ "$anchore_version" == 'dev' ]]; then
        docker save -o "${WORKSPACE}/caches/${CIRCLE_PROJECT_REPONAME}-dev.tar" "${IMAGE_NAME}:dev"
    else
        docker save -o "${WORKSPACE}/caches/${CIRCLE_PROJECT_REPONAME}-${anchore_version}-dev.tar" "${IMAGE_NAME}:dev-${anchore_version}"
    fi
}

setup_and_print_env_vars() {
    # Export & print all project env vars to the screen
    echo "${color_yellow}"
    printf "%s\n\n" "- ENVIRONMENT VARIABLES SET -"
    echo "BUILD_VERSIONS=${BUILD_VERSIONS[@]}"
    printf "%s\n" "LATEST_VERSION=$LATEST_VERSION"
    for var in ${PROJECT_VARS[@]}; do
        export "$var"
        printf "%s" "${color_yellow}"
        printf "%s\n" "$var"
    done
    # BUILD_VARS are static variables that don't change between projects
    declare -a BUILD_VARS=( \
        CI=${CI:=false} \
        CIRCLE_BRANCH=${CIRCLE_BRANCH:=dev} \
        SKIP_FINAL_CLEANUP=${SKIP_FINAL_CLEANUP:=false} \
        WORKSPACE=${WORKSPACE:=${WORKING_DIRECTORY}/workspace} \
    )
    # Export & print all build env vars to the screen
    for var in ${BUILD_VARS[@]}; do
        export "$var"
        printf "%s" "${color_yellow}"
        printf "%s\n" "$var"
    done
    echo "${color_normal}"
    # If running tests manually, sleep for a few seconds to give time to visually double check that ENV is setup correctly
    if [[ "$CI" == false ]]; then
        sleep 5
    fi
    # Trap all bash commands & print to screen. Like using set -v but allows printing in color
    trap 'printf "%s+ %s%s\n" "${color_cyan}" "${BASH_COMMAND}" "${color_normal}" >&2' DEBUG
}

########################################
###   MAIN PROGRAM BOOTSTRAP LOGIC   ###
########################################

# Save current working directory for cleanup on exit
pushd . &> /dev/null

# Trap all signals that cause script to exit & run cleanup function before exiting
trap 'cleanup' SIGINT SIGTERM ERR EXIT
trap 'printf "\n%s+ PIPELINE ERROR - exit code %s - cleaning up %s\n" "${color_red}" "$?" "${color_normal}"' SIGINT SIGTERM ERR

# Get ci_utils.sh from anchore test-infra repo - used for common functions
# If running on test-infra container ci_utils.sh is installed to /usr/local/bin/
# if [[ -f /usr/local/bin/ci_utils.sh ]]; then
#     source ci_utils.sh
# elif [[ -f "${WORKSPACE}/test-infra" ]]; then
#     source "${WORKSPACE}/test-infra/scripts/ci_utils.sh"
# else
#     git clone https://github.com/anchore/test-infra "${WORKSPACE}/test-infra"
#     source "${WORKSPACE}/test-infra/scripts/ci_utils.sh"
# fi

# Setup terminal colors for printing
export TERM=xterm
color_red=$(tput setaf 1)
color_cyan=$(tput setaf 6)
color_yellow=$(tput setaf 3)
color_normal=$(tput setaf 9)

set_environment_variables

# If no params are passed to script, build the image
# Run script with the 'test' param to execute the full pipeline locally
# Run script with the 'ci' param to execute a fully mocked CircleCI pipeline, running in docker
# If first param is a valid function name, execute the function & pass all following params to function
if [[ "$#" -eq 0 ]]; then
    display_usage >&2
    exit 1
elif [[ "$1" == 'build' ]];then
    build
elif [[ "$1" == 'test' ]]; then
    main
elif [[ "$1" == 'ci' ]]; then
    ci_test_run_workflow
else
    export SKIP_FINAL_CLEANUP=true
    if declare -f "$1" > /dev/null; then
        "$@"
    else
        display_usage >&2
        printf "%sERROR - %s is not a valid function name %s\n" "$color_red" "$1" "$color_normal" >&2
        exit 1
    fi
fi