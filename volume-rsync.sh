#!/bin/bash
set -euo pipefail

# sshpass is needed if docker is used in any scenario
# answer question with direct uid:gid answer or piping on stdin ('echo x:y | volume-rsync.sh ...')

function usage() {
  echo "usage: $0 [<SRC-USER>@]<SRC-HOST>:<SRC-PATH> [:<SRC-PATH> [..]] [<DEST-USER>@]<DEST-HOST>:<DEST-PATH>"
  echo "       $0 docker://[<SRC-USER>@]<SRC-HOST>:<VOLUME-ID>[/] [:<VOLUME-ID>[/] [..]] [<DEST-USER>@]<DEST-HOST>:<DEST-PATH>"
  echo "       $0 [<SRC-USER>@]<SRC-HOST>:<SRC-PATH> [:<SRC-PATH> [..]] docker://[<DEST-USER>@]<DEST-HOST>:<VOLUME-ID>"
  echo "       $0 docker://[<SRC-USER>@]<SRC-HOST>:<VOLUME-ID>[/] [:<VOLUME-ID>[/] [..]] docker://[<DEST-USER>@]<DEST-HOST>:<VOLUME-ID>"
}

if [ $# -lt 2 ]
then
  echo "Not enough ($#) parameter"
  usage
  exit 1
fi

echo
echo -n "Check SSH agent is running... "
if ! ps -p "$SSH_AGENT_PID" >/dev/null
then
  echo "SSH agent not configured"
  echo
  exit 2
fi
echo OK
echo
echo "List of SSH keys:"
ssh-add -l
echo

# https://unix.stackexchange.com/questions/230673/how-to-generate-a-random-string
DOCKER_SSH_USER=$(tr -dc A-Za-z </dev/urandom | head -c 10; echo)
DOCKER_SSH_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 15; echo)

read -r -d '' DOCKERFILE_CONTENT << EOF
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND noninteractive
ENV LANG C

RUN apt -qq update
RUN apt install -y -qq apt-utils openssh-server openssh-client rsync sshpass && apt clean
RUN useradd -m -s /bin/bash -U "${DOCKER_SSH_USER}"
RUN echo "${DOCKER_SSH_USER}:${DOCKER_SSH_PASSWORD}" | chpasswd
RUN echo "root:${DOCKER_SSH_PASSWORD}" | chpasswd
RUN echo "${DOCKER_SSH_USER} ALL=NOPASSWD:/usr/bin/rsync" >> /etc/sudoers
RUN sed -i '"'"'s/^#PermitRootLogin prohibit-password$/PermitRootLogin yes/'"'"' /etc/ssh/sshd_config
CMD ["service", "ssh", "start", "-D"]
EOF

DEFAULT_USER=${DOCKER_SSH_USER}
CT_LOGIN_PASSWORD="${DOCKER_SSH_PASSWORD}"
DEFAULT_NEW_USER=newuser
DEFAULT_NEW_GROUP=newgroup

function get_ct_user() {
  SSH_CONN=$1
  SSH_CT_ID=$2
  TARGET_UID=$3
  TARGET_GID=$4
  
  TARGET_USER="$DEFAULT_NEW_USER"
  TARGET_GROUP="$DEFAULT_NEW_GROUP"
  
  if ((TARGET_UID>-1))
  then
    # New user
    if ((TARGET_GID<=-1))
    then
      # Got no group id, reuse previous
      TARGET_GID=$(ssh -A "$SSH_CONN" docker exec "$SSH_CT_ID" id -g)
    fi
    ssh -A "$SSH_CONN" docker exec "$SSH_CT_ID" groupadd -g "$TARGET_GID" "$TARGET_GROUP" || echo "Group exists, command exited with $?" >&2
    
    USER_EXISTS=$(ssh -A "$SSH_CONN" docker exec -i "$SSH_CT_ID" bash <<< "useradd -m  -s /bin/bash  -u '$TARGET_UID' -g '$TARGET_GID' '$TARGET_USER' >&2 && echo 0 || echo 1")
    
    if [[ "$USER_EXISTS" == "1" ]]
    then
      TARGET_USER=$(ssh -A "$SSH_CONN" docker exec "$SSH_CT_ID" id -nu "$TARGET_UID")
      echo "User exists, command exited with $?; switching to user $TARGET_USER" >&2
    fi
    
    ssh -A "$SSH_CONN" docker exec -i "$SSH_CT_ID" bash <<< "echo '$TARGET_USER:$CT_LOGIN_PASSWORD' | chpasswd" >&2
    ssh -A "$SSH_CONN" docker exec -i "$SSH_CT_ID" bash <<< "usermod -U '$TARGET_USER'" >&2
  elif ((TARGET_GID>-1))
  then
    TARGET_USER="$DEFAULT_USER"
    ssh -A "$SSH_CONN" docker exec "$SSH_CT_ID" groupadd -g "$TARGET_GID" "$TARGET_GROUP" || echo "Group exists, command exited with $?" >&2
    ssh -A "$SSH_CONN" docker exec "$SSH_CT_ID" usermod -aG "$TARGET_GID" "$TARGET_USER" >&2
  fi
  echo "$TARGET_USER"
}

