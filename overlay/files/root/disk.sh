yum install -y fio > /dev/null 2>&1

if [[ -z $(fio --version) ]];then
    echo "fio安装失败"
    exit
fi

IFS=$'\n'

if [[ $(ps aux | grep -v grep | grep -c "fio.conf") -gt 0 ]];then
    echo "fio正在运行"
    exit
fi

mkdir -p /root/fio

root_disk=`lsblk -ar 2>>/dev/null | grep -w "/" | awk '{print $1}' | sed 's/[0-9]//'`
Mount=`lsblk |grep nvme |awk '{print $7}'`
if [ "$Mount" == "" ];then
    Sdd=`lsblk -b -d -o name,size,type,mountpoint,rota 2>>/dev/null | awk '{if($2>500000000000) print $0}' | grep -v "$root_disk"  |awk '{if($4=="0")print $1}'`
    echo "disk umount"
    Sdd_num=`lsblk -b -d -o name,size,type,mountpoint,rota 2>>/dev/null | awk '{if($2>500000000000) print $0}' | grep -v "$root_disk"  |awk '{if($4=="0")print $1}'|wc -l`
    for ((i=1; i<=${Sdd_num}; i ++));do mkdir /data$i ;done
    
    b=0
    for i in $Sdd;do
        b=$[b+1]
        mkfs.xfs -f /dev/$i > /dev/null 2>&1
        mount /dev/$i /data$b
        nohup fio -filename=/data${b}/test.test -direct=0 -iodepth 1 -thread -rw=randrw -rwmixread=80 -ioengine=psync -bs=256k -size=100G -numjobs=1 -runtime=180 -group_reporting -name=randrw_80read_256k > /root/fio/${b}.log & > /dev/null 2>&1
    done 
    
else
    Sdd=`lsblk -b -d -o name,size,type,mountpoint,rota 2>>/dev/null | awk '{if($2>500000000000) print $0}' | grep -v "$root_disk"  |awk '{if($5=="0")print $4}'`
    echo "disk mount"
    b=0
    for i in $Sdd;do
        b=$[b+1]
        nohup fio -filename=${i}/test.test -direct=0 -iodepth 1 -thread -rw=randrw -rwmixread=80 -ioengine=psync -bs=256k -size=100G -numjobs=1 -runtime=180 -group_reporting -name=randrw_80read_256k > /root/fio/${b}.log & > /dev/null 2>&1
    done
fi

sleep 300

RED='\E[1;31m'   # 红
GREEN='\E[1;32m' #绿
YELOW='E[1;33m'  #黄
BLUE='\E[1;34m'  #蓝
PINK='\E[1;35m'  #粉红
SHAN='E[33;5m'   #黄色闪烁
RES='\E[0m'      #清楚颜色

for i in `ls /root/fio/`;do
    Disk=`cat /root/fio/${i} |egrep 'nvme|IOPS' |awk '{print $1,$2}'|xargs -n6`
    echo -e "${BLUE} ${Disk} ${RES}"
done