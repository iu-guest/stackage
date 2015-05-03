#!/usr/bin/env bash

set -eux

ROOT=$(cd $(dirname $0) ; pwd)
TARGET=$1
TROOT=$ROOT/$(echo $TARGET | cut -d. -f 1)
PLAN_FILE=current-plan.yaml
BUNDLE_FILE=current.bundle

CABAL_DIR=$ROOT/cabal
GHC_DIR=$ROOT/ghc
CURATOR_DIR=$ROOT/stackage-curator
UPDATE_DIR=$ROOT/stackage-update
WORKDIR=$TROOT/work
SSH_DIR=$ROOT/ssh-$(echo $TARGET | cut -d- -f 1)

mkdir -p \
	"$CABAL_DIR" \
	"$GHC_DIR" \
	"$CURATOR_DIR" \
	"$UPDATE_DIR" \
	"$WORKDIR" \
	"$SSH_DIR"

GITCONFIG=$ROOT/gitconfig
cat >$GITCONFIG <<EOF
[user]
	email = michael+stackage-build@fpcomplete.com
	name = Stackage Build host
EOF

cat >$SSH_DIR/known_hosts <<EOF
|1|Qn0iij8BnxGZXbyFSozS9zWkH+Q=|YrKKNp2KHO3/oc4UBFIe1zOvhDc= ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==
|1|RxBEt2ljiEppr019szMIhbY12m0=|0FZ2Oji1LphRbPLLEQhFzTmL69I= ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==
EOF

AUTH_TOKEN=$ROOT/auth-token
HACKAGE_CREDS=$ROOT/hackage-creds

function require_400_file {
    if [ ! -f "$1" ]
    then
        echo File not found: "$1"
        exit 1
    fi

    chmod 400 "$1"
}

require_400_file "$SSH_DIR/id_rsa"
require_400_file "$AUTH_TOKEN"
require_400_file "$HACKAGE_CREDS"

mkdir -p $ROOT/bin
BINDIR=$(cd $ROOT/bin ; pwd)
(
cd $BINDIR
rm -f stackage-curator stackage-curator.bz2
wget https://s3.amazonaws.com/stackage-travis/stackage-curator/stackage-curator.bz2
bunzip2 stackage-curator.bz2
chmod +x stackage-curator
)

ARGS_COMMON="--rm -u $USER -v $WORKDIR:/home/stackage/work -w /home/stackage/work -v $BINDIR/stackage-curator:/usr/local/bin/stackage-curator:ro -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro"
ARGS_PREBUILD="$ARGS_COMMON -v $CABAL_DIR:/home/stackage/.cabal -v $GHC_DIR:/home/stackage/.ghc -v $UPDATE_DIR:/home/stackage/.stackage-update"
ARGS_BUILD="$ARGS_COMMON -v $CABAL_DIR:/home/stackage/.cabal:ro -v $GHC_DIR:/home/stackage/.ghc:ro"
ARGS_UPLOAD="$ARGS_COMMON -v $AUTH_TOKEN:/auth-token:ro -v $HACKAGE_CREDS:/hackage-creds:ro -v $CURATOR_DIR:/home/stackage/.stackage-curator -v $SSH_DIR:/home/ubuntu/.ssh:ro -v $GITCONFIG:/home/stackage/.gitconfig:ro"

# Use cabal update first to initialize ~/.cabal.config, then use stackage-curator update to get it securely
docker run $ARGS_PREBUILD snoyberg/stackage /bin/bash -c "cabal update && stackage-curator update && stackage-curator create-plan --plan-file $PLAN_FILE --target $TARGET ${CONSTRAINTS:-} && stackage-curator check --plan-file $PLAN_FILE && stackage-curator fetch --plan-file $PLAN_FILE && cabal install random cabal-install"
docker run $ARGS_BUILD snoyberg/stackage stackage-curator make-bundle --plan-file $PLAN_FILE --bundle-file $BUNDLE_FILE --target $TARGET
docker run $ARGS_UPLOAD snoyberg/stackage /bin/bash -c "stackage-curator upload --bundle-file $BUNDLE_FILE && stackage-curator hackage-distro --plan-file $PLAN_FILE --target $TARGET && stackage-curator upload-github --plan-file $PLAN_FILE --target $TARGET"
