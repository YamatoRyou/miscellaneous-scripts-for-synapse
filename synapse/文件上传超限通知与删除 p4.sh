# 进入当前脚本所在目录
cd "$(dirname "$0")"

# Synapse 实例
synapse_url=`cat ./constants.json | jq -r ".synapse_url"`
access_token=`cat ./constants.json | jq -r ".synapse_access_token"`

# 临时目录
#tmp_path="/tmp/{251792DA-C8DB-77D8-0AA5-B58ED6B94C90}"
tmp_path=`cat ../tmp_storage_path.json | jq -r ".tmp_storage_path"`

# 待办: 引入查询用户剩余上传配额
# 不直接进行 SQL, 而是使用某种方式缓冲, 避免产生多个 psql 进程以节省系统资源开销

# Postgres 数据库连接信息 (新)
postgres_container_name=`cat ./constants.json | jq -r ".database.container_name"` # 容器名称
postgres_database_port=`cat ./constants.json | jq -r ".database.postgres_database_port"` # 数据库端口
postgres_database_name=`cat ./constants.json | jq -r ".database.postgres_database_name"` # 数据库名称
postgres_database_operator_name=`cat ./constants.json | jq -r ".database.postgres_database_operator_name"` # 操作数据库使用的用户名
postgres_database_table_name="local_media_repository" # 目标数据库中的目标表名称

# SQL 查询最小间隔 (秒)
sql_query_minimum_period=10

# 总上传额度 (字节)
total_upload_qupta_bytes=1610612736

# 自动调整数据大小单位函数, 通过此函数将该指定的数值 (通常为字节数) 转换为合适的带单位的值, 保留 2 位小数
#data_bytes_to_humanization_size_format () {
#  if [ $1 -ge 1073741824 ]; # 如果大于等于 1073741824 字节 (1 GB)
#  then
#      datasize2=$(awk "BEGIN {printf \"%.2f\", $1 / 1024 / 1024 / 1024}") # 除法浮点运算
#      datasize_with_unit="$datasize2 GB"
#  elif [ $1 -lt 1073741824 -a $1 -ge 1048576 ]; # 如果小于 1073741824 字节 (1 GB) 且大于等于 1048576 字节 (1 MB)
#  then
#      datasize2=$(awk "BEGIN {printf \"%.2f\", $1 / 1024 / 1024}") # 除法浮点运算
#      datasize_with_unit="$datasize2 MB"
#  elif [ $1 -lt 1048576 -a $1 -ge 1024 ]; # 如果小于 1048576 字节 (1 MB) 且大于等于 1024 字节 (1 KB)
#  then
#      datasize2=$(awk "BEGIN {printf \"%.2f\", $1 / 1024}") # 除法浮点运算
#      datasize_with_unit="$datasize2 KB"
#  elif [ $1 -lt 1024 ]; # 如果小于 1024 字节 (1 KB);
#  then
#      datasize_with_unit="$1 B"
#  fi
  
#  echo "$datasize_with_unit"
#}

# 自动调整数据大小单位函数 (新, 支持处理负数), 通过此函数将该指定的数值 (通常为字节数) 转换为合适的带单位的值, 保留 2 位小数
data_bytes_to_humanization_size_format () {
  local value=$1

  # 负数处理
  local negative_num=false
  if [ $value -lt 0 ]
  then
    negative_num=true
    value=$(( -value ))
  fi

  if [ $value -ge 1073741824 ]; # 如果大于等于 1073741824 字节 (1 GB)
  then
      datasize=$(awk "BEGIN {printf \"%.2f\", $value / 1024 / 1024 / 1024}") # 除法浮点运算
      datasize_with_unit="$datasize GB"
  elif [ $value -lt 1073741824 -a $value -ge 1048576 ]; # 如果小于 1073741824 字节 (1 GB) 且大于等于 1048576 字节 (1 MB)
  then
      datasize=$(awk "BEGIN {printf \"%.2f\", $value / 1024 / 1024}") # 除法浮点运算
      datasize_with_unit="$datasize MB"
  elif [ $value -lt 1048576 -a $value -ge 1024 ]; # 如果小于 1048576 字节 (1 MB) 且大于等于 1024 字节 (1 KB)
  then
      datasize=$(awk "BEGIN {printf \"%.2f\", $value / 1024}") # 除法浮点运算
      datasize_with_unit="$datasize KB"
  elif [ $value -lt 1024 ]; # 如果小于 1024 字节 (1 KB);
  then
      datasize_with_unit="$value B"
  fi
  
  # 再次判断 flag, 用于补回负号
  if [ $negative_num = true ]
  then
    local negative_sign="-"
  fi
  
  echo "$negative_sign$datasize_with_unit"
}


