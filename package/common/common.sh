set -o pipefail
if [ "$RANCHER_DEBUG" == "true" ]; then set -x; fi

err() {
    echo -e $@ 1>&2
}

usage() {
    err "Usage: "
    err "\t$0 create <json params>"
    err "\t$0 delete <json params>"
    err "\t$0 attach <json params>"
    err "\t$0 detach <device>"
    err "\t$0 mount <mount dir> <device> <json params>"
    err "\t$0 unmount <mount dir> <json params>"
    err "\t$0 init"
    exit 1
}

main()
{

    case $1 in
        init)
            "$@"
            ;;
        create|delete|attach)
            parse "$2"
            "$@"
            ;;
        detach)
            DEVICE="$2"
            "$@"
            ;;
        mount)
            MNT_DEST="$2"
            DEVICE="$3"
            parse "$4"
            shift 1
            mountdest "$@"
            ;;
        unmount)
            MNT_DEST="$2"
            parse "$3"
            "$@"
            ;;
        *)
            usage
            ;;
    esac
}

declare -A OPTS
parse()
{
    mapfile -t < <(echo "$1" | jq -r 'to_entries | map([.key, .value]) | .[]' | jq '.[]' | sed 's!^"\(.*\)"$!\1!g')
    for ((i=0;i < ${#MAPFILE[@]} ; i+=2)) do
        OPTS[${MAPFILE[$i]}]=${MAPFILE[$((i+1))]}
    done
}

print_options()
{
    for ((i=1; i < $#; i+=2)) do
        j=$((i+1))
        jq -n --arg k ${!i} --arg v ${!j} '{"key": $k, "value": $v}'
    done | jq -c -s '{"status": "Success", "options": from_entries}'
}

print_device()
{
    echo -n "$@" | jq -R -c -s '{"status": "Success", "device": .}'
}

print_not_supported() {
    echo -n "$@" | jq -R -c -s '{"status": "Not supported", "message": .}'
}

exit_not_supported() {
    print_not_supported "$@"
    exit 0
}

print_success()
{
    echo -n "$@" | jq -R -c -s '{"status": "Success", "message": .}'
}

exit_success() {
    print_success "$@"
    exit 0
}

print_error()
{
    echo -n "$@" | jq -R -c -s '{"status": "Failure", "message": .}'
    exit 1
}

ismounted() {
    local mountPoint=$1
    local mountP=`findmnt -n ${mountPoint} 2>/dev/null | cut -d' ' -f1`
    if [ "${mountP}" == "${mountPoint}" ]; then
        echo "1"
    else
        echo "0"
    fi
}

unset_aws_credentials_env() {
    if [ -z "${AWS_ACCESS_KEY_ID}" ] || [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
        unset AWS_ACCESS_KEY_ID
        unset AWS_SECRET_ACCESS_KEY
    fi
}

get_host_process_pid() {
    PARENT_PID=$(ps --no-header --pid $$ -o ppid)
    TARGET_PID=$(ps --no-header --pid ${PARENT_PID} -o ppid)
}

init_nfs_client_service() {
    # using host network context to start rpcbind and rpc.statd inside the container process.
    # this requires mapping host pid namespace to this containers when container starts.
    # here parent is the storage --driver rancher-nfs process, the script process is launched
    # on demand of each create/delete etc calls, so host process pid is 2 hops away
    get_host_process_pid
    if [ ! "$(pidof rpcbind)" ] && [ ! "$(pidof rpc.statd)" ]; then
        nsenter -t $TARGET_PID -n rpcbind >& /dev/null
        nsenter -t $TARGET_PID -n rpc.statd >& /dev/null
    fi
}

must_exist() {
    local name="$1"
    local var="$2"
    if [ -z "$var" ]; then
        print_error "Failed: No variable $name found"
    fi
}

mount_nfs() {
    local server=$1
    local dir=$2
    local dest=$3
    local opts=$4
    local error

    get_host_process_pid

    MOUNT_CMD="mount -t nfs"
    if [ ! -z "$opts" ]; then
        MOUNT_CMD="$MOUNT_CMD -o $opts"
    fi

    if [ "$(ismounted $dest)" == 0 ]; then
        mkdir -p $dest

        error=`nsenter -t ${TARGET_PID} -n -m $MOUNT_CMD "$server":"$dir" "$dest" 2>&1`
        if [ $? -ne 0 ]; then
            print_error "Mount failed: $error"
        fi
    fi
}

unmount_dir() {
    local dest=$1
    if [ "$(ismounted $dest)" == 1 ]; then
        error=`umount $dest 2>&1`
        if [ $? -ne 0 ]; then
            print_error "Umount failed: $error"
        elif [ ! "$(ls -A $dest)" ]; then
            rmdir $dest
        fi
    fi
}
