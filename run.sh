#!/bin/bash

if [ -f "./hostfile" ]
then
	rm -f ./hostfile
fi

# set number of GPUs per machine
# DEEPLEARNING_WORKER_GPU_COUNT is not set automatically by CloudFormation Template for P3

if [ "$DEEPLEARNING_WORKER_GPU_COUNT" -eq "0" ]
then
	echo "DEEPLEARNING_WORKER_GPU_COUNT is not set, setting it to default value of 8"
	DEEPLEARNING_WORKER_GPU_COUNT=8
fi


SRC_DIR=$HOME/tensorpack

# EFS_MOUNT is set automatically by CloudFormation Template
FSX_MOUNT=/fsx
FILE_SYSTEM=""

if [ -e $FSX_MOUNT/data ]
then
FILE_SYSTEM="fsx"
DATA_DIR=$FSX_MOUNT/data
LOG_DIR=$FSX_MOUNT
elif [ -e $EFS_MOUNT/data ]
then
FILE_SYSTEM="efs"
DATA_DIR=$EFS_MOUNT/data
LOG_DIR=$EFS_MOUNT
else
FILE_SYSTEM="ebs"
DATA_DIR=$HOME/data
LOG_DIR=$HOME
fi
echo "Data directory: $DATA_DIR"

#DEEPLEARNING_WORKERS_COUNT is set automatically by CloudFormation Template
[ $DEEPLEARNING_WORKERS_COUNT -eq 1 ] || [ $(($DEEPLEARNING_WORKERS_COUNT % 2)) -eq 0 ] || \
(echo "DEEPLEARNING_WORKERS_COUNT must be 1 or even" && (exit 1)) 

for i in $(seq 1 $DEEPLEARNING_WORKERS_COUNT)
do
ssh -oStrictHostKeyChecking=no deeplearning-worker$i "touch /efs/deeplearning-worker$i-health.check"
echo "deeplearning-worker$i slots=$DEEPLEARNING_WORKER_GPU_COUNT" >> ./hostfile
echo "Running setup on deeplearning-worker$i: may take a few minutes"
ssh ubuntu@deeplearning-worker$i 'bash -l /home/ubuntu/setup.sh 1>setup.log 2>&1'
echo "Completed setup on deeplearning-worker$i"
done

MPIRUN=$HOME/anaconda3/envs/tensorflow_p36/bin/mpirun
NUM_PARALLEL=$( expr "$DEEPLEARNING_WORKERS_COUNT" '*' "$DEEPLEARNING_WORKER_GPU_COUNT")
echo "Number of parallel mpi runs:$NUM_PARALLEL"

#Batch Norm type
BATCH_NORM=FreezeBN
#BATCH_NORM=SyncBN

DATE=`date '+%Y-%m-%d-%H-%M-%S'`
RUN_ID=mask-rcnn-coco-$NUM_PARALLEL-$FILE_SYSTEM-$DATE

EVAL_PERIOD=$( expr "8" '/' "$DEEPLEARNING_WORKERS_COUNT")

echo "Training started:" `date '+%Y-%m-%d-%H-%M-%S'`

HOROVOD_CYCLE_TIME=0.5 \
HOROVOD_FUSION_THRESHOLD=67108864 \
$MPIRUN -np $NUM_PARALLEL \
--hostfile ./hostfile \
--mca plm_rsh_no_tree_spawn 1 -bind-to none -map-by slot -mca pml ob1 -mca btl ^openib \
-mca btl_tcp_if_exclude lo,docker0 \
-x NCCL_SOCKET_IFNAME=^docker0 \
-x NCCL_MIN_NRINGS=8 -x NCCL_DEBUG=INFO \
-x LD_LIBRARY_PATH -x PATH \
-x HOROVOD_CYCLE_TIME -x HOROVOD_FUSION_THRESHOLD \
--output-filename $LOG_DIR/$RUN_ID \
python3 $SRC_DIR/examples/FasterRCNN/train.py \
--logdir $LOG_DIR/$RUN_ID/train_log/maskrcnn \
--config MODE_MASK=True \
MODE_FPN=True \
DATA.BASEDIR=$DATA_DIR \
DATA.TRAIN='["train2017"]' \
DATA.VAL=val2017 \
TRAIN.EVAL_PERIOD=$EVAL_PERIOD \
TRAIN.STEPS_PER_EPOCH=1875 \
TRAIN.LR_SCHEDULE='[120000, 160000, 180000]' \
BACKBONE.WEIGHTS=$DATA_DIR/pretrained-models/COCO-R50FPN-MaskRCNN-Standard.npz \
BACKBONE.NORM=$BATCH_NORM \
TRAINER=horovod

echo "Training finished:" `date '+%Y-%m-%d-%H-%M-%S'`