DEST_PARAM="${@: -1}"

SRC_IS_DOCKER=$([[ "$1" == docker://* ]] && echo 1 || echo 0)
DEST_IS_DOCKER=$([[ "$DEST_PARAM" == docker://* ]] && echo 1 || echo 0)

#source_UID=-1
#source_GID=-1
#if [[ "$SRC_IS_DOCKER" -eq 1 ]]
#then
#  read -p "Run source container with arbitrary UID:GID? [y/N]: "
#  if [[ "$REPLY" == 'Y' ]] || [[ "$REPLY" == 'y' ]]
#  then
#    echo
#    read -p "Source user UID [Not set]: "
#    [[ "$REPLY" =~ -?[0-9]+ ]] && source_UID="$REPLY" || echo "Not a number"
#    read -p "Source user GID [Not set]: "
#    [[ "$REPLY" =~ -?[0-9]+ ]] && source_GID="$REPLY" || echo "Not a number"
#  fi
#  echo
#fi

destination_UID=-1
destination_GID=-1
if [[ "$DEST_IS_DOCKER" -eq 1 ]]
then
  read -p "Run destination container with arbitrary UID:GID? [y/N/uid:/uid:gid]: "
  if [[ "$REPLY" == 'Y' ]] || [[ "$REPLY" == 'y' ]]
  then
    echo
    read -p "Source user UID [Not set]: "
    [[ "$REPLY" =~ -?[0-9]+ ]] && destination_UID="$REPLY" || echo "Not a number"
    read -p "Source user GID [Not set]: "
    [[ "$REPLY" =~ -?[0-9]+ ]] && destination_GID="$REPLY" || echo "Not a number"
    echo
  elif [[ "$REPLY" =~ -?[0-9]+: ]] || [[ "$REPLY" =~ -?[0-9]+:[0-9]+ ]]
  then
    destination_UID=$(echo "$REPLY" | cut -f '1' -d ':')
    destination_GID=$(echo "$REPLY" | cut -f '2' -d ':')
  fi
  echo
fi

#i=0
#for param in $@
#do
#  case $param in
#    :* 
#  esac
#done

SRC_CONN=$(echo "${1#*docker://}" | cut -d ':' -f 1)
DST_CONN=$(echo "${DEST_PARAM#*docker://}" | cut -d ':' -f 1)
DST_HOST=$(echo "$DST_CONN" | cut -d '@' -f 2)

DST_PATH=$(echo "${DEST_PARAM#*docker://}" | cut -d ':' -f 2)

echo
echo "Source: $SRC_CONN"
echo "Destination: $DST_CONN"
echo "Destination path: $DST_PATH"
echo

# Collect source paths or volume ids
src_paths=( $(echo "${1#*docker://}" | cut -d ':' -f 2) )

for src_file in ${@:2:$#-2}
do
  src_paths+=( $(echo $src_file | cut -d ':' -f 2) )
done

echo "Parameters: ${src_paths[*]}"
echo

if [[ "$DEST_IS_DOCKER" -eq 1 ]]
then
  SSH_DEST_PORT=11221
  
  function ssh_ct_delete() {
    echo "Terminate ssh server on ${DST_CONN}"
    ssh -A "${DST_CONN}" bash << EOF
      docker stop "$SERVER_CT" && docker rm "$SERVER_CT"
EOF
  }
  
  escaped_dest_volid=$(echo "$DST_PATH" | tr -cd "[:print:]")
  
  # Build image
  ssh "${DST_CONN}" docker build -t custom-openssh-server - <<< "$DOCKERFILE_CONTENT"
  
  # Use ssh keys instead!
  echo "Starting ssh server container on ${DST_CONN}" # -e SSH_AUTH_SOCK
  SERVER_CT=$(ssh -A "${DST_CONN}" docker run -d -p "${SSH_DEST_PORT}:22" -e TZ=Europe/Budapest -v "$DST_PATH:/mnt/$escaped_dest_volid" custom-openssh-server:latest)
  trap ssh_ct_delete EXIT
  echo "Docker run command exited, server container ID / error status: $SERVER_CT"
  
  RSYNC_DST_PATH="/mnt/$escaped_dest_volid"
  
  RSYNC_DST_USER=$(get_ct_user "$DST_CONN" "$SERVER_CT" "$destination_UID" "$destination_GID")
  
  RSYNC_DST_CONN="${RSYNC_DST_USER}@${DST_HOST}"
  
  if [[ "$SRC_IS_DOCKER" -ne 1 ]]
  then
    for binary in sshpass
    do
      if ! ssh "${SRC_CONN}" "which '$binary'"
      then
        echo "ERROR: $binary not found on source. Abort."
        exit 4
      fi
    done
  fi
  RSYNC_DST_ENV="sshpass -p '$CT_LOGIN_PASSWORD' ssh -o StrictHostKeyChecking=no -A -p '${SSH_DEST_PORT}'"
else
  SSH_DEST_PORT=22
  RSYNC_DST_CONN="$DST_CONN"
  RSYNC_DST_ENV=ssh
  RSYNC_DST_PATH="$DST_PATH"
  
  if [[ "$SRC_IS_DOCKER" -eq 1 ]]
  then
    # No previous knowledge about destination
    RSYNC_DST_ENV="ssh -o StrictHostKeyChecking=no"
  fi
fi

if [[ "$SRC_IS_DOCKER" -eq 1 ]]
then
  ssh "${SRC_CONN}" docker build -t custom-openssh-server - <<< "$DOCKERFILE_CONTENT"
  
  SOURCE_DIRS=()
  SOURCE_VOLUMES=()
  for volume in ${src_paths[*]}
  do
    escaped_volid=$(echo "$volume" | tr -cd "[:print:]")
    SOURCE_VOLUMES+=("-v '${volume%/}:/mnt/${escaped_volid}'")
    
    #trailing_slash=$([[ "$volume" == */ ]] && echo '/' || true)
    #SOURCE_DIRS+=("/mnt/${escaped_volid}${trailing_slash}")
    SOURCE_DIRS+=("/mnt/${escaped_volid}")
  done
  
  echo "SOURCE_DIRS ${SOURCE_DIRS}"
  echo
  
  # Use ssh keys instead!
  # Prepare container
  echo "Starting ssh source container on ${SRC_CONN}"
  SOURCE_CT=$(ssh -A "${SRC_CONN}" docker run -d --rm ${SOURCE_VOLUMES[@]} -e SSH_AUTH_SOCK -v "/tmp:/tmp" -e TZ=Europe/Budapest custom-openssh-server:latest)
  echo "Docker run command exited, server container ID / error status: $SOURCE_CT"
  
  SRC_WRAPPER="docker exec -i -e SSH_AUTH_SOCK '$SOURCE_CT'"
else
  SRC_WRAPPER=
  
  SOURCE_DIRS=( ${src_paths[*]} )
fi

echo
echo "Preparing files..."
echo "Source file list: ${SOURCE_DIRS[@]}"
echo "Destination path: ${DST_PATH}"
echo
#echo "Other variables:"
#( set -o posix ; set )
#echo

ssh -A "${SRC_CONN}" $SRC_WRAPPER bash << EOF
  echo "Spawning SSH session on ${SRC_CONN}"
  ssh-keygen -f ~/.ssh/known_hosts -R "[${DST_HOST}]:${SSH_DEST_PORT}"
  
  #while ! sshpass -p '${DOCKER_SSH_PASSWORD}' ssh -o StrictHostKeyChecking=no -p "${SSH_DEST_PORT}" ${DOCKER_SSH_USER}@${DST_HOST} sleep 1; do
  #  echo "Waiting for SSH server to become available..."
  #  sleep 3
  #done
  
  echo
  echo "SSH keys:"
  ssh-add -l
  echo
  
  echo
  echo "Copying files..."
  echo
  echo "Contents of /tmp"
  ls -al /mnt
  
  #if [[ "$DEST_IS_DOCKER" -eq 1 ]]
  #then
    rsync -v -e "$RSYNC_DST_ENV" -aHAX --delete ${SOURCE_DIRS[*]} "${RSYNC_DST_CONN}:${RSYNC_DST_PATH}"
  #else
  #  rsync -vvv --rsync-path="sudo rsync" -uar ${SOURCE_DIRS[*]} ${RSYNC_DST_CONN}:${DST_PATH}
  #fi
  
  if [[ "$SRC_IS_DOCKER" -eq 1 ]]
  then
    shutdown -h now
  fi
EOF

# Best-effort source-container removal (proper method would be using the trap function)
if [ -n "${SOURCE_CT+set}" ]
then
  echo "Remove source container"
  ssh -A "${SRC_CONN}" "docker stop '$SOURCE_CT'"
  ssh -A "${SRC_CONN}" "docker rm '$SOURCE_CT'"
fi

