#!/bin/bash
set -x
set -e
set -u

DATADIR=$1

if [ ! -d $DATADIR ]; then
	echo $DATADIR does not exist
	exit 1
fi

if [ -z "$DATADIR" ]; then
   echo no data dir specified
   exit 1
fi

CHAINID=32382
SRCHOME=$HOME/src
PRYSMSRC=/home/tristan/offchain/4844/prysm

# do the slow build stuff before computing genesis time
pushd $PRYSMSRC

INTEROP_BIN=$PRYSMSRC/interop-bin
mkdir -p $INTEROP_BIN

bazel build //cmd/prysmctl -c dbg
BAZEL_CTL_CMD=$PRYSMSRC/bazel-bin/cmd/prysmctl/prysmctl_/prysmctl
CTL_CMD=$INTEROP_BIN/prysmctl
cp -f $BAZEL_CTL_CMD $CTL_CMD

bazel build //cmd/beacon-chain -c dbg
BAZEL_BC_CMD=$PRYSMSRC/bazel-bin/cmd/beacon-chain/beacon-chain_/beacon-chain
BC_CMD=$INTEROP_BIN/beacon-chain
cp -f $BAZEL_BC_CMD $BC_CMD

bazel build //cmd/validator -c dbg
BAZEL_V_CMD=$PRYSMSRC/bazel-bin/cmd/validator/validator_/validator
V_CMD=$INTEROP_BIN/validator
cp -f $BAZEL_V_CMD $V_CMD

popd

BLOBUTILSRC=/home/tristan/offchain/4844/blob-utils
BLOBUTILSCMD=$BLOBUTILSRC/blob-utils
pushd $BLOBUTILSRC
go build -o $BLOBUTILSCMD
chmod +x $BLOBUTILSCMD
popd

GETHEXE=/home/tristan/offchain/4844/go-ethereum-upstream/build/bin/geth
SCRIPTDIR=$PWD # assumes this is run from the dir where the script lives

CL_DATADIR_1=$DATADIR/cl-1
CL_DATADIR_2=$DATADIR/cl-2
GETHDATA_1=$DATADIR/el-1
GETHDATA_2=$DATADIR/el-2

LOGDIR=$DATADIR/logs
CL_LOGS_1=$LOGDIR/beacon-node_1.log
VAL_LOGS_1=$LOGDIR/validator_1.log
CL_LOGS_2=$LOGDIR/beacon-node_2.log
GETH_1_LOG=$LOGDIR/geth_1.log
GETH_2_LOG=$LOGDIR/geth_2.log
PID_FILE=$LOGDIR/run-pids
rm $PID_FILE
touch $PID_FILE
echo "pids written to $PID_FILE"

# clean up all the processes on sigint
trap cleanup INT
trap cleanup EXIT
function cleanup() {
	$(cat $PID_FILE | cut -d' ' -f1 | xargs kill $1)
}

function log_pid() {
	SHELL_PID=$1
	PROC_NAME=$2
	OUTER_PID=$(ps -o pid,cmd --ppid=$SHELL_PID | grep 'run-existing.sh' | tail -n1 | awk '{ print $1 }')
	#OUTER_PID=$(ps --ppid=$SHELL_PID | grep 'run.sh' | tail -n1 | cut -d' ' -f1)
	GO_PID=$(ps --ppid=$OUTER_PID | tail -n1 | awk '{ print $1 }')
	echo "$PROC_NAME pid = $GO_PID"
	echo "$GO_PID # $PROC_NAME" >> $PID_FILE
}

echo "all logs and stdout/err for each program redirected to log dir = $LOGDIR"

JWT_PATH=$DATADIR/jwt.secret

GETH_PASSWORD_FILE=$DATADIR/geth_password.txt

pushd $PRYSMSRC

echo "beacon-node 1 logs at $CL_LOGS_1"
setsid $($BC_CMD \
	--datadir=$CL_DATADIR_1 \
	--log-file=$CL_LOGS_1 \
        --min-sync-peers=0 \
        --genesis-state=$DATADIR/genesis.ssz \
        --interop-eth1data-votes \
        --bootstrap-node= \
        --chain-config-file=$DATADIR/config.yml \
        --chain-id=$CHAINID \
        --accept-terms-of-use \
        --jwt-secret=$JWT_PATH \
	--execution-endpoint=http://localhost:8551 \
	--suggested-fee-recipient=0x0000000000000000000000000000000000000000 --verbosity=debug \
	1> $LOGDIR/beacon-1.stdout 2> $LOGDIR/beacon-1.stderr) &
PID_BN1=$!
log_pid $PID_BN1 "beacon node 1"

sleep 10

echo "validator 1 logs at $VAL_LOGS_1"
setsid $($V_CMD \
	--datadir=$CL_DATADIR_1 \
	--log-file=$VAL_LOGS_1 \
        --accept-terms-of-use \
        --interop-num-validators=256 \
        --interop-start-index=0 \
	--chain-config-file=$DATADIR/config.yml \
	1> $LOGDIR/validator-1.stdout 2> $LOGDIR/validator-1.stderr) &
PID_V1=$!
log_pid $PID_V1 "validator 1"

sleep 10

echo "geth logs at $GETH_1_LOG"
setsid $($GETHEXE \
	--log.file=$GETH_1_LOG \
	--http \
	--http.api web3,eth,debug \
        --datadir=$GETHDATA_1 \
        --nodiscover \
        --syncmode=full \
        --allow-insecure-unlock \
        --unlock=0x123463a4b065722e99115d6c222f267d9cabb524 \
        --password=$GETH_PASSWORD_FILE \
	--authrpc.port=8551 \
	--authrpc.jwtsecret=$JWT_PATH \
	console \
	1> $LOGDIR/geth-1.stdout 2> $LOGDIR/geth-1.stderr) &
PID_GETH_1=$!
log_pid $PID_GETH_1 "geth 1"


echo "sleeping until infinity or ctrl+c, whichever comes first"
sleep infinity
