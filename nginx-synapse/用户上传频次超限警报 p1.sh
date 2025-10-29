# 进入当前脚本所在目录
cd "$(dirname "$0")"

# 定义关键词
# keyword=" limiting requests, "
keyword="\"POST /_matrix/media/(r0|v3)/upload.+HTTP/.+\"\ 503"

# Synapse 实例
synapse_url=`cat ./constants.json | jq -r ".synapse_url"`
access_token=`cat ./constants.json | jq -r ".synapse_access_token"`
synapse_server_name=`cat ./constants.json | jq -r ".synapse_server_name"`

# 临时目录
#tmp_path="/tmp/{251792DA-C8DB-77D8-0AA5-B58ED6B94C90}"
tmp_path=`cat ../tmp_storage_path.json | jq -r ".tmp_storage_path"`

# 目标容器名称
container_name=`cat ./constants.json | jq -r ".container_name"`

# 尝试创建 Ramdisk, 用于存储临时文件
#if [ ! -d "${tmp_path}" ]
#then
#  mkdir "${tmp_path}"
#  mount -t tmpfs -o size=1M tmpfs $tmp_path
#  echo "[文件上传超限通知与删除 P1] 已创建 Ramdisk (大小 1 MB), 目录 ${tmp_path}."
#else
#  echo "[文件上传超限通知与删除 P1] Ramdisk ${tmp_path} 已存在."
#fi

# ntfy 实例
ntfy_url=`cat ./constants.json | jq -r ".ntfy_url"`
ntfy_topic_name="synapse_log_based_triggers_39BED2DD5CAF"
curl -s -H "Title: Synapse 基于日志的触发器" -d "触发器已激活, 开始监控所有用户向 Synapse 的 /_matrix/media/(r0|v3)/upload 请求状况." "$ntfy_url/$ntfy_topic_name"

timeout $1 docker logs -tf --tail 1 $container_name 2>&1 | grep -E --line-buffered "$keyword" | \
while read line
do
  # 打印含有匹配字符串的日志
  # echo $line
  
  # 从日志中提取出 IP 地址
  client_ip=${line#* }
  client_ip=${client_ip% - - \[*}
  
  echo "[用户上传频率超限警报 P1] 用户 IP: $client_ip"
  
  # 从日志中提取出访问 Token
  user_access_token=${line#*authorization: Bearer }
  user_access_token=${user_access_token%\"}
  
  echo "[用户上传频率超限警报 P1] 用户访问 Token: $user_access_token"

  # 当前时间戳 (10 位)
  current_ts13=`date +%s` # 13 位
  current_ts10=${current_ts13:0:10} # 转换为 10 位
  
  # 用于阻塞的临时文件
  block_tmpfile="$tmp_path/$user_id.uploadratelimit.json"
  
  # ntfy 主题
  ntfy_topic_name="synapse_push_failure_warning_for_ios_1067C8A77671"
  
  # 判断用于阻塞的临时文件是否不存在
  # 只有不存在; 或文件存在但其中记录的时间戳距离当前大于 1 秒才发送警报
  if [ ! -e "$block_tmpfile" ]
  then
    # 创建临时文件
    echo "{\"last_trig_ts10\": $current_ts10}" > $block_tmpfile
    echo "[用户上传频率超限警报 P1] 面向用户 $user_id 的阻塞临时文件不存在, 已创建."
    
    # 根据访问 Token 获取用户 ID
    user_id=`curl -s -H "authorization: Bearer $user_access_token" "$synapse_url/_matrix/client/v3/account/whoami" | jq -r ".user_id"`
    echo "[用户上传频率超限警报 P1] 用户 ID: $user_id"
    
    # 发送警报到 ntfy. 警报正文的换行符无需转义
    # curl_result=`curl -s -H "Priority: high" -H "Title: Synapse 请求频率超限" -d "用户 $user_id 请求 API: /_matrix/media/(r0|v3)/upload 时触发了频率限制. 客户端 IP: $client_ip" "$ntfy_url/$ntfy_topic_name"`
    
    # 向触发限制的用户发送通知.
    curl_result=`curl -s -X POST -H "authorization: Bearer $access_token" -d "{\"user_id\":\"$user_id\",\"content\":{\"msgtype\":\"m.text\",\"body\":\"你在尝试批量上传文件时触发了速率限制, 请对这些文件打包压缩或减少批量上传时的文件数量.\u000a部分文件的上传请求已被拦截.\"}}" "$synapse_url/_synapse/admin/v1/send_server_notice"`
    echo "[用户上传频率超限警报 P1] $curl_result"
  else
    cooldown_time=1 # 冷却时间 (秒)
    last_trig_ts10=`cat "$block_tmpfile" | jq -r ".last_trig_ts10"`
    ts10_diff=`expr $current_ts10 - $last_trig_ts10`
    echo "[用户上传频率超限警报 P1] 时间戳的差: $ts10_diff"
    if [ $ts10_diff -gt $cooldown_time ]
    then
      # 根据访问 Token 获取用户 ID
      user_id=`curl -s -H "authorization: Bearer $user_access_token" "$synapse_url/_matrix/client/v3/account/whoami" | jq -r ".user_id"`
      echo "[用户上传频率超限警报 P1] 用户 ID: $user_id"

      # 发送警报到 ntfy. 警报正文的换行符无需转义
      # curl_result=`curl -s -H "Priority: high" -H "Title: Synapse 请求频率超限" -d "用户 $user_id 请求 API: /_matrix/media/(r0|v3)/upload 时触发了频率限制. 客户端 IP: $client_ip" "$ntfy_url/$ntfy_topic_name"`
      
      # 向触发限制的用户发送通知.
      curl_result=`curl -s -X POST -H "authorization: Bearer $access_token" -d "{\"user_id\":\"$user_id\",\"content\":{\"msgtype\":\"m.text\",\"body\":\"你在尝试批量上传文件时触发了速率限制, 请对这些文件打包压缩或减少批量上传时的文件数量.\u000a部分文件的上传请求已被拦截.\"}}" "$synapse_url/_synapse/admin/v1/send_server_notice"`
      echo "[用户上传频率超限警报 P1] $curl_result"
      
      # 更新临时文件中的时间戳
      echo "{\"last_trig_ts10\": $current_ts10}" > $block_tmpfile
      echo "[用户上传频率超限警报 P1] 面向用户 $user_id 的阻塞临时文件已存在, 更新最后触发时间戳 (10 位)."
    else
      echo "[用户上传频率超限警报 P1] 触发冷却时间小于等于 $cooldown_time 秒, 不发送通知."
    fi
  fi

done
