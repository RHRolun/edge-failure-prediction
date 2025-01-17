#!/bin/sh

# setup app parameters
APP_NAME="${APP_NAME:-predict}"
NAMESPACE="${NAMESPACE:-edge-failure-prediction}"

# setup database parameters
DB_APP_NAME="${DB_APP_NAME:-predict-db}"
DB_HOSTNAME="${DB_HOSTNAME:-${DB_APP_NAME}.${NAMESPACE}.svc.cluster.local}"
DB_DATABASE="${DB_DATABASE:-predict-db}"
DB_USERNAME="${DB_USERNAME:-predict-db}"
DB_PASSWORD="${DB_PASSWORD:-failureislame}"
DB_PORT="${DB_PORT:-5432}"
DB_DATA_PATH="${DB_DATA_PATH:-/var/lib/pgsql/data}"
DB_TABLE="${DB_TABLE:-waterpump}"

# setup kafka parameters
KAFKA_HOSTNAME="${KAFKA_HOSTNAME:-kafka-cluster-kafka-bootstrap.edge-kafka.svc.cluster.local}"

# other parameters
GIT_URL=https://github.com/RHRolun/edge-failure-prediction.git
GIT_BRANCH="main"
DB_PATH=data
APP_LABEL="app.kubernetes.io/part-of=${APP_NAME}"
CONTEXT_DIR="src"


ocp_init(){
  oc whoami || exit 0

  echo "NAMESPACE: ${NAMESPACE}"
  echo "Press Ctrl + C if this is not correct"
  sleep 5

  # update openshift context to project
  oc project ${NAMESPACE} || oc new-project ${NAMESPACE}
}

is_sourced() {
  if [ -n "$ZSH_VERSION" ]; then
      case $ZSH_EVAL_CONTEXT in *:file:*) return 0;; esac
  else  # Add additional POSIX-compatible shell names here, if needed.
      case ${0##*/} in dash|-dash|bash|-bash|ksh|-ksh|sh|-sh) return 0;; esac
  fi
  return 1  # NOT sourced.
}

ocp_setup_db_instance(){
  # setup postgres
  oc new-app \
    --name ${DB_APP_NAME} \
    -n ${NAMESPACE} \
    -l ${APP_LABEL} \
    --image-stream=postgresql:12-el8

  # setup postgres env
  oc set env \
    deployment/${DB_APP_NAME} \
    -n ${NAMESPACE} \
    -e POSTGRESQL_DATABASE=${DB_DATABASE} \
    -e POSTGRESQL_USER=${DB_USERNAME} \
    -e POSTGRESQL_PASSWORD=${DB_PASSWORD}

  # make db persistent
  oc set volume \
    deployment/${DB_APP_NAME} \
    --add \
    --name=${DB_APP_NAME} \
    --mount-path=${DB_DATA_PATH} \
    -t pvc \
    --claim-size=1G \
    --claim-name=${DB_APP_NAME} \
    --overwrite
}

ocp_setup_db_data(){
  # SQL_EXISTS=$(printf '\dt "%s"' "${DB_TABLE}")
  # psql -d "${DB_DATABASE}" -c "${SQL_EXISTS}"

  until oc -n "${NAMESPACE}" exec deployment/"${DB_APP_NAME}" -- psql --version >/dev/null 2>&1
  do
    sleep 10
  done

  POD=$(oc -n "${NAMESPACE}" get pod -l deployment="${DB_APP_NAME}" -o name | sed 's#pod/##')

  echo "copying data to database container..."
  echo "POD: ${POD}"

  oc -n "${NAMESPACE}" cp "${DB_PATH}"/db.sql "${POD}":/tmp
  oc -n "${NAMESPACE}" cp "${DB_PATH}"/sensor.csv.zip "${POD}":/tmp

cat << COMMAND | oc -n "${NAMESPACE}" exec "${POD}" -- sh -c "$(cat -)"
# you can run the following w/ oc rsh
# this hack just saves you time

cd /tmp
unzip -o sensor.csv.zip

echo 'GRANT ALL ON TABLE waterpump TO "'"${DB_USERNAME}"'" ;' >> db.sql
psql -d ${DB_DATABASE} -f db.sql

COMMAND
}

