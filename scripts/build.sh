#!/usr/bin/env bash

# Fail on any errors, including in pipelines
# Don't allow unset variables. Trace all functions with DEBUG trap
set -eo pipefail -o functrace

display_usage() {
    echo "${color_yellow}"
    cat << EOF
    Anchore Build Pipeline ---

    CI pipeline script for Anchore container images.
    Allows building container images & mocking CI pipelines.

    The following overide environment variables are available:
        
        SKIP_CLEANUP = [ true | false ] - skips cleanup job that runs on exit (kills containers & removes workspace)
        IMAGE_REPO = docker.io/example/test - specify a custom image repo to build/test
        WORKING_DIRECTORY = /home/test/workdir - used as a temporary workspace for build/test
        WORKSPACE = /home/test/workspace - used to store temporary artifacts

    Usage: ${0##*/} [ -f | -s ] [ build | test | ci | function_name ]  < build_version >
        
        f - Force sync from a fresh postgresql image
        s - Build slim preloaded image without nvd2 feed data
        build - Build a dev image tagged IMAGE_REPO:dev'
        test - Run full ci pipeline locally on your workstation
        ci - Run mocked CircleCI pipeline using Docker-in-Docker
        function_name - Invoke a function directly using build environment
EOF
    echo "${color_normal}"
}

##############################################
###   PROJECT SPECIFIC ENVIRONMENT SETUP   ###
##############################################

# Specify what versions to build & what version should get 'latest' tag
export BUILD_VERSIONS=('v0.6.1' 'v0.6.0' 'v0.5.2' 'v0.5.1')
export LATEST_VERSION='v0.6.1'

# PROJECT_VARS are custom vars that are modified between projects
# Expand all required ENV vars or set to default values with := variable substitution
# Use eval on $CIRCLE_WORKING_DIRECTORY to ensure default value (~/project) gets expanded to the absolute path
export PROJECT_VARS=( \
    "IMAGE_REPO=${IMAGE_REPO:=anchore/engine-db-preload}" \
    "PROJECT_REPONAME=${CIRCLE_PROJECT_REPONAME:=engine-db-preload}" \
    "WORKING_DIRECTORY=${WORKING_DIRECTORY:=$(eval echo ${CIRCLE_WORKING_DIRECTORY:="${HOME}/tempci_${IMAGE_REPO##*/}_${RANDOM}/project"})}" \
    "WORKSPACE=${WORKSPACE:=$(dirname "$WORKING_DIRECTORY")/workspace}" \
)
# These vars are static & defaults should not need to be changed
PROJECT_VARS+=( \
    "CI=${CI:=false}" \
    "GIT_BRANCH=${CIRCLE_BRANCH:=dev}" \
    "SKIP_FINAL_CLEANUP=${SKIP_FINAL_CLEANUP:=false}" \
)


########################################
###   MAIN PROGRAM BOOTSTRAP LOGIC   ###
########################################

main() {
    if [[ "$#" -eq 0 ]]; then
        echo "ERROR - $0 requires at least 1 input" >&2
        display_usage >&2
        exit 1
    fi

    while getopts ':fsh' option; do
        case "${option}" in
            f  ) f_flag=true;;
            s  ) s_flag=true;;
            h  ) display_usage; exit;;
            \? ) printf "\n\t%s\n\n" "Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
            :  ) printf "\n\t%s\n\n%s\n\n" "Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
        esac
    done
    shift "$((OPTIND - 1))"

    PROJECT_VARS+=( \
        "FORCE_FRESH_SYNC=${f_flag:=false}" \
        "SLIM_BUILD=${s_flag:=false}" \
    )

    # Save current working directory for cleanup on exit
    pushd . &> /dev/null

    # Trap all signals that cause script to exit & run cleanup function before exiting
    trap 'cleanup' SIGINT SIGTERM ERR EXIT
    trap 'printf "\n%s+ PIPELINE ERROR - exit code %s - cleaning up %s\n" "${color_red}" "$?" "${color_normal}"' SIGINT SIGTERM ERR

    # Get ci_utils.sh from anchore test-infra repo - used for common functions
    # If running on test-infra container ci_utils.sh is installed to /usr/local/bin/
    # if [[ -f /usr/local/bin/ci_utils.sh ]]; then
    #     source ci_utils.sh
    # elif [[ -f "${WORKSPACE}/test-infra/scripts/ci_utils.sh" ]]; then
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

    setup_and_print_env_vars

    # Trap all bash commands & print to screen. Like using set -v but allows printing in color
    trap 'printf "%s+ %s%s\n" "${color_cyan}" "$BASH_COMMAND" "${color_normal}" >&2' DEBUG

    # Run script with the 'build' param to build the image, include additional version param (eg 'all', 'v0.5.0', 'dev'). Defaults to 'latest'
    if [[ "$1" == 'build' ]]; then
        build_images "${2:-latest}"
    # Run script with the 'test' param to execute the full pipeline locally, builds specified version
    elif [[ "$1" == 'test' ]]; then
        build_images "${2:-dev}"
        save_images "${2:-dev}"
        test_built_images "${2:-dev}"
        push_all_versions "${2:-dev}"
    # Run script with the 'ci' param to execute a fully mocked CircleCI pipeline, running in docker
    elif [[ "$1" == 'ci' ]]; then
        setup_build_environment
        ci_test_job 'docker.io/anchore/test-infra:latest' 'build_images'
        ci_test_job 'docker.io/anchore/test-infra:latest' 'save_images'
        ci_test_job 'docker.io/anchore/test-infra:latest' 'test_built_images'
        ci_test_job 'docker.io/anchore/test-infra:latest' 'push_all_versions'
    else
        export SKIP_FINAL_CLEANUP=true
        # If first param is a valid function name, execute the function & pass all following params to function
        if declare -f "$1" > /dev/null; then
            "$@"
        else
            display_usage >&2
            printf "%sERROR - %s is not a valid function name %s\n" "${color_red}" "$1" "${color_normal}" >&2
            exit 1
        fi
    fi
}

