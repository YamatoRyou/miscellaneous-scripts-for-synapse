# 进入当前脚本所在目录
cd "$(dirname "$0")"

# 日志文件
log_filepath="./{9DA8C71A-BEEB-4507-0432-660138725951}.log"

# 目标容器名称
container_name=`cat ./constants.json | jq -r ".container_name"`

# Docker 主程序
docker_execfile_path=`cat ./constants.json | jq -r ".docker_execfile_path"`

# ntfy 实例
ntfy_url=`cat ./constants.json | jq -r ".ntfy_url"`

# 定义一个空数组, 用于存放触发器的进程 ID
trigger_pids=()

# 初始化或清空日志
echo -n > $log_filepath

# 简易门槛机制 #1, 直到指定的文件存在时才跳出循环
# 用于检测 Docker 套件是否正在运行
until [ -f $docker_execfile_path ]
do
    echo "[总脚本] Docker 主程序文件不存在, 可能是 Docker 套件尚未启动. 等待中..." >> $log_filepath
    sleep 1
done

# 简易门槛机制 #2, 直到指定的容器开始运行才跳出循环
# 用于检测 Synapse 容器是否正在运行
until [ "$(docker inspect $container_name | jq '.[0].State.Running')" = "true" ]
do
    echo "[总脚本] 容器 $container_name 尚未开始运行, 等待中..." >> $log_filepath
    sleep 1
done

# 简易门槛机制 #3, 直到指定的命令在指定的超时前联机成功才跳出循环
# 用于检测与 ntfy 联网
until [ -n "$(curl -s --connect-timeout 1 $ntfy_url)" ]
do
    echo "[总脚本] 与 $ntfy_url 联机超时, 正在重试..." >> $log_filepath
    # sleep 1
done

####################### 执行触发器 #1: 用户上传频次超限警报 #######################
# 用途: 当某个用户特定周期内请求 Syanpse 的媒体上传 API 超过特定频率时发出警报.
    process_identity_string="30001d" # 一个唯一字符串, 用于定位进程
    nohup "./用户上传频次超限警报 p1.sh" $process_identity_string >> $log_filepath &
    sleep 0.25 # 插入少许延时缓冲下面的命令, 避免拿到错误的进程 ID

    # 获取触发器的进程 ID 并加入到数组
    trigger_pids+=(`ps -ef | grep "timeout $process_identity_string" | grep -v "grep" | awk '{print $2}'`)
###########################################################################






# timeout *****d 的作用
# timeout 原本的用途是为指定的命令设置超时, 若未能在指定的时间内执行完毕则强行停止命令.
# 在此脚本中被用作确定进程 ID 的唯一字符串.
# *****d 为任意天数, 比如 10000d 为 10000 天 (值要符合 4 个要求: 必须是 10 进制数字; 足够长; 唯一; 必须以 "d" 结尾). 设置不切实际的超时可以避免进程短时间内自动终止.

# 简易触发机制 #4, 循环判断容器正在运行, 除非停止或正在重启, 否则将无限循环
#until [[ $(docker inspect $container_name | jq -r ".[0].State.Running") == "false" ]]
#do
#    echo "容器 $container_name 正在运行, 等待其停止或重启..."
#    sleep 0.25
#done

# 简易门槛机制 #5, 监控 Synapse 容器的停止 (stop) 事件, 如果监测到, 就开始杀死所有触发器
container_id=`docker inspect $container_name | jq -r ".[0].Id"` # 获取容器 ID, 因为监视事件必须以容器 ID 而不是容器名称才能有效过滤
process_identity_string="30000d" # 一个唯一字符串, 用于定位 docker events 进程
keyword="container stop"
timeout $process_identity_string docker events --filter "container=$container_id" --filter "event=stop" | \
while read line
do
  echo "监测到容器停止事件" >> $log_filepath
  
  # 当容器停止或重启时, 通过收集到的所有触发器的进程 ID 杀死对应的进程
  for ((x=0; x<${#trigger_pids[*]}; x++))
  do
      echo ${trigger_pids[$x]}
      kill ${trigger_pids[$x]}
  done
  
  # sleep 0.25 # 插入少许延时缓冲下面的命令, 避免拿到错误的进程 ID
  # 获取 docker events 的进程 ID 并杀死对应的进程
  docker_events_watcher_pid=`ps -ef | grep "timeout $process_identity_string" | grep -v "grep" | awk '{print $2}'`
  echo $docker_events_watcher_pid
  echo `cat /proc/$docker_events_watcher_pid/cmdline`
  kill $docker_events_watcher_pid
done


# 收尾工作: 当容器停止或重启时, 通过收集到的所有触发器的进程 ID 杀死对应的进程
#for ((x=0; x<${#trigger_pids[*]}; x++))
#do
#    echo ${trigger_pids[$x]}
#    kill ${trigger_pids[$x]}
#done

# 重启自身, 为容器重启后做准备
echo "重启自身" >> $log_filepath
"$0"
# nohup "$0" > /dev/null 2>&1 &
