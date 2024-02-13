#!/bin/bash -xe

# Configurable parameters
[ -z "$COMMAND" ] && echo "Need to set COMMAND" && exit 1;

USER_NAME=${USER_NAME:-builder}
REMOTE_WORKSPACE=${REMOTE_WORKSPACE:-/home/${USER_NAME}/workspace/}
INSTANCE_NAME=${INSTANCE_NAME:-docker-remote-builder-$(cat /proc/sys/kernel/random/uuid)}
INSTANCE_MAX_DURATION=${INSTANCE_MAX_DURATION:-3600s}
INSTANCE_ARGS=${INSTANCE_ARGS:---preemptible}
INSTANCE_SPOT_ARGS=${INSTANCE_SPOT_ARGS:---no-restart-on-failure --maintenance-policy=TERMINATE --provisioning-model=SPOT --instance-termination-action=DELETE --max-run-duration=${INSTANCE_MAX_DURATION}}
ZONE=${ZONE:-asia-southeast1-b}
RETRIES=${RETRIES:-10}

# Always delete instance after attempting build
function cleanup {
    gcloud compute instances delete ${INSTANCE_NAME} --quiet
}

# Run command on the instance via ssh
function ssh {
    gcloud compute ssh --ssh-key-file=${SSH_KEY} ${USER_NAME}@${INSTANCE_NAME} -- $1
}

gcloud config set compute/zone ${ZONE}

SSH_KEY=/tmp/builder-key
ssh-keygen -t rsa -N "" -f ${SSH_KEY} -C ${USER_NAME} || true
chmod 400 ${SSH_KEY}*

SSH_KEYS=/tmp/ssh-keys
cat << EOF | perl -pe 'chomp if eof' > ${SSH_KEYS}
${USER_NAME}:$(cat ${SSH_KEY}.pub)
EOF

STARTUP_SCRIPT=/tmp/startup-script
cat << EOF > ${STARTUP_SCRIPT}
#!/bin/bash
apt-get update -y
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  \$(. /etc/os-release && echo "\$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

useradd -m ${USER_NAME}
usermod -aG docker ${USER_NAME}
usermod -aG sudo ${USER_NAME}
mkdir ${REMOTE_WORKSPACE}
chmod 0755 ${REMOTE_WORKSPACE}
chown ${USER_NAME}:${USER_NAME} ${REMOTE_WORKSPACE}
EOF

gcloud beta compute instances create \
    ${INSTANCE_ARGS} ${INSTANCE_SPOT_ARGS} ${INSTANCE_NAME} \
    --metadata block-project-ssh-keys=TRUE \
    --metadata-from-file "ssh-keys=${SSH_KEYS}" \
    --metadata-from-file "startup-script=${STARTUP_SCRIPT}"

trap cleanup EXIT

RETRY_COUNT=1
while [ "$(ssh "stat -c %U:%G ${REMOTE_WORKSPACE} 2> /dev/null")" != "${USER_NAME}:${USER_NAME}" ]; do
    echo "[Try $RETRY_COUNT of $RETRIES] Waiting for instance to start accepting SSH connections..."
    if [ "$RETRY_COUNT" == "$RETRIES" ]; then
        echo "Retry limit reached, giving up!"
        exit 1
    fi
    sleep 10
    RETRY_COUNT=$(($RETRY_COUNT+1))
done

gcloud compute scp --compress --recurse \
    $(pwd)/* ${USER_NAME}@${INSTANCE_NAME}:${REMOTE_WORKSPACE} \
    --ssh-key-file=${SSH_KEY}

ssh "bash -c 'pushd ${REMOTE_WORKSPACE} && ${COMMAND} && popd'"