# The cleanup() function that runs whenever the script exits
cleanup() {
    ret="$?"
    set +euo pipefail
    if [[ "${ret}" -eq 0 ]]; then
        set +o functrace
    fi
    if [[ "${SKIP_FINAL_CLEANUP}" == false ]]; then
        deactivate 2> /dev/null
        docker-compose down --volumes 2> /dev/null
        if [[ "${DOCKER_RUN_IDS[@]}" -ne 0 ]]; then
            for i in "${DOCKER_RUN_IDS[@]}"; do
                docker kill "$i" 2> /dev/null
                docker rm "$i" 2> /dev/null
            done
        fi
        popd &> /dev/null
        if [[ "${WORKING_DIRECTORY}" =~ 'tempci' ]]; then
            rm -rf $(dirname "${WORKING_DIRECTORY}")
        fi
    else
        echo "Workspace dir: ${WORKSPACE}"
        echo "Working Dir: ${WORKING_DIRECTORY}"
    fi
    popd &> /dev/null
    exit "${ret}"
}


#################################################################
###   FUNCTIONS CALLED DIRECTLY BY CIRCLECI - RUNTIME ORDER   ###
#################################################################

build_images() {
    local build_version="$1"
    setup_build_environment

    if [[ "${SLIM_BUILD}" == 'true' ]]; then
        local feed_sync_opts="--slim"
    fi

    if [[ "${build_version}" == 'all' ]]; then
        for version in "${BUILD_VERSIONS[@]}"; do
            compose_up_anchore_engine "${version}"
            if ! scripts/feed_sync_wait.py ${feed_sync_opts} 120 60; then
                compose_down_anchore_engine
                export COMPOSE_DB_IMAGE="postgres:9"
                compose_up_anchore_engine "${version}"
                scripts/feed_sync_wait.py ${feed_sync_opts} 300 60
            fi
            compose_down_anchore_engine
            docker build -t "${IMAGE_REPO}:dev" .
            docker tag "${IMAGE_REPO}:dev" "${IMAGE_REPO}:dev-${version}"
        done 
    else
        compose_up_anchore_engine "${build_version}"
        if [[ "${FORCE_FRESH_SYNC}" == 'true' ]]; then
            scripts/feed_sync_wait.py ${feed_sync_opts} 300 60
        else
            if ! scripts/feed_sync_wait.py ${feed_sync_opts} 120 60; then
                compose_down_anchore_engine
                export COMPOSE_DB_IMAGE="postgres:9"
                compose_up_anchore_engine "${build_version}"
                scripts/feed_sync_wait.py ${feed_sync_opts} 300 60
            fi
        fi
        compose_down_anchore_engine
        docker build -t "${IMAGE_REPO}:dev" .
        docker tag "${IMAGE_REPO}:dev" "${IMAGE_REPO}:dev-${build_version}"
    fi
}