# SQL 查询函数
sql_query() {
  # 当前时间戳 (函数专用)
  current_ts13_for_func=`date +%s` # 13 位
  current_ts10_for_func=${current_ts13_for_func:0:10} # 转换为 10 位

  # 开始数据库查询, 为指定用户统计距今前 24 小时内上传的数据总量
  # 限制查询时长为 3 秒
  sql_result=`timeout 3 docker exec $postgres_container_name psql -X -A -d $postgres_database_name -U $postgres_database_operator_name -p $postgres_database_port -t -c \
  "\
  SELECT
    media_length
  FROM 
    $postgres_database_table_name
  WHERE
    created_ts >= $(expr $(date '+%s%3N') - 86400000)
    AND
    user_id = '$1'; \
  "`
  
  # 整理第 1 阶段, 以空格为分隔符将每个文件的信息置入数组
  pending_media_list=(${sql_result//\ /})

  # 定义一些空数组
  media_size_bytes_s=() # 媒体大小 (字节), 0
  tmp_array=() # 用于中转的临时数组
  medias_total_size=0 # 初始化合计

  # 整理第 2 阶段, 以管道符为分隔符将每个文件中的不同种类信息分别置入各自的数组
  for ((x = 0; x < ${#pending_media_list[*]}; x ++));
  do
    # 拆分每一行中的信息到临时数组
    tmp_array=(${pending_media_list[x]//\|/ })
    
    # 获取媒体大小 (字节)
    media_size_bytes_s+=(${tmp_array[0]}) 
    
    # 获取媒体上传时间 (13 位时间戳)
    media_mxc_upload_timestamp13_s+=(${tmp_array[1]}) 
    
    # 临时显示信息
    # echo "$x: 大小: ${media_size_bytes_s[x]}, 上传时间戳: ${media_mxc_upload_timestamp13_s[x]}"
    
    # 合计在周期内所有媒体的总大小 (字节)
    medias_total_size=`expr $medias_total_size + ${media_size_bytes_s[x]}`
  done
  echo $medias_total_size
}

# 记录上传总量的文件路径
uploaded_datasizefile_for_user_filepath="$tmp_path/$1.uploadeddatasize.json"

# 当前时间戳
current_ts13=`date +%s` # 13 位
current_ts10=${current_ts13:0:10} # 转换为 10 位

# 判断用于记录上传总量的文件是否存在, 如果不存在则创建并在其中写入信息
if [ -e "$uploaded_datasizefile_for_user_filepath" ]
then
  echo "[文件上传超限通知与删除 P4] 用户 $1 的上传总量记录文件 $uploaded_datasizefile_for_user_filepath 已存在, 读取此文件中的信息."
  uploaded_datasize_json=`cat $uploaded_datasizefile_for_user_filepath | jq .`
  
  # 获取文件中记录的最后查询时间戳 (10 位)
  last_query_ts10_for_user=`echo $uploaded_datasize_json | jq ".last_query_ts10"`
  echo "[文件上传超限通知与删除 P4] 用户 $1 记录到 $uploaded_datasizefile_for_user_filepath 中的最后查询时间戳 (10 位) 为 $last_query_ts10_for_user"
  
  # 计算时间差
  ts10_diff=`expr $current_ts10 - $last_query_ts10_for_user` # 当前时间戳 (10 位) - 文件记录的最后查询时间戳 (10 位)
  echo "[文件上传超限通知与删除 P4] 时间戳的差: $ts10_diff"
  
  # 判断是否大于最小查询间隔
  if [ $ts10_diff -gt $sql_query_minimum_period ]
  then
    echo "[文件上传超限通知与删除 P4] 用户 $1 记录到 $uploaded_datasizefile_for_user_filepath 中的最后查询时间戳 (10 位) 距今已超过 $sql_query_minimum_period 秒, 重新查询以更新信息."
    total_uploaded_data_size_bytes_for_user=`sql_query $1` # 如果大于最小查询间隔, 则重新查询数据库
    echo "[文件上传超限通知与删除 P4] 用户 $1 的上传总量记录文件 $uploaded_datasizefile_for_user_filepath 已更新."
    
    # 覆盖现有文件
    echo "{\"last_query_ts10\": $current_ts10, \"total_uploaded_data_size_bytes_for_user\": $total_uploaded_data_size_bytes_for_user}" > $uploaded_datasizefile_for_user_filepath
  else
    echo "[文件上传超限通知与删除 P4] 用户 $1 记录到 $uploaded_datasizefile_for_user_filepath 中的最后查询时间戳 (10 位) 距今不足 $sql_query_minimum_period 秒, 读取此文件中的信息."
    
    # 从文件获取指定用户的上传总量 (字节)
    total_uploaded_data_size_bytes_for_user=`echo $uploaded_datasize_json | jq ".total_uploaded_data_size_bytes_for_user"`
  fi
else
  total_uploaded_data_size_bytes_for_user=`sql_query $1` # 由于记录文件尚不存在, 直接从 SQL 查询中获取
  echo "[文件上传超限通知与删除 P4] 用户 $1 的上传总量记录文件 $uploaded_datasizefile_for_user_filepath 不存在, 创建."
  
  # 创建新文件
  echo "{\"last_query_ts10\": $current_ts10, \"total_uploaded_data_size_bytes_for_user\": $total_uploaded_data_size_bytes_for_user}" > $uploaded_datasizefile_for_user_filepath
fi

# 计算剩余上传流量配额
remain_upload_quota_bytes=`expr $total_upload_qupta_bytes - $total_uploaded_data_size_bytes_for_user`

# 转换为带单位的友好格式
remain_upload_quota_with_unit=`data_bytes_to_humanization_size_format $remain_upload_quota_bytes`

echo "[文件上传超限通知与删除 P4] 用户 $1 的剩余上传流量配额为 $remain_upload_quota_with_unit"

# 正则匹配相对文件路径, 避免 rm 命令意外执行
regex="^/volume2/Private 2/docker/synapse/data/media_store/local_content/[a-z|A-Z]{2}/[a-z|A-Z]{2}/[a-z|A-Z]{20}" # 正则表达式
regex_result=`echo "$3" | grep -E "$regex"`

if [ "$regex_result" == "$3" ]
then
  echo "[文件上传超限通知与删除 P4] 相对路径 $3 正则匹配通过, 执行删除."

  # 删除文件
  rm_result=`rm -v "$3"`
  echo "[文件上传超限通知与删除 P4] $rm_result"
  echo "[文件上传超限通知与删除 P4] 删除文件 (rm 结果: $?): $3"

  # 通知用户
  curl_result=`curl -s -X POST -H "authorization: Bearer $access_token" -d "{\"user_id\":\"$1\",\"content\":{\"msgtype\":\"m.text\",\"body\":\"由于你的账号在 24 小时内剩余的上传流量额度不足以上传此文件或已耗尽, 本次上传的文件已被服务器删除. 请上传更小的文件或间隔至少 24 小时后再试.\u000a尝试上传的文件名: $2\u000a\u000a剩余: $remain_upload_quota_with_unit\u000a此处显示的剩余流量为你最后一次触发上传流量超限时产生的计算结果. 除非下次触发上传流量超限距离本次超过 $sql_query_minimum_period 秒, 否则此数值不会更新.\"}}" "$synapse_url/_synapse/admin/v1/send_server_notice"`
  echo "[文件上传超限通知与删除 P4 - CURL 结果 (通知用户)] $curl_result"
else
  echo "[文件上传超限通知与删除 P4] 相对路径 $3 正则匹配不通过, 放弃删除."
fi
