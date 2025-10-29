# 进入当前脚本所在目录
cd "$(dirname "$0")"

# 定义关键词
keyword="400 \"POST /_matrix/media/(r0|v3)/upload"

# 临时目录
#tmp_path="/tmp/{251792DA-C8DB-77D8-0AA5-B58ED6B94C90}"
tmp_path=`cat ../tmp_storage_path.json | jq -r ".tmp_storage_path"`

# 目标容器名称
container_name=`cat ./constants.json | jq -r ".container_name"`

# Synapse 实例
synapse_url=`cat ./constants.json | jq -r ".synapse_url"`
access_token=`cat ./constants.json | jq -r ".synapse_access_token"`

# 文件路径前缀, 用于与后缀组合为完整的绝对路径
filepath_prefix="/volume2/Private 2/docker/synapse/data/media_store"

# ntfy 实例
ntfy_url=`cat ./constants.json | jq -r ".ntfy_url"`
ntfy_topic_name="synapse_log_based_triggers_39BED2DD5CAF"

curl -s -H "Title: Synapse 基于日志的触发器" -d "(文件上传超限通知与删除 P3) 触发器已激活." "$ntfy_url/$ntfy_topic_name"

timeout $1 docker logs -tf --tail 1 $container_name 2>&1 | grep --line-buffered -E "$keyword" | \
while read line
do
  # 取出 POST ID
  post_id="${line#*INFO - }"
  post_id="${post_id%% - *}"
  
  echo "[文件上传超限通知与删除 P3] 监测到关键字: $keyword, POST ID 为 $post_id"

  info_filepath1="$tmp_path/$post_id-1" # P1 创建
  info_filepath2="$tmp_path/$post_id-2" # P2 创建

  # 循环判断多个命名管道 (P1 创建的名称为 $post_id-1, P2 创建的名称为 $post_id-2) 是否有至少 1 个不存在, 如果是, 继续判断直到同时存在, 最终跳出循环
  # 意味着判断语句的实际作用是等待管道出现

  until [[ $(stat -c "%F" $info_filepath1) == "fifo" && $(stat -c "%F" $info_filepath2) == "fifo" ]]
  do
    echo "[文件上传超限通知与删除 P3] 所需的命名管道不存在 (或缺少至少 1 个), 继续监测..."
    break
  done
  
  echo "[文件上传超限通知与删除 P3] 已找到标识符为 $post_id-1 的命名管道."
  echo "[文件上传超限通知与删除 P3] 已找到标识符为 $post_id-2 的命名管道."

  # 读取命名管道 $info_filepath2 中的文件路径 ()
  filepath_postfix=`cat "$info_filepath2"`
  echo "[文件上传超限通知与删除 P3] $post_id-2 中记录的文件路径: $filepath_postfix"
  
  # 从日志中获取用户 ID
  target_userid=${line#*\{}
  target_userid=${target_userid%\}*}
  echo "[文件上传超限通知与删除 P3] 用户 $target_userid 触发周期内上传流量额度限制"
  
  # 从日志中获取文件名
  if [[ "$line" =~ "?filename=" ]] # 针对 Element X, 如果请求的 URL 不含指定的字符串, 则视为未携带文件名, 单独处理
  then
    target_filename=${line#*/upload\?filename\=}
    target_filename=${target_filename% HTTP*}
  else
    target_filename="未知"
  fi
  
  # 对文件名 URL 解码
  urldecode() { : "${*//+/ }"; echo -e "${_//%/\\x}"; }
  target_filename_urldecoded=`urldecode $target_filename`
  target_filename_urldecoded=`urldecode $target_filename_urldecoded` # 需要二次解码, 原因不明
  echo "[文件上传超限通知与删除 P3] 文件名: $target_filename_urldecoded"
  
  # 加入随机延时, 避免极端高并发
  # random_delay=$(awk -v min=0.2 -v max=1 'BEGIN{srand(); print min + (max-min)*rand()}')
  random_delay=0.2$(openssl rand -base64 8 |cksum | cut -c1-4)
  # random_delay=0.3
  echo "[文件上传超限通知与删除 P3] 在开始运行最终脚本前延时 $random_delay 秒"
  sleep $random_delay
  
  # 在新进程中运行脚本, 并传递特定变量
  # 文件名参数虽然仍然传递, 但实际暂时被弃用
  # "./文件上传超限通知与删除 p4.sh" "$target_userid" "$target_filename_urldecoded" "$filepath_prefix$filepath_postfix" &
  "./文件上传超限通知与删除 p4_new.sh" "$target_userid" "$target_filename_urldecoded" "$filepath_prefix$filepath_postfix" &
  
  # 删除所有命名管道
  rm "$info_filepath1"
  rm "$info_filepath2"

done