save_images() {
    local build_version="$1"
    setup_build_environment
    if [[ "${build_version}" == 'all' ]]; then
        for version in "${BUILD_VERSIONS[@]}"; do
            save_image "${version}"
        done
    else
        save_image "${build_version}"
    fi
}

test_built_images() {
    local build_version="$1"
    setup_build_environment
    if [[ "${build_version}" == 'all' ]]; then
        for version in "${BUILD_VERSIONS[@]}"; do
            load_image "${version}"
            export COMPOSE_DB_IMAGE=$(eval echo "${IMAGE_REPO}:dev-${version}")
            compose_up_anchore_engine "${version}"
            run_tests
            compose_down_anchore_engine
        done
    else
        load_image "${build_version}"
        export COMPOSE_DB_IMAGE=$(eval echo "${IMAGE_REPO}:dev-${build_version}")
        compose_up_anchore_engine "${build_version}"
        run_tests
        compose_down_anchore_engine
    fi
}

push_all_versions() {
    local build_version="$1"
    setup_build_environment
    if [[ "${build_version}" == 'all' ]]; then
        for version in "${BUILD_VERSIONS[@]}"; do
            load_image "${version}"
            push_dockerhub "${version}"
        done
    else
        load_image "${build_version}"
        push_dockerhub "${build_version}"
    fi
}


###########################################################
###   PROJECT SPECIFIC FUNCTIONS - ALPHABETICAL ORDER   ###
###########################################################

compose_down_anchore_engine() {
    docker-compose down --volumes
    unset COMPOSE_DB_IMAGE COMPOSE_ENGINE_IMAGE
    # For machine image on circleci no need to ssh to remote-docker
    rm -rf "${WORKSPACE}/aevolume" || sudo rm -rf "${WORKSPACE}/aevolume"
    # If running on circleCI kill forwarded socket to remote-docker
    # if [[ "${CI}" == true ]]; then
    #     ssh -S anchore -O exit remote-docker
    #     ssh remote-docker "sudo rm -rf ${WORKSPACE}/aevolume"
    # else
    #     rm -rf "${WORKSPACE}/aevolume"
    # fi
}