ocp_print_db_info(){
  # print db hostname for workshop
  echo "The web app requires a running postgres db to function"
  echo "The following is the hostame is for the database inside OpenShift"
  echo "DB_HOSTNAME: ${DB_HOSTNAME}"
}

ocp_setup_db(){
  [ -n "${NON_INTERACTIVE}" ] && input=yes

  if [ ! -n "$input" ]; then 
    echo "As a participant in a workshop, the expected answer is: No"
    read -r -p "Setup sensor database in OpenShift? [y/N] " input
  fi
  
  case $input in
    [yY][eE][sS]|[yY])
      ocp_setup_db_instance
      ocp_setup_db_data
      ocp_print_db_info
      ;;
    [nN][oO]|[nN])
      echo
      ;;
    *)
      echo
      ;;
  esac
}

ocp_setup_app(){
  # setup prediction app
  oc new-app \
    ${GIT_URL}#${GIT_BRANCH} \
    --name ${APP_NAME} \
    -l ${APP_LABEL} \
    -n ${NAMESPACE} \
    --context-dir ${CONTEXT_DIR}

  # setup database parameters
  oc set env \
    deployment/${APP_NAME} \
    -n ${NAMESPACE} \
    -e DB_HOSTNAME=${DB_HOSTNAME} \
    -e DB_DATABASE=${DB_DATABASE} \
    -e DB_USERNAME=${DB_USERNAME} \
    -e DB_PASSWORD=${DB_PASSWORD}

  oc set env \
    deployment/${APP_NAME} \
    -n ${NAMESPACE} \
    -e KAFKA_HOSTNAME=${KAFKA_HOSTNAME}

  # create route
  oc expose service \
    ${APP_NAME} \
    -n ${NAMESPACE} \
    -l ${APP_LABEL} \
    --overrides='{"spec":{"tls":{"termination":"edge","insecureEdgeTerminationPolicy":"Redirect"}}}'

  # kludge - some versions of oc don't work
  oc patch route \
    ${APP_NAME} \
    -n ${NAMESPACE} \
    --type=merge \
    -p '{"spec":{"tls":{"termination":"edge","insecureEdgeTerminationPolicy":"Redirect"}}}'

  # kludge - fix timeout for app
  oc annotate route \
    ${APP_NAME} \
    -n ${NAMESPACE} \
    haproxy.router.openshift.io/timeout=5m \
    --overwrite
}

container_setup_db_instance(){
  PODMAN_CMD=docker
  which podman && PODMAN_CMD=podman

  # remove old container
  ${PODMAN_CMD} stop "${DB_APP_NAME}"
  sleep 1

  # run db; remove on stop
  # requires login
  # registry.redhat.io/rhel8/postgresql-12:latest
  ${PODMAN_CMD} run \
    --name "${DB_APP_NAME}" \
    -d --rm \
    -p "${DB_PORT}":5432 \
    -v $(pwd):/opt/app-root/src \
    -e POSTGRESQL_DATABASE="${DB_DATABASE}" \
    -e POSTGRESQL_PASSWORD="${DB_PASSWORD}" \
    -e POSTGRESQL_USER="${DB_USERNAME}" \
    quay.io/sclorg/postgresql-12-c8s:latest
  
  # wait for container to start
  sleep 10

  # run db data setup
  ${PODMAN_CMD} exec \
    -it \
    "${DB_APP_NAME}" \
    /bin/bash -c ". scripts/bootstrap.sh; container_setup_db_data"
}

container_setup_db_data(){
  cd ${DB_PATH}

  cp sensor.csv.zip db.sql /tmp

  cd /tmp

  unzip -o sensor.csv.zip

  echo 'GRANT ALL ON TABLE waterpump TO "'"${DB_USERNAME}"'" ;' >> db.sql
  psql -d "${DB_DATABASE}" -f db.sql
}

container_setup_db(){
  container_setup_db_instance

echo "To stop the container and clean up run:
  podman rm predict-db
"
}

main(){
  ocp_init
  ocp_setup_db
  ocp_setup_app
}

is_sourced || main