compose_up_anchore_engine() {
    local anchore_version="$1"
    # set default values using := notation if COMPOSE vars aren't already set
    export COMPOSE_ENGINE_IMAGE=${COMPOSE_ENGINE_IMAGE:=$(eval echo "docker.io/anchore/anchore-engine:${anchore_version}")}

    # If $COMPOSE_DB_IMAGE is not set, figure out what image to use
    if [[ -z "${COMPOSE_DB_IMAGE}" ]]; then
        if [[ "${FORCE_FRESH_SYNC}" == 'true' ]]; then
            export COMPOSE_DB_IMAGE="docker.io/postgres:9"
        # If the image/tag exists on DockerHub & $COMPOSE_DB_IMAGE is not set - build new image using DB from existing image
        elif docker pull "docker.io/anchore/engine-db-preload:${anchore_version}" &> /dev/null; then
            export COMPOSE_DB_IMAGE="docker.io/anchore/engine-db-preload:${anchore_version}"
        else
            export COMPOSE_DB_IMAGE="docker.io/anchore/engine-db-preload:latest"
        fi
    fi
    if ! docker pull "${COMPOSE_DB_IMAGE}" &> /dev/null && ! docker inspect "${COMPOSE_DB_IMAGE}" &> /dev/null; then
        export COMPOSE_DB_IMAGE="docker.io/postgres:9"
    fi
    echo "COMPOSE_ENGINE_IMAGE=${COMPOSE_ENGINE_IMAGE}"
    echo "COMPOSE_DB_IMAGE=${COMPOSE_DB_IMAGE}"
    ##### When running on machine runner in circleci, no need for ssh remote-docker ####
    mkdir -p "${WORKSPACE}/aevolume/db" "${WORKSPACE}/aevolume/config"
    cp -f config/config.yaml "${WORKSPACE}/aevolume/config/config.yaml"
    if [[ "${SLIM_BUILD}" == "true" ]]; then
        sed -i 's/nvd: True/nvd: False/g' "${WORKSPACE}/aevolume/config/config.yaml"
    fi
    # If CircleCI build, create files/dirs on remote-docker
    # if [[ "$CI" == true ]]; then
    #     ssh remote-docker "mkdir -p ${WORKSPACE}/aevolume/db ${WORKSPACE}/aevolume/config"
    #     scp config/config.yaml remote-docker:"${WORKSPACE}/aevolume/config/config.yaml"
    #     if [[ "$SLIM_BUILD" == "true" ]]; then
    #         ssh remote-docker "sed -i 's/nvd: True/nvd: False/g' ${WORKSPACE}/aevolume/config/config.yaml"
    #     fi
    # else
    #     mkdir -p "${WORKSPACE}/aevolume/db" "${WORKSPACE}/aevolume/config"
    #     cp -f config/config.yaml "${WORKSPACE}/aevolume/config/config.yaml"
    #     if [[ "${SLIM_BUILD}" == "true" ]]; then
    #         sed -i 's/nvd: True/nvd: False/g' "${WORKSPACE}/aevolume/config/config.yaml"
    #     fi
    # fi
    docker-compose up -d
    # If job is running in circleci forward remote-docker:8228 to localhost:8228
    # if [[ "${CI}" == true ]]; then
    #     ssh -MS anchore -fN4 -L 8228:localhost:8228 remote-docker
    # fi
}

install_dependencies() {
    mkdir -p "${WORKSPACE}/aevolume/db" "${WORKSPACE}/aevolume/config"
    cp -f ${WORKING_DIRECTORY}/config/config.yaml "${WORKSPACE}/aevolume/config/config.yaml"
    # Install dependencies to system on CircleCI & virtualenv locally
    if [[ "${CI}" == true ]]; then
        pip install --upgrade pip
        pip install --upgrade docker-compose
        pip install --upgrade anchorecli
    else
        virtualenv .venv
        source .venv/bin/activate
        pip install --upgrade pip
        pip install --upgrade docker-compose
        pip install --upgrade anchorecli
    fi
}

run_tests() {
    anchore-cli --u admin --p foobar --url http://localhost:8228/v1 system wait --feedsready "vulnerabilities"
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


########################################################
###   COMMON HELPER FUNCTIONS - ALPHABETICAL ORDER   ###
########################################################

ci_test_job() {
    local ci_image=$1
    local ci_function=$2
    local docker_name="${RANDOM:-TEMP}-ci-test"
    docker run --net host -it --name "${docker_name}" -v $(dirname "${WORKING_DIRECTORY}"):$(dirname "${WORKING_DIRECTORY}") -v /var/run/docker.sock:/var/run/docker.sock "${ci_image}" /bin/sh -c "\
        cd ${WORKING_DIRECTORY} && \
        cp ${WORKING_DIRECTORY}/scripts/build.sh $(dirname "${WORKING_DIRECTORY}")/build.sh && \
        export WORKING_DIRECTORY=${WORKING_DIRECTORY} && \
        sudo -E bash $(dirname "${WORKING_DIRECTORY}")/build.sh ${ci_function} \
    "
    local docker_id=$(docker inspect ${docker_name} | jq '.[].Id')
    docker kill "${docker_id}" && docker rm "${docker_id}"
    DOCKER_RUN_IDS+=("$docker_id")
}

load_image() {
    local anchore_version="$1"
    docker load -i "${WORKSPACE}/caches/${IMAGE_REPO##*/}-${anchore_version}-dev.tar"
}

push_dockerhub() {
    local anchore_version="$1"
    if [[ "${CI}" == true ]]; then
        echo "${DOCKER_PASS}" | docker login -u "${DOCKER_USER}" --password-stdin
    fi
    if [[ "${GIT_BRANCH}" == 'master' || -n "${CIRCLE_TAG}" ]] && [[ "${CI}" == true ]] && [[ ! "${anchore_version}" == 'dev' ]]; then
        docker tag "${IMAGE_REPO}:dev-${anchore_version}" "${IMAGE_REPO}:${anchore_version}"
        echo "Pushing to DockerHub - ${IMAGE_REPO}:${anchore_version}"
        docker push "${IMAGE_REPO}:${anchore_version}"
        if [[ "${anchore_version}" == "${LATEST_VERSION}" ]]; then
            docker tag "${IMAGE_REPO}:dev-${anchore_version}" "${IMAGE_REPO}:latest"
            echo "Pushing to DockerHub - ${IMAGE_REPO}:latest"
            docker push "${IMAGE_REPO}:latest"
        fi
    else
        docker tag "${IMAGE_REPO}:dev-${anchore_version}" "anchore/private_testing:${IMAGE_REPO##*/}-${anchore_version}"
        echo "Pushing to DockerHub - anchore/private_testing:${IMAGE_REPO##*/}-${anchore_version}"
        if [[ "$CI" == 'false' ]]; then
            sleep 10
        fi
        docker push "anchore/private_testing:${IMAGE_REPO##*/}-${anchore_version}"
    fi
}

save_image() {
    local anchore_version="$1"
    mkdir -p "${WORKSPACE}/caches"
    docker save -o "${WORKSPACE}/caches/${IMAGE_REPO##*/}-${anchore_version}-dev.tar" "${IMAGE_REPO}:dev-${anchore_version}"
}

setup_and_print_env_vars() {
    # Export & print all project env vars to the screen
    echo "${color_yellow}"
    printf "%s\n\n" "- ENVIRONMENT VARIABLES SET -"
    echo "BUILD_VERSIONS=${BUILD_VERSIONS[@]}"
    printf "%s\n" "LATEST_VERSION=${LATEST_VERSION}"
    for var in ${PROJECT_VARS[@]}; do
        export "${var}"
        printf "%s" "${color_yellow}"
        printf "%s\n" "${var}"
    done
    echo "${color_normal}"
    # If running tests manually, sleep for a few seconds to give time to visually double check that ENV is setup correctly
    if [[ "${CI}" == false ]]; then
        sleep 5
    fi
    # Setup a variable for docker image cleanup at end of script
    declare -a DOCKER_RUN_IDS
    export DOCKER_RUN_IDS
}

setup_build_environment() {
    # Copy source code to $WORKING_DIRECTORY for mounting to docker volume as working dir
    if [[ ! -d "${WORKING_DIRECTORY}" ]]; then
        mkdir -p "${WORKING_DIRECTORY}"
        cp -a . "${WORKING_DIRECTORY}"
    fi
    # Setup python3 for machine runner
    if [[ "${CI}" == true ]]; then
        if [[ ! $(pyenv versions) =~ 3.6.3 ]]; then
            pyenv install 3.6.3
        fi
        pyenv global 3.6.3
    fi
    mkdir -p "${WORKSPACE}/caches"
    pushd "${WORKING_DIRECTORY}"
    install_dependencies || true
}

main "$@"
